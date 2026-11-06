"""
Datos maestros de la empresa, compartidos por todos los sistemas:
usuarios, departamentos, empleados, clientes, servicios y proyectos.

Convenciones de toda la base (ver PLAN_MIGRACION.md):
- Llave primaria UUID versión 7 (empieza con la hora, así que ordenada como
  texto queda en orden de creación, como los ObjectId). Las filas migradas
  derivan su UUID del ObjectId original (ver nucleo/ids.py).
- `mongo_id`: `_id` del documento de MongoDB del que salió la fila. Es único y
  permite volver a correr la migración sin duplicar.
- `datos_extra`: campos que el documento traía fuera del esquema.
- Montos en NUMERIC(14,4): conserva hasta 4 decimales (el IVA del 13 % los
  produce) y quita solo el ruido de punto flotante.
"""

from django.contrib.auth.base_user import AbstractBaseUser, BaseUserManager
from django.contrib.auth.models import PermissionsMixin
from django.contrib.postgres.functions import RandomUUID
from django.db import models
from django.db.models import F, Q
from django.db.models.functions import Lower, Now
from django.utils import timezone

from .ids import uuid7

MONTO = {"max_digits": 14, "decimal_places": 4}
HORAS = {"max_digits": 8, "decimal_places": 4}


class ModeloBase(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid7, db_default=RandomUUID(), editable=False)
    mongo_id = models.CharField(
        max_length=24, unique=True, null=True, blank=True, editable=False,
        help_text="_id del documento de MongoDB de origen; vacío si la fila se creó después de la migración.",
    )
    datos_extra = models.JSONField(
        default=dict, db_default={}, blank=True,
        help_text="Campos que el documento original traía fuera del esquema.",
    )
    creado_en = models.DateTimeField(default=timezone.now, db_default=Now())
    actualizado_en = models.DateTimeField(default=timezone.now, db_default=Now())

    class Meta:
        abstract = True

    def save(self, *args, **kwargs):
        self.actualizado_en = timezone.now()
        update_fields = kwargs.get("update_fields")
        if update_fields is not None:
            kwargs["update_fields"] = {*update_fields, "actualizado_en"}
        super().save(*args, **kwargs)


class ModeloHijo(models.Model):
    """Fila que en MongoDB era un elemento de un arreglo dentro de otro documento."""

    id = models.UUIDField(primary_key=True, default=uuid7, db_default=RandomUUID(), editable=False)
    # Normalmente el _id del subdocumento (24 caracteres). Si el subdocumento no
    # tenía _id se usa "<_id del padre>.<posición>", por eso admite 40.
    mongo_id = models.CharField(max_length=40, unique=True, null=True, blank=True, editable=False)
    posicion = models.PositiveIntegerField(default=0, db_default=0, help_text="Orden dentro del arreglo original.")
    datos_extra = models.JSONField(default=dict, db_default={}, blank=True)

    class Meta:
        abstract = True
        ordering = ["posicion"]


# ---------------------------------------------------------------------------
# Usuarios
# ---------------------------------------------------------------------------


class UsuarioManager(BaseUserManager):
    use_in_migrations = True

    def _crear(self, email, password, **extra):
        if not email:
            raise ValueError("El correo es obligatorio")
        usuario = self.model(email=self.normalize_email(email), **extra)
        usuario.set_password(password)
        usuario.save(using=self._db)
        return usuario

    def create_user(self, email, password=None, **extra):
        extra.setdefault("is_staff", False)
        extra.setdefault("is_superuser", False)
        extra.setdefault("tipo", Usuario.Tipo.ADMINISTRADOR)
        return self._crear(email, password, **extra)

    def create_superuser(self, email, password=None, **extra):
        extra.setdefault("is_staff", True)
        extra.setdefault("is_superuser", True)
        extra.setdefault("tipo", Usuario.Tipo.ADMINISTRADOR)
        return self._crear(email, password, **extra)


