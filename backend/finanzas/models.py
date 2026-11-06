"""Facturación: proformas, cuentas por cobrar y pagos."""

from django.db import models
from django.db.models import Q

from nucleo.models import MONTO, Cliente, ModeloBase, ModeloHijo, Proyecto, Servicio


class Proforma(ModeloBase):
    class Estado(models.TextChoices):
        APROBADA = "aprobada", "Aprobada"
        PENDIENTE = "pendiente", "Pendiente"
        RECHAZADA = "rechazada", "Rechazada"

    cliente = models.ForeignKey(Cliente, null=True, blank=True, on_delete=models.SET_NULL, related_name="proformas")
    proyecto = models.ForeignKey(Proyecto, null=True, blank=True, on_delete=models.SET_NULL, related_name="proformas")
    fecha_emision = models.DateField(null=True, blank=True)
    cargos_horas_extra = models.DecimalField(**MONTO, null=True, blank=True)
    cargos_adicionales = models.DecimalField(**MONTO, null=True, blank=True)
    costo_base_proyecto = models.DecimalField(**MONTO, default=0, db_default=0)
    total = models.DecimalField(**MONTO, null=True, blank=True)
    estado = models.CharField(max_length=20, choices=Estado.choices, null=True, blank=True)
    aprobada_en = models.DateTimeField(null=True, blank=True)
    notas = models.TextField(null=True, blank=True)
    enviada_en = models.DateTimeField(null=True, blank=True)
    enviada_a = models.EmailField(max_length=254, null=True, blank=True)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=Q(estado__in=["aprobada", "pendiente", "rechazada"]), name="proforma_estado_valido"),
            models.CheckConstraint(
                condition=Q(cargos_horas_extra__gte=0) & Q(cargos_adicionales__gte=0) & Q(costo_base_proyecto__gte=0) & Q(total__gte=0),
                name="proforma_montos_no_negativos",
            ),
        ]


class ProformaItem(ModeloHijo):
    proforma = models.ForeignKey(Proforma, on_delete=models.CASCADE, related_name="items")
    servicio = models.ForeignKey(Servicio, null=True, blank=True, on_delete=models.SET_NULL, related_name="items_proforma")
    cantidad = models.DecimalField(**MONTO, null=True, blank=True)
    costo_unitario = models.DecimalField(**MONTO, null=True, blank=True)
    subtotal = models.DecimalField(**MONTO, null=True, blank=True)

    class Meta(ModeloHijo.Meta):
        verbose_name = "ítem de proforma"
        verbose_name_plural = "ítems de proforma"
        constraints = [
            models.CheckConstraint(condition=Q(cantidad__gt=0), name="proforma_item_cantidad_positiva"),
            models.CheckConstraint(condition=Q(costo_unitario__gte=0) & Q(subtotal__gte=0), name="proforma_item_montos_no_negativos"),
        ]


class CuentaPorCobrar(ModeloBase):
    class Estado(models.TextChoices):
        PENDIENTE = "pendiente", "Pendiente"
        VENCIDA = "vencida", "Vencida"
        PAGADA = "pagada", "Pagada"

    # NULL solo si la proforma se borró después; la cuenta conserva sus montos y pagos.
    proforma = models.ForeignKey(Proforma, null=True, blank=True, on_delete=models.SET_NULL, related_name="cuentas_por_cobrar")
    numero_factura = models.CharField(max_length=50, unique=True)
    fecha_emision = models.DateField()
    fecha_vencimiento = models.DateField()
    subtotal = models.DecimalField(**MONTO, null=True, blank=True)
    impuesto = models.DecimalField(**MONTO, null=True, blank=True)
    total = models.DecimalField(**MONTO, null=True, blank=True)
    pagado = models.DecimalField(**MONTO)
    saldo = models.DecimalField(**MONTO)
    estado = models.CharField(max_length=20, choices=Estado.choices)
    notas = models.TextField(null=True, blank=True)

    class Meta:
        verbose_name = "cuenta por cobrar"
        verbose_name_plural = "cuentas por cobrar"
        constraints = [
            models.CheckConstraint(condition=Q(estado__in=["pendiente", "vencida", "pagada"]), name="cuenta_estado_valido"),
            models.CheckConstraint(
                condition=Q(subtotal__gte=0) & Q(impuesto__gte=0) & Q(total__gte=0) & Q(pagado__gte=0),
                name="cuenta_montos_no_negativos",
            ),
        ]


class CuentaPorCobrarItem(ModeloHijo):
    cuenta = models.ForeignKey(CuentaPorCobrar, on_delete=models.CASCADE, related_name="items")
    servicio = models.ForeignKey(Servicio, null=True, blank=True, on_delete=models.SET_NULL, related_name="items_cuenta")
    cantidad = models.DecimalField(**MONTO, null=True, blank=True)
    costo_unitario = models.DecimalField(**MONTO, null=True, blank=True)
    subtotal = models.DecimalField(**MONTO, null=True, blank=True)

    class Meta(ModeloHijo.Meta):
        verbose_name = "ítem de cuenta por cobrar"
        verbose_name_plural = "ítems de cuenta por cobrar"
        constraints = [
            models.CheckConstraint(condition=Q(cantidad__gt=0), name="cuenta_item_cantidad_positiva"),
            models.CheckConstraint(condition=Q(costo_unitario__gte=0) & Q(subtotal__gte=0), name="cuenta_item_montos_no_negativos"),
        ]


class Pago(ModeloHijo):
    cuenta = models.ForeignKey(CuentaPorCobrar, on_delete=models.CASCADE, related_name="pagos")
    fecha = models.DateField(null=True, blank=True)
    comprobante_url = models.URLField(max_length=1000, null=True, blank=True)
    cloudinary_id = models.CharField(max_length=255, null=True, blank=True)
    monto = models.DecimalField(**MONTO, null=True, blank=True)
    metodo = models.CharField(max_length=50, null=True, blank=True)
    notas = models.TextField(null=True, blank=True)

    class Meta(ModeloHijo.Meta):
        constraints = [
            models.CheckConstraint(condition=Q(monto__gt=0), name="pago_monto_positivo"),
        ]
