"""
App `lab`: el LIMS (laboratorio de materiales y geotecnia) dentro del backend Django.

Las tablas viven en el esquema `lab` de la misma base central y las crea el SQL de
lab/sql/0001_lims.sql (migración lab/migrations/0001_initial.py). Estos modelos son
`managed = False`: Django consulta y escribe con ellos, pero no genera ni modifica el DDL.
Se hizo así porque el esquema del LIMS usa cosas que las migraciones de Django no generan:
llaves foráneas compuestas, columnas calculadas, tipos enum propios, triggers y vistas.

Cómo leer los db_table: 'lab"."ensayos' es la forma de escribir lab.ensayos en Django, que
cita el nombre completo como "lab"."ensayos". No es un error de tipeo.

Las reglas de negocio siguen en la base (triggers): solo el supervisor aprueba, un ensayo
aprobado no se corrige sin motivo, el historial de ubicaciones y la auditoría. Para que la base
sepa quién está trabajando, el backend fija lab.usuario_id en cada transacción; eso lo hace
lab/middleware.py. Sin esa variable los triggers dejan pasar los cambios (sirve para
migraciones y scripts) pero no registran autor en la auditoría.

Los campos *_path son FileField con el almacenamiento de Cloudinary (ver DEFAULT_FILE_STORAGE
en config/settings/base.py). La columna en la base sigue siendo text y guarda la ruta que
devuelve Cloudinary; por eso llevan max_length alto y conservan su nombre original.
"""

import uuid

from django.contrib.postgres.fields import ArrayField
from django.db import models
from django.db.models import F, Func, Value
from django.db.models.functions import Now, NullIf, Round

from lab.storages import almacenamiento_lab


def ahora_en_bd():
    """now(): el valor por defecto de las columnas de fecha en el esquema lab."""
    return Now()


def numero():
    """numeric sin precisión fija, como lo declara el esquema lab."""
    return models.DecimalField(max_digits=None, decimal_places=None)


class SinGestion(models.Model):
    """Base de los modelos del esquema lab: Django no genera DDL para ellos."""

    class Meta:
        abstract = True
        managed = False


class IdUuidLab(SinGestion):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    class Meta(SinGestion.Meta):
        abstract = True


# =====================================================================
#  Catálogos
# =====================================================================
class Area(SinGestion):
    """Ensayos a materiales / Geotecnia."""

    id = models.SmallAutoField(primary_key=True)
    nombre = models.TextField(unique=True)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."areas'
        verbose_name = "área"

    def __str__(self):
        return self.nombre


class CategoriaMaterial(SinGestion):
    """Concreto, mortero, suelo, arena, grava, acero, lodocreto, bloques..."""

    id = models.SmallAutoField(primary_key=True)
    area = models.ForeignKey(Area, on_delete=models.PROTECT, related_name="categorias")
    nombre = models.TextField(unique=True)
    activo = models.BooleanField(default=True)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."categorias_material'
        verbose_name = "categoría de material"
        verbose_name_plural = "categorías de material"

    def __str__(self):
        return self.nombre


class TipoEspecimen(SinGestion):
    """Códigos de la hoja de programación (CC, CM, PG, BRQ, V). Significado por confirmar."""

    class Forma(models.TextChoices):
        CILINDRO = "cilindro", "Cilindro"
        CUBO = "cubo", "Cubo"
        NUCLEO = "nucleo", "Núcleo"
        VIGA = "viga", "Viga"

    id = models.SmallAutoField(primary_key=True)
    codigo = models.TextField(unique=True)
    nombre = models.TextField()
    categoria = models.ForeignKey(
        CategoriaMaterial, on_delete=models.PROTECT, related_name="tipos_especimen"
    )
    forma = models.TextField(choices=Forma.choices)
    notas = models.TextField(null=True, blank=True)
    activo = models.BooleanField(default=True)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."tipos_especimen'
        verbose_name = "tipo de espécimen"
        verbose_name_plural = "tipos de espécimen"

    def __str__(self):
        return f"{self.codigo} · {self.nombre}"


class Norma(SinGestion):
    id = models.SmallAutoField(primary_key=True)
    codigo = models.TextField(unique=True)
    titulo = models.TextField(null=True, blank=True)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."normas'

    def __str__(self):
        return self.codigo