class Usuario(ModeloBase, AbstractBaseUser, PermissionsMixin):
    """
    Cuenta para iniciar sesión en cualquier sistema de la empresa.

    - tipo «administrador»: viene de la colección `administrators`.
    - tipo «empleado»: credenciales de un empleado (`Empleado.usuario`). Si puede
      entrar o no lo deciden `Empleado.activo` y `Empleado.tiene_acceso`, igual que
      en el sistema administrativo.
    """

    class Tipo(models.TextChoices):
        ADMINISTRADOR = "administrador", "Administrador"
        EMPLEADO = "empleado", "Empleado"

    # unique=True lo exige Django para el campo de inicio de sesión; la restricción
    # «usuario_email_unico» además impide correos que solo difieren en mayúsculas.
    email = models.EmailField("correo", max_length=254, unique=True)
    nombres = models.CharField(max_length=150, blank=True, default="", db_default="")
    apellidos = models.CharField(max_length=150, blank=True, default="", db_default="")
    tipo = models.CharField(max_length=20, choices=Tipo.choices)
    verificado = models.BooleanField(null=True, blank=True)
    intentos_login = models.PositiveSmallIntegerField(null=True, blank=True)
    bloqueado_hasta = models.DateTimeField(null=True, blank=True)
    is_active = models.BooleanField("activo", default=True, db_default=True)
    is_staff = models.BooleanField("acceso al panel de Django", default=False, db_default=False)
    is_superuser = models.BooleanField("superusuario", default=False, db_default=False)

    objects = UsuarioManager()

    USERNAME_FIELD = "email"
    EMAIL_FIELD = "email"
    REQUIRED_FIELDS = []

    class Meta:
        verbose_name = "usuario"
        constraints = [
            models.UniqueConstraint(Lower("email"), name="usuario_email_unico"),
            models.CheckConstraint(condition=Q(tipo__in=["administrador", "empleado"]), name="usuario_tipo_valido"),
        ]

    def __str__(self):
        return self.email


# ---------------------------------------------------------------------------
# Organización
# ---------------------------------------------------------------------------


class Departamento(ModeloBase):
    nombre = models.CharField(max_length=150)
    descripcion = models.TextField(null=True, blank=True)
    activo = models.BooleanField(null=True, blank=True)
    tarifa_hora_extra = models.DecimalField(**MONTO, null=True, blank=True)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=Q(tarifa_hora_extra__gte=0), name="departamento_tarifa_no_negativa"),
        ]

    def __str__(self):
        return self.nombre


class Empleado(ModeloBase):
    class TipoCuenta(models.TextChoices):
        AHORRO = "Ahorro", "Ahorro"
        CORRIENTE = "Corriente", "Corriente"

    usuario = models.OneToOneField(Usuario, null=True, blank=True, on_delete=models.SET_NULL, related_name="empleado")
    nombres = models.CharField(max_length=150)
    apellidos = models.CharField(max_length=150)
    telefono = models.CharField(max_length=30, null=True, blank=True)
    email = models.EmailField("correo", max_length=254, null=True, blank=True)
    dui = models.CharField("DUI", max_length=20, null=True, blank=True)
    codigo = models.CharField("código de empleado", max_length=30, null=True, blank=True, unique=True)
    tipo = models.CharField("tipo de empleado", max_length=100, null=True, blank=True)
    departamento = models.ForeignKey(Departamento, null=True, blank=True, on_delete=models.SET_NULL, related_name="empleados")
    cargo = models.CharField(max_length=150, null=True, blank=True)
    cuenta_bancaria = models.CharField(max_length=50, null=True, blank=True)
    tipo_cuenta = models.CharField(max_length=20, choices=TipoCuenta.choices, null=True, blank=True)
    afp = models.CharField("AFP", max_length=50, null=True, blank=True)
    pensionado = models.BooleanField(default=False, db_default=False)
    exento_isss = models.BooleanField("exento de ISSS", default=False, db_default=False)
    proceso_judicial = models.BooleanField(default=False, db_default=False)
    horas_jornada = models.DecimalField(**HORAS, null=True, blank=True)
    fecha_contratacion = models.DateField(null=True, blank=True)
    salario_mensual = models.DecimalField(**MONTO, null=True, blank=True, help_text="Copia del salario del contrato activo.")
    activo = models.BooleanField(default=True, db_default=True)
    tiene_acceso = models.BooleanField(default=False, db_default=False)
    es_admin = models.BooleanField(default=False, db_default=False)

    class Meta:
        constraints = [
            models.UniqueConstraint(Lower("email"), name="empleado_email_unico"),
            models.UniqueConstraint(fields=["dui"], name="empleado_dui_unico"),
            models.CheckConstraint(condition=Q(tipo_cuenta__in=["Ahorro", "Corriente"]), name="empleado_tipo_cuenta_valido"),
            models.CheckConstraint(condition=Q(horas_jornada__gte=0, horas_jornada__lte=24), name="empleado_horas_jornada_validas"),
            models.CheckConstraint(condition=Q(salario_mensual__gte=0), name="empleado_salario_no_negativo"),
        ]

    def __str__(self):
        return f"{self.nombres} {self.apellidos}"


