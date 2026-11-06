"""
Recursos humanos: contratos, horas extra, planillas y boletas de pago.

Las líneas de planilla siguen las columnas de la hoja «PLANILLA» del Excel de la
empresa (en el backend Node: src/utils/payrollFormulas.js).
"""

from django.db import models
from django.db.models import F, Q

from nucleo.models import HORAS, MONTO, Departamento, Empleado, ModeloBase, Proyecto, Usuario


class Contrato(ModeloBase):
    # NULL solo si el empleado se borró después (en el sistema original el contrato quedaba
    # apuntando a un empleado inexistente). La migración exige que exista.
    empleado = models.ForeignKey(Empleado, null=True, blank=True, on_delete=models.SET_NULL, related_name="contratos")
    tipo = models.CharField("tipo de contrato", max_length=100, null=True, blank=True)
    fecha_inicio = models.DateField(null=True, blank=True)
    fecha_fin = models.DateField(null=True, blank=True)
    salario = models.DecimalField(**MONTO, null=True, blank=True)
    hora_entrada = models.TimeField(null=True, blank=True)
    hora_salida = models.TimeField(null=True, blank=True)
    horas_jornada = models.DecimalField(**HORAS, null=True, blank=True)
    clausulas = models.TextField("cláusulas", null=True, blank=True)
    activo = models.BooleanField(null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["empleado"], condition=Q(activo=True), name="contrato_un_activo_por_empleado"),
            models.CheckConstraint(condition=Q(fecha_fin__gte=F("fecha_inicio")), name="contrato_fechas_en_orden"),
            models.CheckConstraint(condition=Q(salario__gte=0), name="contrato_salario_no_negativo"),
            models.CheckConstraint(condition=Q(horas_jornada__gte=0, horas_jornada__lte=24), name="contrato_horas_validas"),
        ]


class HoraExtra(ModeloBase):
    class Tipo(models.TextChoices):
        DIARIA = "diaria", "Diaria"
        SEMANAL = "semanal", "Semanal"
        FERIADO = "feriado", "Feriado"

    proyecto = models.ForeignKey(Proyecto, null=True, blank=True, on_delete=models.SET_NULL, related_name="horas_extra")
    empleado = models.ForeignKey(Empleado, null=True, blank=True, on_delete=models.SET_NULL, related_name="horas_extra")
    periodo_inicio = models.DateField(null=True, blank=True)
    periodo_fin = models.DateField(null=True, blank=True)
    autorizado_por = models.CharField(max_length=255, null=True, blank=True)
    horas_regulares = models.DecimalField(**HORAS, null=True, blank=True)
    horas_extra = models.DecimalField(**HORAS, default=0, db_default=0)
    costo_hora = models.DecimalField(**MONTO, default=0, db_default=0)
    total = models.DecimalField(**MONTO, default=0, db_default=0)
    tipo = models.CharField(max_length=20, choices=Tipo.choices, null=True, blank=True)

    class Meta:
        verbose_name = "registro de horas extra"
        verbose_name_plural = "registros de horas extra"
        constraints = [
            models.CheckConstraint(condition=Q(periodo_fin__gte=F("periodo_inicio")), name="hora_extra_periodo_en_orden"),
            models.CheckConstraint(
                condition=Q(horas_regulares__gte=0) & Q(horas_extra__gte=0) & Q(costo_hora__gte=0) & Q(total__gte=0),
                name="hora_extra_valores_no_negativos",
            ),
            models.CheckConstraint(condition=Q(tipo__in=["diaria", "semanal", "feriado"]), name="hora_extra_tipo_valido"),
        ]


class Planilla(ModeloBase):
    class Estado(models.TextChoices):
        BORRADOR = "borrador", "Borrador"
        APROBADA = "aprobada", "Aprobada"
        PAGADA = "pagada", "Pagada"

    departamento = models.ForeignKey(Departamento, null=True, blank=True, on_delete=models.SET_NULL, related_name="planillas")
    periodo_inicio = models.DateField(null=True, blank=True)
    periodo_fin = models.DateField(null=True, blank=True)
    # Cuenta que generó la planilla (puede ser un administrador o un empleado).
    generada_por = models.ForeignKey(Usuario, null=True, blank=True, on_delete=models.SET_NULL, related_name="planillas_generadas")
    total = models.DecimalField(**MONTO, default=0, db_default=0)
    estado = models.CharField(max_length=20, choices=Estado.choices, null=True, blank=True)
    generada_en = models.DateTimeField(null=True, blank=True)
    incluye_descuentos = models.BooleanField(default=False, db_default=False)
    incluye_bonos = models.BooleanField(default=False, db_default=False)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=Q(periodo_fin__gte=F("periodo_inicio")), name="planilla_periodo_en_orden"),
            models.CheckConstraint(condition=Q(estado__in=["borrador", "aprobada", "pagada"]), name="planilla_estado_valido"),
        ]