class MetodoEnsayo(SinGestion):
    """tipo_resultado decide dónde se guardan los datos del ensayo."""

    class TipoResultado(models.TextChoices):
        COMPRESION = "compresion", "Compresión (resultados_compresion)"
        GENERICO = "generico", "Genérico (mediciones)"

    id = models.SmallAutoField(primary_key=True)
    nombre = models.TextField(unique=True)
    area = models.ForeignKey(Area, on_delete=models.PROTECT, related_name="metodos")
    norma = models.ForeignKey(
        Norma, on_delete=models.PROTECT, null=True, blank=True, related_name="metodos"
    )
    tipo_resultado = models.TextField(choices=TipoResultado.choices)
    unidad_resultado = models.TextField(null=True, blank=True)
    activo = models.BooleanField(default=True)
    tipos_especimen = models.ManyToManyField(
        TipoEspecimen, through="MetodoTipoEspecimen", related_name="metodos"
    )

    class Meta(SinGestion.Meta):
        db_table = 'lab"."metodos_ensayo'
        verbose_name = "método de ensayo"
        verbose_name_plural = "métodos de ensayo"

    def __str__(self):
        return self.nombre


class MetodoTipoEspecimen(SinGestion):
    """Qué tipos de espécimen admite cada método."""

    pk = models.CompositePrimaryKey("metodo_id", "tipo_especimen_id")
    metodo = models.ForeignKey(MetodoEnsayo, on_delete=models.CASCADE)
    tipo_especimen = models.ForeignKey(TipoEspecimen, on_delete=models.CASCADE)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."metodo_tipos_especimen'


class ParametroMetodo(SinGestion):
    """Parámetros configurables por método (los definen los técnicos)."""

    class TipoDato(models.TextChoices):
        NUMERO = "numero", "Número"
        TEXTO = "texto", "Texto"
        BOOLEANO = "booleano", "Booleano"

    id = models.SmallAutoField(primary_key=True)
    metodo = models.ForeignKey(MetodoEnsayo, on_delete=models.CASCADE, related_name="parametros")
    nombre = models.TextField()
    unidad = models.TextField(null=True, blank=True)
    tipo_dato = models.TextField(choices=TipoDato.choices, default=TipoDato.NUMERO)
    requerido = models.BooleanField(default=True)
    repeticiones = models.SmallIntegerField(default=1)
    es_resultado = models.BooleanField(
        default=False, help_text="El valor principal que va al informe."
    )
    valor_min = models.DecimalField(max_digits=None, decimal_places=None, null=True, blank=True)
    valor_max = models.DecimalField(max_digits=None, decimal_places=None, null=True, blank=True)
    orden = models.SmallIntegerField(default=0)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."parametros_metodo'
        verbose_name = "parámetro de método"
        verbose_name_plural = "parámetros de método"

    def __str__(self):
        return f"{self.metodo_id} · {self.nombre}"


class TipoFalla(SinGestion):
    """Columna «Tipo falla» del formato M10-REG01."""

    codigo = models.SmallIntegerField(primary_key=True)
    descripcion = models.TextField()

    class Meta(SinGestion.Meta):
        db_table = 'lab"."tipos_falla'
        verbose_name = "tipo de falla"
        verbose_name_plural = "tipos de falla"

    def __str__(self):
        return f"{self.codigo} · {self.descripcion}"


class ProveedorMaterial(IdUuidLab):
    """Procedencia del concreto/mortero (PAVICON, elaborado en obra, etc.)."""

    nombre = models.TextField(unique=True)
    es_obra = models.BooleanField(default=False)
    activo = models.BooleanField(default=True)
    creado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."proveedores_material'
        verbose_name = "proveedor de material"
        verbose_name_plural = "proveedores de material"

    def __str__(self):
        return self.nombre


# =====================================================================
#  Equipos y ubicaciones físicas
# =====================================================================
class Equipo(IdUuidLab):
    codigo = models.TextField(unique=True)
    nombre = models.TextField(help_text='Por ejemplo "Prensa FORNEY VFD Automatic".')
    marca = models.TextField(null=True, blank=True)
    modelo = models.TextField(null=True, blank=True)
    serie = models.TextField(null=True, blank=True)
    tipo = models.TextField(null=True, blank=True)
    activo = models.BooleanField(default=True)
    creado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."equipos'

    def __str__(self):
        return f"{self.codigo} · {self.nombre}"