# ---------------------------------------------------------------------------
# Clientes, servicios y proyectos
# ---------------------------------------------------------------------------


class Cliente(ModeloBase):
    class TipoPersona(models.TextChoices):
        NATURAL = "natural", "Persona natural"
        JURIDICA = "juridica", "Persona jurídica"

    ruc = models.CharField("RUC", max_length=50, unique=True)
    razon_social = models.CharField(max_length=255)
    contacto = models.CharField(max_length=255)
    telefono = models.CharField(max_length=30, null=True, blank=True)
    email = models.EmailField("correo", max_length=254, null=True, blank=True)
    direccion = models.TextField(null=True, blank=True)
    notas = models.TextField(null=True, blank=True)
    # Persona jurídica (empresa) pide NIT; persona natural pide DUI. El campo `ruc` no se toca
    # (sigue obligatorio y único). PENDIENTE: confirmar qué guarda `ruc`.
    tipo_persona = models.CharField(
        max_length=10, choices=TipoPersona.choices, null=True, blank=True
    )
    nit = models.CharField(max_length=20, unique=True, null=True, blank=True)  # si es jurídica
    dui = models.CharField(max_length=20, unique=True, null=True, blank=True)  # si es natural

    class Meta:
        constraints = [
            models.UniqueConstraint(Lower("email"), name="cliente_email_unico"),
            models.CheckConstraint(
                condition=Q(tipo_persona__in=["natural", "juridica"]),
                name="cliente_tipo_persona_valido",
            ),
            # tipo_persona nulo solo se permite para los clientes que ya existían (sin completar);
            # el formulario lo exige siempre (ver clean).
            models.CheckConstraint(
                condition=(
                    Q(tipo_persona__isnull=True)
                    | Q(tipo_persona="juridica", nit__isnull=False)
                    | Q(tipo_persona="natural", dui__isnull=False)
                ),
                name="cliente_documento_segun_tipo",
            ),
        ]

    def clean(self):
        """Validación antes de guardar desde formularios/admin (la base solo exige lo mínimo)."""
        from django.core.exceptions import ValidationError

        if not self.tipo_persona:
            raise ValidationError({"tipo_persona": "Indique si el cliente es persona natural o jurídica."})
        if self.tipo_persona == self.TipoPersona.JURIDICA and not self.nit:
            raise ValidationError({"nit": "Una persona jurídica (empresa) necesita NIT."})
        if self.tipo_persona == self.TipoPersona.NATURAL and not self.dui:
            raise ValidationError({"dui": "Una persona natural necesita DUI."})

    def __str__(self):
        return self.razon_social


