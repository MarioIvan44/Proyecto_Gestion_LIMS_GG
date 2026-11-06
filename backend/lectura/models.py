"""
Lectura de hojas del laboratorio: fotos subidas, lo que se leyó de cada celda,
lo que corrigió el revisor y lo que el sistema aprendió de esas correcciones.

Sigue las convenciones de toda la base (ver `nucleo/models.py`): UUID versión 7,
`datos_extra` y restricciones en la propia base.

Las imágenes son datos de clientes: se guardan en `LECTURA_MEDIA_ROOT` (fuera del
repositorio) y solo se entregan a usuarios con sesión iniciada.
"""

from django.db import models
from django.db.models import Q

from nucleo.models import Empleado, ModeloBase, Proyecto, Usuario

from .motor.confusiones import NUMERO, TEXTO
from .motor.plantillas import PLANTILLAS
from .motor.propuestas import ORIGENES

TIPOS_HOJA = [(p.tipo, p.nombre) for p in PLANTILLAS.values()]


def ruta_imagen(instancia, nombre_archivo):
    extension = nombre_archivo.rsplit(".", 1)[-1].lower() if "." in nombre_archivo else "bin"
    fecha = instancia.creado_en
    return f"lectura/{fecha:%Y}/{fecha:%m}/{instancia.id}.{extension}"


class HojaEscaneada(ModeloBase):
    class Estado(models.TextChoices):
        PENDIENTE = "pendiente", "Pendiente de leer"
        EN_REVISION = "en_revision", "En revisión"
        REVISADA = "revisada", "Revisada"
        ERROR = "error", "Error al leer"

    class Conjunto(models.TextChoices):
        # Las hojas de «prueba» no se usan para aprender: sirven para medir la
        # exactitud con hojas que el sistema no ha visto.
        ENTRENAMIENTO = "entrenamiento", "Entrenamiento"
        PRUEBA = "prueba", "Prueba"

    tipo = models.CharField("tipo de hoja", max_length=30, choices=TIPOS_HOJA)
    estado = models.CharField(max_length=20, choices=Estado.choices, default=Estado.PENDIENTE, db_default=Estado.PENDIENTE)
    conjunto = models.CharField(max_length=20, choices=Conjunto.choices, default=Conjunto.ENTRENAMIENTO, db_default=Conjunto.ENTRENAMIENTO)
    proyecto = models.ForeignKey(Proyecto, null=True, blank=True, on_delete=models.SET_NULL, related_name="hojas_escaneadas")
    folio = models.CharField(max_length=50, null=True, blank=True)
    imagen = models.FileField(upload_to=ruta_imagen, max_length=255)
    imagen_sha256 = models.CharField(
        max_length=64, unique=True,
        help_text="Huella de la imagen: evita subir dos veces la misma foto.",
    )
    imagen_tipo = models.CharField("tipo de archivo", max_length=50)
    proveedor = models.CharField("servicio de lectura", max_length=50, blank=True, default="", db_default="")
    version_plantilla = models.CharField(max_length=30, blank=True, default="", db_default="")
    respuesta_proveedor = models.JSONField(
        null=True, blank=True,
        help_text="Respuesta completa del servicio de lectura, para auditar y volver a procesar.",
    )
    error = models.TextField(null=True, blank=True)
    # Quien llenó la hoja a mano: la letra de cada técnico se confunde distinto.
    llenada_por = models.ForeignKey(Empleado, null=True, blank=True, on_delete=models.SET_NULL, related_name="hojas_llenadas")
    subida_por = models.ForeignKey(Usuario, null=True, blank=True, on_delete=models.SET_NULL, related_name="hojas_subidas")
    revisada_por = models.ForeignKey(Usuario, null=True, blank=True, on_delete=models.SET_NULL, related_name="hojas_revisadas")
    revisada_en = models.DateTimeField(null=True, blank=True)
    aprendida_en = models.DateTimeField(
        null=True, blank=True,
        help_text="Cuándo se aprendió de las correcciones de esta hoja.",
    )

    class Meta:
        verbose_name = "hoja escaneada"
        verbose_name_plural = "hojas escaneadas"
        ordering = ["-creado_en"]
        constraints = [
            models.CheckConstraint(condition=Q(tipo__in=list(PLANTILLAS)), name="hoja_tipo_valido"),
            models.CheckConstraint(
                condition=Q(estado__in=["pendiente", "en_revision", "revisada", "error"]), name="hoja_estado_valido",
            ),
            models.CheckConstraint(condition=Q(conjunto__in=["entrenamiento", "prueba"]), name="hoja_conjunto_valido"),
            models.CheckConstraint(
                condition=~Q(estado="revisada") | Q(revisada_en__isnull=False), name="hoja_revisada_con_fecha",
            ),
            models.CheckConstraint(condition=Q(imagen_sha256__regex=r"^[0-9a-f]{64}$"), name="hoja_sha256_valido"),
        ]
        indexes = [models.Index(fields=["estado", "tipo"])]

    def __str__(self):
        return f"{self.get_tipo_display()} {self.folio or self.id}"

    @property
    def plantilla(self):
        return PLANTILLAS[self.tipo]