class Calibracion(IdUuidLab):
    equipo = models.ForeignKey(Equipo, on_delete=models.CASCADE, related_name="calibraciones")
    fecha = models.DateField()
    vence = models.DateField(null=True, blank=True)
    entidad = models.TextField(null=True, blank=True)
    certificado_path = models.FileField(
        storage=almacenamiento_lab,
        upload_to="lab/calibraciones/", max_length=1000, null=True, blank=True
    )
    observaciones = models.TextField(null=True, blank=True)

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."calibraciones'
        verbose_name = "calibración"
        verbose_name_plural = "calibraciones"


class Ubicacion(IdUuidLab):
    """Jerarquía: cuarto/pila → bidón o estante → peldaño."""

    class Tipo(models.TextChoices):
        BIDON = "bidon", "Bidón"
        ESTANTE = "estante", "Estante"
        PELDANO = "peldano", "Peldaño"

    padre = models.ForeignKey(
        "self", on_delete=models.PROTECT, null=True, blank=True, related_name="hijas"
    )
    tipo = models.TextField(choices=Tipo.choices)
    codigo = models.TextField()
    nombre = models.TextField(null=True, blank=True)
    activa = models.BooleanField(default=True)

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."ubicaciones'
        verbose_name = "ubicación"
        verbose_name_plural = "ubicaciones"

    def __str__(self):
        return self.nombre or self.codigo


# =====================================================================
#  Recepción: remisión → muestra (colado) → espécimen
# =====================================================================
class Remision(IdUuidLab):
    codigo = models.TextField(unique=True, null=True, blank=True)
    formato = models.TextField(default="P8-REG03")
    proyecto = models.ForeignKey(
        "nucleo.Proyecto", on_delete=models.PROTECT, related_name="remisiones_lab"
    )
    fecha_remision = models.DateField()
    entregado_por_empleado = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="entregado_por_empleado",
    )
    entregado_por_nombre = models.TextField(
        null=True, blank=True, help_text="Por si quien entrega no es empleado."
    )
    recibido_campo_por = models.TextField(null=True, blank=True)
    recibido_lab_por = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="recibido_lab_por",
    )
    recibido_en = models.DateTimeField(null=True, blank=True)
    documento_path = models.FileField(
        storage=almacenamiento_lab,
        upload_to="lab/remisiones/", max_length=1000, null=True, blank=True,
        help_text="Foto o escaneo de la hoja firmada.",
    )
    observaciones = models.TextField(null=True, blank=True)
    creado_por = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="creado_por",
    )
    creado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)
    actualizado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."remisiones'
        verbose_name = "remisión"
        verbose_name_plural = "remisiones"

    def __str__(self):
        return self.codigo or str(self.id)


class Muestra(IdUuidLab):
    """
    Un colado. En la base, (remision_id, proyecto_id) es una llave foránea compuesta a
    lab.remisiones(id, proyecto_id): el proyecto de la muestra debe ser el de su remisión.
    Django no maneja llaves compuestas, así que esas dos FK van con db_constraint=False
    (la restricción ya existe en la base y es ella la que valida).
    """

    class RequisitoTipo(models.TextChoices):
        FC = "fc", "f'c (resistencia a compresión)"
        MR = "mr", "Módulo de ruptura"

    remision = models.ForeignKey(
        Remision, on_delete=models.PROTECT, related_name="muestras", db_constraint=False
    )
    proyecto = models.ForeignKey(
        "nucleo.Proyecto", on_delete=models.PROTECT, related_name="muestras_lab", db_constraint=False
    )
    tipo_especimen = models.ForeignKey(
        TipoEspecimen, on_delete=models.PROTECT, related_name="muestras"
    )
    elemento_colado = models.TextField(
        help_text='Por ejemplo "Losa de fundación de piscina torre A".'
    )
    fecha_elaboracion = models.DateField(help_text="Fecha de colado.")
    hora_elaboracion = models.TimeField(null=True, blank=True)
    requisito_tipo = models.TextField(choices=RequisitoTipo.choices, default=RequisitoTipo.FC)
    resistencia_requerida = models.DecimalField(
        max_digits=8, decimal_places=2, null=True, blank=True
    )
    unidad_requerida = models.TextField(default="kg/cm2")
    revenimiento_in = models.DecimalField(max_digits=5, decimal_places=2, null=True, blank=True)
    temperatura_c = models.DecimalField(max_digits=5, decimal_places=2, null=True, blank=True)
    proveedor = models.ForeignKey(
        ProveedorMaterial, on_delete=models.PROTECT, null=True, blank=True, related_name="muestras"
    )
    comentario = models.TextField(null=True, blank=True)
    creado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)
    actualizado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."muestras'

    def __str__(self):
        return f"{self.elemento_colado} ({self.fecha_elaboracion})"