class Servicio(ModeloBase):
    class Tipo(models.TextChoices):
        VISITA_CAMPO = "Visita de campo", "Visita de campo"
        ENSAYO_LABORATORIO = "Ensayo de laboratorio", "Ensayo de laboratorio"
        SERVICIO_PROFESIONAL = "Servicio profesional", "Servicio profesional"

    nombre = models.CharField(max_length=255)
    descripcion = models.TextField(null=True, blank=True)
    costo_unitario = models.DecimalField(**MONTO, null=True, blank=True)
    tipo = models.CharField(max_length=50, choices=Tipo.choices, null=True, blank=True)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=Q(costo_unitario__gte=0), name="servicio_costo_no_negativo"),
            models.CheckConstraint(
                condition=Q(tipo__in=["Visita de campo", "Ensayo de laboratorio", "Servicio profesional"]),
                name="servicio_tipo_valido",
            ),
        ]

    def __str__(self):
        return self.nombre


class Proyecto(ModeloBase):
    class Estado(models.TextChoices):
        NO_INICIADO = "no_iniciado", "No iniciado"
        EN_PROGRESO = "en_progreso", "En progreso"
        COMPLETADO = "completado", "Completado"

    cliente = models.ForeignKey(Cliente, null=True, blank=True, on_delete=models.SET_NULL, related_name="proyectos")
    nombre = models.CharField(max_length=255)
    codigo = models.CharField(max_length=50, null=True, blank=True)
    fecha_inicio = models.DateField(null=True, blank=True)
    fecha_fin = models.DateField(null=True, blank=True)
    descripcion = models.TextField(null=True, blank=True)
    costo_base = models.DecimalField(**MONTO, null=True, blank=True)
    costo_extra_diurno = models.DecimalField("costo por hora extra diurna", **MONTO, null=True, blank=True)
    costo_extra_nocturno = models.DecimalField("costo por hora extra nocturna", **MONTO, null=True, blank=True)
    estado = models.CharField(max_length=20, choices=Estado.choices, null=True, blank=True)
    ingeniero_supervisor = models.CharField(max_length=255, null=True, blank=True)
    ubicacion = models.TextField(null=True, blank=True)
    tecnicos = models.ManyToManyField(Empleado, through="ProyectoTecnico", related_name="proyectos_asignados", blank=True)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=Q(fecha_fin__gte=F("fecha_inicio")), name="proyecto_fechas_en_orden"),
            models.CheckConstraint(condition=Q(estado__in=["no_iniciado", "en_progreso", "completado"]), name="proyecto_estado_valido"),
            models.CheckConstraint(
                condition=Q(costo_base__gte=0) & Q(costo_extra_diurno__gte=0) & Q(costo_extra_nocturno__gte=0),
                name="proyecto_costos_no_negativos",
            ),
        ]

    def __str__(self):
        return self.nombre


class ProyectoTecnico(ModeloHijo):
    proyecto = models.ForeignKey(Proyecto, on_delete=models.CASCADE, related_name="asignaciones")
    # NULL solo si el empleado se borró después (en MongoDB la asignación quedaba
    # apuntando a un empleado inexistente).
    empleado = models.ForeignKey(Empleado, null=True, blank=True, on_delete=models.SET_NULL, related_name="asignaciones")

    class Meta(ModeloHijo.Meta):
        verbose_name = "técnico asignado"
        verbose_name_plural = "técnicos asignados"
        constraints = [
            models.UniqueConstraint(fields=["proyecto", "empleado"], name="proyecto_tecnico_unico"),
        ]


class AvanceProyecto(ModeloHijo):
    proyecto = models.ForeignKey(Proyecto, on_delete=models.CASCADE, related_name="avances")
    imagen_url = models.URLField(max_length=1000, null=True, blank=True)
    cloudinary_id = models.CharField(max_length=255, null=True, blank=True)
    # Cuenta que subió la imagen (puede ser un administrador o un empleado).
    subido_por = models.ForeignKey(Usuario, null=True, blank=True, on_delete=models.SET_NULL, related_name="avances_subidos")

    class Meta(ModeloHijo.Meta):
        verbose_name = "avance de proyecto"
        verbose_name_plural = "avances de proyecto"