class CampoLeido(ModeloBase):
    class Estado(models.TextChoices):
        PENDIENTE = "pendiente", "Pendiente"
        CONFIRMADO = "confirmado", "Confirmado"  # el valor final es la propuesta
        CORREGIDO = "corregido", "Corregido"  # el revisor escribió otro valor
        ILEGIBLE = "ilegible", "Ilegible"  # no se entiende ni viendo la foto

    hoja = models.ForeignKey(HojaEscaneada, on_delete=models.CASCADE, related_name="campos")
    fila = models.PositiveSmallIntegerField(help_text="0 = encabezado; 1, 2, 3... = renglones de la tabla.")
    campo = models.CharField(max_length=50)
    texto_leido = models.TextField(null=True, blank=True, help_text="Texto tal como lo devolvió el servicio.")
    confianza = models.DecimalField(
        max_digits=4, decimal_places=3, null=True, blank=True,
        help_text="Confianza del servicio de lectura, de 0 a 1.",
    )
    caja = models.JSONField(null=True, blank=True, help_text="Ubicación de la celda en la imagen (para resaltarla).")
    valor_propuesto = models.TextField(null=True, blank=True)
    origen_propuesta = models.CharField(max_length=20, choices=[(o, o) for o in ORIGENES])
    detalle_propuesta = models.JSONField(default=dict, db_default={}, blank=True)
    requiere_revision = models.BooleanField(default=True, db_default=True)
    motivos_revision = models.JSONField(default=list, db_default=[], blank=True)
    valor_final = models.TextField(null=True, blank=True)
    estado = models.CharField(max_length=20, choices=Estado.choices, default=Estado.PENDIENTE, db_default=Estado.PENDIENTE)
    motivo = models.TextField(null=True, blank=True, help_text="Por qué se corrigió (opcional, obligatorio fuera de la lista).")
    revisado_por = models.ForeignKey(Usuario, null=True, blank=True, on_delete=models.SET_NULL, related_name="campos_revisados")
    revisado_en = models.DateTimeField(null=True, blank=True)

    class Meta:
        verbose_name = "campo leído"
        verbose_name_plural = "campos leídos"
        ordering = ["fila", "campo"]
        constraints = [
            models.UniqueConstraint(fields=["hoja", "fila", "campo"], name="campo_leido_unico"),
            models.CheckConstraint(condition=Q(confianza__gte=0, confianza__lte=1), name="campo_confianza_0_a_1"),
            models.CheckConstraint(
                condition=Q(estado__in=["pendiente", "confirmado", "corregido", "ilegible"]), name="campo_estado_valido",
            ),
            models.CheckConstraint(condition=Q(origen_propuesta__in=list(ORIGENES)), name="campo_origen_valido"),
            models.CheckConstraint(
                condition=Q(estado="pendiente") | Q(revisado_en__isnull=False), name="campo_revisado_con_fecha",
            ),
        ]

    def __str__(self):
        return f"{self.hoja_id} fila {self.fila} {self.campo}"


class Sinonimo(ModeloBase):
    """
    Texto leído que el revisor cambió por un valor: «HINO» → «LIMO», «5M» → «SM».
    Se propone la próxima vez que aparezca el mismo texto, con la confiabilidad que
    dan sus confirmaciones y rechazos.
    """

    class Origen(models.TextChoices):
        APRENDIDO = "aprendido", "Aprendido de revisiones"
        CARGADO = "cargado", "Cargado por la empresa"  # glosario del laboratorio

    vocabulario = models.CharField(max_length=50, help_text="Lista a la que pertenece el valor, o «palabras» para texto libre.")
    clave = models.CharField(max_length=200, help_text="Texto leído, normalizado (mayúsculas, sin tildes).")
    valor = models.CharField(max_length=200)
    confirmaciones = models.PositiveIntegerField(default=0, db_default=0)
    rechazos = models.PositiveIntegerField(default=0, db_default=0)
    origen = models.CharField(max_length=20, choices=Origen.choices, default=Origen.APRENDIDO, db_default=Origen.APRENDIDO)

    class Meta:
        verbose_name = "sinónimo"
        constraints = [
            models.UniqueConstraint(fields=["vocabulario", "clave", "valor"], name="sinonimo_unico"),
            models.CheckConstraint(condition=Q(origen__in=["aprendido", "cargado"]), name="sinonimo_origen_valido"),
        ]

    def __str__(self):
        return f"{self.clave} → {self.valor} ({self.vocabulario})"


class ConfusionCaracter(ModeloBase):
    """
    Veces que se leyó un carácter y en realidad era otro (o el mismo). Hay filas
    generales (sin técnico) y filas por técnico que llenó la hoja.
    """

    tipo_campo = models.CharField(max_length=10, choices=[(NUMERO, "Número"), (TEXTO, "Texto")])
    escritor = models.ForeignKey(Empleado, null=True, blank=True, on_delete=models.CASCADE, related_name="confusiones")
    leido = models.CharField(max_length=1)
    real = models.CharField(max_length=1)
    veces = models.PositiveIntegerField(default=0, db_default=0)

    class Meta:
        verbose_name = "confusión de caracteres"
        verbose_name_plural = "confusiones de caracteres"
        constraints = [
            models.UniqueConstraint(
                fields=["tipo_campo", "leido", "real"], condition=Q(escritor__isnull=True), name="confusion_general_unica",
            ),
            models.UniqueConstraint(
                fields=["tipo_campo", "escritor", "leido", "real"], condition=Q(escritor__isnull=False),
                name="confusion_escritor_unica",
            ),
            models.CheckConstraint(condition=Q(tipo_campo__in=[NUMERO, TEXTO]), name="confusion_tipo_valido"),
        ]