class Especimen(IdUuidLab):
    """
    proyecto y tipo_especimen están repetidos a propósito (vienen de la muestra): así la base
    puede exigir que el número no se repita dentro del mismo proyecto y tipo. La coherencia con
    la muestra la valida una llave foránea compuesta en la base, por eso estas tres FK van con
    db_constraint=False.

    fecha_ensayo_programada la calcula un trigger (fecha de colado + edad) si se deja vacía.
    """

    class Estado(models.TextChoices):
        RECIBIDO = "recibido", "Recibido"
        ALMACENADO = "almacenado", "Almacenado"
        ENSAYADO = "ensayado", "Ensayado"

    muestra = models.ForeignKey(
        Muestra, on_delete=models.PROTECT, related_name="especimenes", db_constraint=False
    )
    proyecto = models.ForeignKey(
        "nucleo.Proyecto",
        on_delete=models.PROTECT,
        related_name="especimenes_lab",
        db_constraint=False,
    )
    tipo_especimen = models.ForeignKey(
        TipoEspecimen, on_delete=models.PROTECT, related_name="especimenes", db_constraint=False
    )
    numero = models.TextField(help_text='Número asignado en campo, por ejemplo "769".')
    edad_programada_dias = models.SmallIntegerField()
    fecha_ensayo_programada = models.DateField(
        blank=True, help_text="Si se deja vacía la calcula la base: colado + edad."
    )
    peso_g = models.DecimalField(max_digits=9, decimal_places=2, null=True, blank=True)
    diametro_1_mm = models.DecimalField(max_digits=7, decimal_places=2, null=True, blank=True)
    diametro_2_mm = models.DecimalField(max_digits=7, decimal_places=2, null=True, blank=True)
    altura_1_mm = models.DecimalField(max_digits=7, decimal_places=2, null=True, blank=True)
    altura_2_mm = models.DecimalField(max_digits=7, decimal_places=2, null=True, blank=True)
    largo_mm = models.DecimalField(
        max_digits=7, decimal_places=2, null=True, blank=True, help_text="Cubos y bloques."
    )
    ancho_mm = models.DecimalField(
        max_digits=7, decimal_places=2, null=True, blank=True, help_text="Cubos y bloques."
    )
    estado = models.TextField(choices=Estado.choices, default=Estado.RECIBIDO)
    ubicacion = models.ForeignKey(
        Ubicacion, on_delete=models.PROTECT, null=True, blank=True, related_name="especimenes"
    )
    observaciones = models.TextField(null=True, blank=True)
    creado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)
    actualizado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."especimenes'
        verbose_name = "espécimen"
        verbose_name_plural = "especímenes"

    def __str__(self):
        return self.numero


class MovimientoEspecimen(SinGestion):
    """Historial de bidón/estante/peldaño. Lo llena un trigger al cambiar la ubicación."""

    id = models.BigAutoField(primary_key=True)
    especimen = models.ForeignKey(Especimen, on_delete=models.CASCADE, related_name="movimientos")
    ubicacion = models.ForeignKey(
        Ubicacion, on_delete=models.PROTECT, null=True, blank=True, related_name="movimientos"
    )
    movido_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)
    movido_por = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="movido_por",
    )
    nota = models.TextField(null=True, blank=True)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."movimientos_especimen'
        verbose_name = "movimiento de espécimen"
        verbose_name_plural = "movimientos de espécimen"