class ReporteSemanal(ModeloBase):
    proyecto = models.ForeignKey(Proyecto, null=True, blank=True, on_delete=models.SET_NULL, related_name="reportes_semanales")
    reportado_por = models.ForeignKey(Empleado, null=True, blank=True, on_delete=models.SET_NULL, related_name="reportes_semanales")
    semana_termina = models.DateField(null=True, blank=True)
    notas = models.TextField(null=True, blank=True)
    estado = models.CharField(max_length=50, null=True, blank=True)
    enviado_en = models.DateTimeField(null=True, blank=True)

    class Meta:
        verbose_name = "reporte semanal"
        verbose_name_plural = "reportes semanales"


class RolDepartamento(ModeloBase):
    """
    Un rol dentro de un departamento (la pieza de «cada departamento con sus propios roles»).

    El permiso real lo lleva un grupo de Django (auth_group): así los permisos por modelo se
    administran con lo que ya trae Django y con el mismo mecanismo que usa Gestión GG, que
    guarda sus roles como grupos (gestion_ofertas, gestion_laboratorio...). Este modelo solo
    dice a qué departamento pertenece cada grupo y cómo se llama en palabras de la empresa.

    Para asignarle el rol a alguien se agrega su usuario al grupo (usuario.groups.add(grupo)),
    que es lo que ya leen los permisos de Django.

    La lista de departamentos y de roles de la empresa se carga con:
        python manage.py cargar_roles nucleo/roles_departamentos.json
    PENDIENTE: ese archivo está vacío a propósito, esperando la lista (ver PENDIENTES.md).
    """

    departamento = models.ForeignKey(
        Departamento, on_delete=models.CASCADE, related_name="roles"
    )
    grupo = models.OneToOneField(
        "auth.Group",
        on_delete=models.CASCADE,
        related_name="rol_departamento",
        help_text="Grupo de Django que lleva los permisos de este rol.",
    )
    codigo = models.SlugField(
        max_length=50, help_text="Nombre corto del rol dentro del departamento, por ejemplo jefe."
    )
    nombre = models.CharField(max_length=150)
    descripcion = models.TextField(null=True, blank=True)
    es_jefatura = models.BooleanField(
        default=False,
        db_default=False,
        help_text="Marca el rol que aprueba o autoriza dentro del departamento.",
    )
    es_supuesto = models.BooleanField(
        default=True,
        db_default=True,
        help_text="Queda en true mientras la empresa no confirme este rol.",
    )

    class Meta:
        verbose_name = "rol de departamento"
        verbose_name_plural = "roles de departamento"
        constraints = [
            models.UniqueConstraint(
                fields=["departamento", "codigo"], name="rol_unico_por_departamento"
            ),
        ]

    def __str__(self):
        return f"{self.departamento} · {self.nombre}"


class ContactoCliente(models.Model):
    """
    Personas de contacto de un cliente (antes core.contactos / lab.contactos_cliente del LIMS).
    La central solo tenía nucleo_cliente.contacto, un texto con un nombre. Se conservan las
    columnas de la Parte 3 del LIMS; `recibe_informes` marca a quién se envían los informes.
    Al borrar un cliente se borran sus contactos (igual que en la Parte 3).
    """

    id = models.UUIDField(primary_key=True, default=uuid7, db_default=RandomUUID(), editable=False)
    cliente = models.ForeignKey("Cliente", on_delete=models.CASCADE, related_name="contactos")
    nombre = models.CharField(max_length=255)
    cargo = models.CharField(max_length=150, null=True, blank=True)
    telefono = models.CharField(max_length=30, null=True, blank=True)
    correo = models.EmailField(max_length=254, null=True, blank=True)
    recibe_informes = models.BooleanField(default=False, db_default=False)
    creado_en = models.DateTimeField(default=timezone.now, db_default=Now())

    class Meta:
        verbose_name = "contacto de cliente"
        verbose_name_plural = "contactos de clientes"

    def __str__(self):
        return f"{self.nombre} ({self.cliente})"