class LineaPlanilla(ModeloBase):
    """Una fila de la planilla por empleado (columnas de la hoja «PLANILLA»)."""

    class BaseDiaria(models.TextChoices):
        MES_30 = "mes_30", "Mes de 30 días"
        ANIO_365 = "anio_365", "Año de 365 días"

    planilla = models.ForeignKey(Planilla, on_delete=models.CASCADE, related_name="lineas")
    # NULL solo si el empleado se borró después; la línea conserva sus montos.
    empleado = models.ForeignKey(Empleado, null=True, blank=True, on_delete=models.SET_NULL, related_name="lineas_planilla")
    salario_base = models.DecimalField(**MONTO, null=True, blank=True)
    dias_laborados = models.DecimalField(**HORAS, null=True, blank=True)
    horas_turno = models.DecimalField(**HORAS, default=8, db_default=8)
    base_diaria = models.CharField(max_length=10, choices=BaseDiaria.choices, default="mes_30", db_default="mes_30")
    horas_extra_diurnas = models.DecimalField(**HORAS, default=0, db_default=0)
    horas_extra_nocturnas = models.DecimalField(**HORAS, default=0, db_default=0)
    horas_descanso_diurnas = models.DecimalField(**HORAS, default=0, db_default=0)
    horas_descanso_nocturnas = models.DecimalField(**HORAS, default=0, db_default=0)
    horas_extra = models.DecimalField(**HORAS, default=0, db_default=0)
    pago_extra_diurno = models.DecimalField(**MONTO, default=0, db_default=0)
    pago_extra_nocturno = models.DecimalField(**MONTO, default=0, db_default=0)
    pago_extra_ordinario = models.DecimalField(**MONTO, default=0, db_default=0)
    pago_descanso_diurno = models.DecimalField(**MONTO, default=0, db_default=0)
    pago_descanso_nocturno = models.DecimalField(**MONTO, default=0, db_default=0)
    pago_extra_descanso = models.DecimalField(**MONTO, default=0, db_default=0)
    pago_extra = models.DecimalField(**MONTO, default=0, db_default=0)
    ajuste_pendiente = models.DecimalField(**MONTO, default=0, db_default=0)
    bonificaciones = models.DecimalField(**MONTO, default=0, db_default=0)
    bonificaciones_extra = models.DecimalField(**MONTO, default=0, db_default=0)
    salario_devengado = models.DecimalField(**MONTO, default=0, db_default=0)
    total_devengado = models.DecimalField(**MONTO, default=0, db_default=0)
    descuento_isss = models.DecimalField(**MONTO, default=0, db_default=0)
    descuento_afp = models.DecimalField(**MONTO, default=0, db_default=0)
    neto_antes_renta = models.DecimalField(**MONTO, default=0, db_default=0)
    descuento_renta = models.DecimalField(**MONTO, default=0, db_default=0)
    descuentos = models.DecimalField(**MONTO, default=0, db_default=0)
    anticipo = models.DecimalField(**MONTO, default=0, db_default=0)
    otros_descuentos = models.DecimalField(**MONTO, default=0, db_default=0)
    liquido = models.DecimalField("líquido a pagar", **MONTO, null=True, blank=True)

    class Meta:
        verbose_name = "línea de planilla"
        verbose_name_plural = "líneas de planilla"
        constraints = [
            models.UniqueConstraint(fields=["planilla", "empleado"], name="linea_planilla_empleado_unico"),
            models.CheckConstraint(condition=Q(base_diaria__in=["mes_30", "anio_365"]), name="linea_planilla_base_diaria_valida"),
        ]


class Boleta(ModeloBase):
    linea_planilla = models.ForeignKey(LineaPlanilla, null=True, blank=True, on_delete=models.SET_NULL, related_name="boletas")
    periodo = models.CharField(max_length=100, null=True, blank=True)
    salario = models.DecimalField(**MONTO, null=True, blank=True)
    generada_en = models.DateTimeField(null=True, blank=True)
    enviada_por = models.CharField(max_length=50, null=True, blank=True)
    enviada_en = models.DateTimeField(null=True, blank=True)
    estado_entrega = models.CharField(max_length=50, null=True, blank=True)

    class Meta:
        verbose_name = "boleta de pago"
        verbose_name_plural = "boletas de pago"