# =====================================================================
#  Ensayos y resultados
# =====================================================================
class Importacion(IdUuidLab):
    """Archivos de los equipos (CSV de la prensa FORNEY)."""

    class Estado(models.TextChoices):
        CARGADO = "cargado", "Cargado"
        VALIDADO = "validado", "Validado"
        CON_ERRORES = "con_errores", "Con errores"
        APLICADO = "aplicado", "Aplicado"
        DESCARTADO = "descartado", "Descartado"

    equipo = models.ForeignKey(
        Equipo, on_delete=models.PROTECT, null=True, blank=True, related_name="importaciones"
    )
    archivo_path = models.FileField(
        storage=almacenamiento_lab, upload_to="lab/importaciones/", max_length=1000
    )
    archivo_sha256 = models.TextField(
        unique=True, help_text="Evita importar dos veces el mismo archivo."
    )
    estado = models.TextField(choices=Estado.choices, default=Estado.CARGADO)
    filas_total = models.IntegerField(null=True, blank=True)
    filas_validas = models.IntegerField(null=True, blank=True)
    importado_por = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="importado_por",
    )
    importado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)
    notas = models.TextField(null=True, blank=True)

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."importaciones'
        verbose_name = "importación"
        verbose_name_plural = "importaciones"


class ImportacionFila(SinGestion):
    class Estado(models.TextChoices):
        PENDIENTE = "pendiente", "Pendiente"
        OK = "ok", "OK"
        ERROR = "error", "Error"
        DUPLICADO = "duplicado", "Duplicado"
        APLICADA = "aplicada", "Aplicada"

    id = models.BigAutoField(primary_key=True)
    importacion = models.ForeignKey(Importacion, on_delete=models.CASCADE, related_name="filas")
    numero_fila = models.IntegerField()
    datos = models.JSONField(help_text="La fila cruda tal como venía en el CSV.")
    especimen = models.ForeignKey(
        Especimen,
        on_delete=models.PROTECT,
        null=True,
        blank=True,
        related_name="filas_importadas",
    )
    estado = models.TextField(choices=Estado.choices, default=Estado.PENDIENTE)
    errores = ArrayField(models.TextField(), null=True, blank=True)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."importacion_filas'
        verbose_name = "fila de importación"
        verbose_name_plural = "filas de importación"


class Ensayo(IdUuidLab):
    """
    Una ejecución de un método sobre un espécimen (un espécimen se rompe una sola vez por
    método). Los triggers de la base calculan la edad real, exigen rol de supervisor para
    aprobar y piden un motivo para corregir un ensayo ya aprobado.
    """

    class Estado(models.TextChoices):
        PENDIENTE = "pendiente", "Pendiente"
        EN_PROCESO = "en_proceso", "En proceso"
        COMPLETADO = "completado", "Completado"
        EN_REVISION = "en_revision", "En revisión"
        APROBADO = "aprobado", "Aprobado"

    class Origen(models.TextChoices):
        MANUAL = "manual", "Manual"
        IMPORTACION = "importacion", "Importación"

    especimen = models.ForeignKey(Especimen, on_delete=models.PROTECT, related_name="ensayos")
    metodo = models.ForeignKey(MetodoEnsayo, on_delete=models.PROTECT, related_name="ensayos")
    fecha_programada = models.DateField(
        blank=True, help_text="Si se deja vacía la toma de la fecha programada del espécimen."
    )
    ejecutado_en = models.DateTimeField(null=True, blank=True)
    edad_real_dias = models.SmallIntegerField(
        null=True, blank=True, help_text="La calcula la base al registrar ejecutado_en."
    )
    tecnico = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+"
    )
    equipo = models.ForeignKey(
        Equipo, on_delete=models.PROTECT, null=True, blank=True, related_name="ensayos"
    )
    estado = models.TextField(choices=Estado.choices, default=Estado.PENDIENTE)
    origen = models.TextField(choices=Origen.choices, default=Origen.MANUAL)
    importacion_fila = models.ForeignKey(
        ImportacionFila, on_delete=models.PROTECT, null=True, blank=True, related_name="ensayos"
    )
    revisado_por = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="revisado_por",
    )
    revisado_en = models.DateTimeField(null=True, blank=True)
    aprobado_por = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="aprobado_por",
    )
    aprobado_en = models.DateTimeField(null=True, blank=True)
    observaciones = models.TextField(null=True, blank=True)
    creado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)
    actualizado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."ensayos'

    def __str__(self):
        return f"{self.especimen_id} · {self.metodo_id}"


class ResultadoCompresion(SinGestion):
    """
    Datos del formato M10-REG01. resistencia_kgcm2, resistencia_mpa y ganancia_pct las calcula
    PostgreSQL (columnas generadas): se leen, no se escriben.
    resistencia_requerida_kgcm2 y area_mm2 las llena un trigger si llegan vacías.
    """

    ensayo = models.OneToOneField(
        Ensayo, on_delete=models.CASCADE, primary_key=True, related_name="resultado_compresion"
    )
    carga_kn = models.DecimalField(max_digits=10, decimal_places=2)
    tipo_falla = models.ForeignKey(
        TipoFalla, on_delete=models.PROTECT, null=True, blank=True, related_name="resultados",
        db_column="tipo_falla",
    )
    resistencia_requerida_kgcm2 = models.DecimalField(
        max_digits=8,
        decimal_places=2,
        null=True,
        blank=True,
        help_text="Copia de la muestra al ensayar: queda congelada.",
    )
    area_mm2 = models.DecimalField(
        max_digits=10, decimal_places=2, blank=True, help_text="Si llega vacía la calcula la base."
    )
    # Las tres columnas de abajo son `generated always as ... stored` en PostgreSQL: las calcula
    # la base y no se pueden escribir. Las expresiones son la copia en Django de las fórmulas de
    # lab/sql/0001_lims.sql, que es la que manda; Django las usa para saber de qué columnas
    # dependen y volver a leerlas después de guardar. Si allá cambia una fórmula, cambiarla aquí.
    #   resistencia_kgcm2 = lab.resistencia_kgcm2(carga_kn, area_mm2)
    resistencia_kgcm2 = models.GeneratedField(
        expression=Func(
            F("carga_kn"), F("area_mm2"), function="lab.resistencia_kgcm2", output_field=numero()
        ),
        output_field=numero(),
        db_persist=True,
    )
    #   resistencia_mpa = round(carga_kn * 1000 / nullif(area_mm2, 0), 2)
    resistencia_mpa = models.GeneratedField(
        expression=Round(F("carga_kn") * Value(1000) / NullIf(F("area_mm2"), Value(0)), 2),
        output_field=numero(),
        db_persist=True,
    )
    #   ganancia_pct = round(lab.resistencia_kgcm2(carga_kn, area_mm2)
    #                        / nullif(resistencia_requerida_kgcm2, 0) * 100, 1)
    ganancia_pct = models.GeneratedField(
        expression=Round(
            Func(
                F("carga_kn"),
                F("area_mm2"),
                function="lab.resistencia_kgcm2",
                output_field=numero(),
            )
            / NullIf(F("resistencia_requerida_kgcm2"), Value(0))
            * Value(100),
            1,
        ),
        output_field=numero(),
        db_persist=True,
    )
    actualizado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."resultados_compresion'
        verbose_name = "resultado de compresión"
        verbose_name_plural = "resultados de compresión"


class Medicion(SinGestion):
    """Mediciones genéricas de cualquier otro método (geotecnia, agregados...)."""

    id = models.BigAutoField(primary_key=True)
    ensayo = models.ForeignKey(Ensayo, on_delete=models.CASCADE, related_name="mediciones")
    parametro = models.ForeignKey(
        ParametroMetodo, on_delete=models.PROTECT, related_name="mediciones"
    )
    repeticion = models.SmallIntegerField(default=1)
    valor_num = models.DecimalField(max_digits=None, decimal_places=None, null=True, blank=True)
    valor_texto = models.TextField(null=True, blank=True)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."mediciones'
        verbose_name = "medición"
        verbose_name_plural = "mediciones"


# =====================================================================
#  Informes y archivos
# =====================================================================
class Informe(IdUuidLab):
    class Tipo(models.TextChoices):
        DIARIO = "diario", "Diario"
        MENSUAL = "mensual", "Mensual"

    class Estado(models.TextChoices):
        BORRADOR = "borrador", "Borrador"
        EMITIDO = "emitido", "Emitido"
        ANULADO = "anulado", "Anulado"

    codigo = models.TextField(unique=True, null=True, blank=True)
    tipo = models.TextField(choices=Tipo.choices)
    proyecto = models.ForeignKey(
        "nucleo.Proyecto",
        on_delete=models.PROTECT,
        null=True,
        blank=True,
        related_name="informes_lab",
        help_text="Vacío en el informe diario general.",
    )
    fecha_desde = models.DateField()
    fecha_hasta = models.DateField()
    conclusiones = models.TextField(null=True, blank=True)
    recomendaciones = models.TextField(null=True, blank=True)
    estado = models.TextField(choices=Estado.choices, default=Estado.BORRADOR)
    archivo_pdf_path = models.FileField(
        storage=almacenamiento_lab,
        upload_to="lab/informes/", max_length=1000, null=True, blank=True
    )
    datos_congelados = models.JSONField(
        null=True, blank=True, help_text="Foto de los datos al emitir."
    )
    elaborado_por = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="elaborado_por",
    )
    aprobado_por = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="aprobado_por",
    )
    emitido_en = models.DateTimeField(null=True, blank=True)
    creado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)
    actualizado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)
    ensayos = models.ManyToManyField(Ensayo, through="InformeEnsayo", related_name="informes")

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."informes'

    def __str__(self):
        return self.codigo or str(self.id)


class InformeEnsayo(SinGestion):
    pk = models.CompositePrimaryKey("informe_id", "ensayo_id")
    informe = models.ForeignKey(Informe, on_delete=models.CASCADE)
    ensayo = models.ForeignKey(Ensayo, on_delete=models.PROTECT)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."informe_ensayos'


class Adjunto(IdUuidLab):
    """
    Archivo suelto de cualquier entidad del laboratorio. La base no tiene llave foránea para
    entidad_id (apunta a tablas distintas según `entidad`), así que la coherencia la cuida el
    código que crea el adjunto.
    """

    class Entidad(models.TextChoices):
        REMISION = "remision", "Remisión"
        MUESTRA = "muestra", "Muestra"
        ESPECIMEN = "especimen", "Espécimen"
        ENSAYO = "ensayo", "Ensayo"
        INFORME = "informe", "Informe"
        EQUIPO = "equipo", "Equipo"

    entidad = models.TextField(choices=Entidad.choices)
    entidad_id = models.UUIDField()
    storage_path = models.FileField(
        storage=almacenamiento_lab, upload_to="lab/adjuntos/", max_length=1000
    )
    nombre_original = models.TextField(null=True, blank=True)
    mime = models.TextField(null=True, blank=True)
    tamano_bytes = models.BigIntegerField(null=True, blank=True)
    subido_por = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="subido_por",
    )
    subido_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)

    class Meta(IdUuidLab.Meta):
        db_table = 'lab"."adjuntos'


# =====================================================================
#  Seguridad y auditoría
# =====================================================================
class UsuarioRol(SinGestion):
    """
    Roles del LIMS (lab.usuarios_roles). Los usan los triggers de la base: solo quien tiene
    'supervisor' (o 'administrador') puede aprobar resultados.

    Es aparte de los permisos por departamento de Django: estos cinco roles son del laboratorio
    y los lee PostgreSQL; los de Django controlan qué puede hacer cada quien en la aplicación.
    """

    class Rol(models.TextChoices):
        ADMINISTRADOR = "administrador", "Administrador"
        RECEPCION = "recepcion", "Recepción"
        TECNICO = "tecnico", "Técnico"
        SUPERVISOR = "supervisor", "Supervisor"
        CONSULTA = "consulta", "Consulta"

    pk = models.CompositePrimaryKey("empleado_id", "rol")
    empleado = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.CASCADE, related_name="roles_lab"
    )
    rol = models.TextField(choices=Rol.choices)
    asignado_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)
    asignado_por = models.ForeignKey(
        "nucleo.Empleado", on_delete=models.PROTECT, null=True, blank=True, related_name="+",
        db_column="asignado_por",
    )

    class Meta(SinGestion.Meta):
        db_table = 'lab"."usuarios_roles'
        verbose_name = "rol de usuario del laboratorio"
        verbose_name_plural = "roles de usuario del laboratorio"


class Auditoria(SinGestion):
    """
    Bitácora que llenan los triggers. Solo se lee desde Django.
    usuario_auth_id conserva su nombre del LIMS original, pero guarda el id de nucleo_usuario
    (sin llave foránea, a propósito: la bitácora sobrevive al borrado de un usuario).
    """

    id = models.BigAutoField(primary_key=True)
    tabla = models.TextField()
    registro_id = models.TextField(null=True, blank=True)
    accion = models.TextField()
    antes = models.JSONField(null=True, blank=True)
    despues = models.JSONField(null=True, blank=True)
    motivo = models.TextField(null=True, blank=True)
    usuario_auth_id = models.UUIDField(null=True, blank=True)
    ocurrido_en = models.DateTimeField(db_default=ahora_en_bd(), editable=False)

    class Meta(SinGestion.Meta):
        db_table = 'lab"."auditoria'
        verbose_name = "auditoría"
        verbose_name_plural = "auditoría"


# =====================================================================
#  Vistas (solo lectura)
# =====================================================================
# Las define lab/sql/0001_lims.sql. Son `managed = False` igual que las tablas, y además no se
# escriben: sirven para las pantallas de programación del día, el reporte de resultados y la
# gráfica de resistencia contra edad. El `id` que declara cada una es solo para que Django
# tenga llave primaria; no existe como columna nueva.
class SoloLectura(SinGestion):
    class Meta(SinGestion.Meta):
        abstract = True

    def save(self, *args, **kwargs):  # pragma: no cover
        raise NotImplementedError(f"{type(self).__name__} es una vista de solo lectura.")

    def delete(self, *args, **kwargs):  # pragma: no cover
        raise NotImplementedError(f"{type(self).__name__} es una vista de solo lectura.")


class VistaProgramacionEnsayos(SoloLectura):
    """Lista del día: filtrar por fecha_ensayo_programada = hoy."""

    especimen_id = models.UUIDField(primary_key=True)
    fecha_ensayo_programada = models.DateField()
    proyecto = models.TextField()
    numero = models.TextField()
    fecha_colado = models.DateField()
    edad = models.SmallIntegerField()
    tipo = models.TextField()
    resistencia_requerida = models.DecimalField(max_digits=8, decimal_places=2, null=True)
    requisito_tipo = models.TextField()
    ubicacion = models.TextField(null=True)
    estado = models.TextField()

    class Meta(SoloLectura.Meta):
        db_table = 'lab"."v_programacion_ensayos'
        verbose_name = "programación de ensayos"
        verbose_name_plural = "programación de ensayos"


class VistaResultadosCompresion(SoloLectura):
    """Reporte de resultados de compresión, con cliente y proyecto de la base central."""

    ensayo_id = models.UUIDField(primary_key=True)
    cliente = models.TextField(null=True)
    proyecto = models.TextField()
    elemento_colado = models.TextField()
    tipo = models.TextField()
    especimen = models.TextField()
    fecha_colado = models.DateField()
    fecha_ensayo = models.DateField(null=True)
    edad = models.SmallIntegerField(null=True)
    peso_g = models.DecimalField(max_digits=9, decimal_places=2, null=True)
    diametro_prom_mm = models.DecimalField(max_digits=None, decimal_places=None, null=True)
    altura_prom_mm = models.DecimalField(max_digits=None, decimal_places=None, null=True)
    area_mm2 = models.DecimalField(max_digits=10, decimal_places=2)
    carga_kn = models.DecimalField(max_digits=10, decimal_places=2)
    resistencia_kgcm2 = models.DecimalField(max_digits=None, decimal_places=None, null=True)
    resistencia_mpa = models.DecimalField(max_digits=None, decimal_places=None, null=True)
    resistencia_requerida_kgcm2 = models.DecimalField(max_digits=8, decimal_places=2, null=True)
    ganancia_pct = models.DecimalField(max_digits=None, decimal_places=None, null=True)
    tipo_falla = models.SmallIntegerField(null=True)
    estado = models.TextField()

    class Meta(SoloLectura.Meta):
        db_table = 'lab"."v_resultados_compresion'
        verbose_name = "resultado de compresión (vista)"
        verbose_name_plural = "resultados de compresión (vista)"


class VistaCurvaResistencia(SoloLectura):
    """Curva resistencia vs edad por colado (gráfica de 3, 7 y 28 días)."""

    muestra_id = models.UUIDField(primary_key=True)
    proyecto_id = models.UUIDField()
    elemento_colado = models.TextField()
    fecha_colado = models.DateField()
    resistencia_requerida = models.DecimalField(max_digits=8, decimal_places=2, null=True)
    edad = models.SmallIntegerField(null=True)
    n_especimenes = models.BigIntegerField()
    resistencia_promedio = models.DecimalField(max_digits=None, decimal_places=None, null=True)
    ganancia_promedio = models.DecimalField(max_digits=None, decimal_places=None, null=True)

    class Meta(SoloLectura.Meta):
        db_table = 'lab"."v_curva_resistencia'
        verbose_name = "curva de resistencia"
        verbose_name_plural = "curvas de resistencia"
