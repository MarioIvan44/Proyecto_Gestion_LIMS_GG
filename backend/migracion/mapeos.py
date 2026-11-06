"""
Mapeo de cada colección de MongoDB a su tabla de PostgreSQL.

Cada `Campo` dice de qué campo del documento sale una columna, cómo se convierte
y si es obligatorio. Cada `Ref` es un ObjectId que apunta a otra colección y
pasa a ser una llave foránea. Los `Hijos` son arreglos de subdocumentos que
pasan a una tabla propia.

El orden de `ORDEN` respeta las dependencias: una colección se migra después de
las colecciones a las que apunta.
"""

from dataclasses import dataclass, field
from typing import Callable

from finanzas.models import CuentaPorCobrar, CuentaPorCobrarItem, Pago, Proforma, ProformaItem
from nucleo.models import (
    AvanceProyecto, Cliente, Departamento, Empleado, Proyecto, ProyectoTecnico, ReporteSemanal, Servicio, Usuario,
)
from rrhh.models import Boleta, Contrato, HoraExtra, LineaPlanilla, Planilla

from .conversiones import booleano, decimal, entero, fecha_dia, fecha_hora, fecha_texto, hora, opcion, texto

# Referencias a «la cuenta que hizo algo»: puede ser un administrador o un
# empleado. Se resuelven contra Usuario, que tiene el _id de ambos.
USUARIOS = "usuarios"


@dataclass
class Campo:
    origen: str
    destino: str
    convertir: Callable
    obligatorio: bool = False
    por_defecto: object = None  # valor por defecto del esquema de Mongoose
    suma: bool = False  # se incluye en la validación de sumas


@dataclass
class Ref:
    origen: str
    destino: str  # nombre del campo ForeignKey en el modelo de Django
    coleccion: str
    obligatoria: bool = False


@dataclass
class Unico:
    """Restricción de unicidad que se revisa antes de guardar, para dar un motivo claro."""

    filtro: Callable  # recibe los valores convertidos y devuelve el filtro de Django (o None si no aplica)
    mensaje: str


@dataclass
class Hijos:
    arreglo: str
    modelo: type
    padre: str
    campos: list
    refs: list = field(default_factory=list)
    unico_en_padre: tuple = ()  # campos que no se pueden repetir dentro del mismo documento padre


@dataclass
class Coleccion:
    nombre: str
    modelo: type
    campos: list
    refs: list = field(default_factory=list)
    hijos: list = field(default_factory=list)
    unicos: list = field(default_factory=list)
    con_fechas: bool = True  # el esquema usa timestamps (createdAt/updatedAt)
    campos_especiales: tuple = ()  # campos que trata el motor aparte (no van a datos_extra)


def _iexact(campo, columna):
    return lambda v: {f"{columna}__iexact": v[columna]} if v.get(columna) else None


def _exacto(*columnas):
    def filtro(v):
        if any(v.get(c) is None for c in columnas):
            return None
        return {c: v[c] for c in columnas}

    return filtro


DEPARTAMENTOS = Coleccion(
    "departments", Departamento,
    campos=[
        Campo("name", "nombre", texto(150), obligatorio=True),
        Campo("description", "descripcion", texto()),
        Campo("isActive", "activo", booleano()),
        Campo("overtimeHourlyRate", "tarifa_hora_extra", decimal(), suma=True),
    ],
)

EMPLEADOS = Coleccion(
    "employees", Empleado,
    campos=[
        Campo("firstName", "nombres", texto(150), obligatorio=True),
        Campo("lastName", "apellidos", texto(150), obligatorio=True),
        Campo("phone", "telefono", texto(30)),
        Campo("email", "email", texto(254, vacio_a_null=True)),
        Campo("dui", "dui", texto(20, vacio_a_null=True)),
        Campo("employeeCode", "codigo", texto(30, vacio_a_null=True)),
        Campo("employeeType", "tipo", texto(100)),
        Campo("jobTitle", "cargo", texto(150)),
        Campo("bankAccount", "cuenta_bancaria", texto(50)),
        Campo("accountType", "tipo_cuenta", opcion({"Ahorro": "Ahorro", "Corriente": "Corriente"})),
        Campo("afp", "afp", texto(50)),
        Campo("isPensioner", "pensionado", booleano(), por_defecto=False),
        Campo("isExemptFromIsss", "exento_isss", booleano(), por_defecto=False),
        Campo("isUnderJudicialProcess", "proceso_judicial", booleano(), por_defecto=False),
        Campo("workShiftHours", "horas_jornada", decimal()),
        Campo("hireDate", "fecha_contratacion", fecha_dia()),
        Campo("monthlySalary", "salario_mensual", decimal(), suma=True),
        Campo("isActive", "activo", booleano(), por_defecto=True),
        Campo("hasAccess", "tiene_acceso", booleano(), por_defecto=False),
        Campo("isAdmin", "es_admin", booleano(), por_defecto=False),
    ],
    refs=[Ref("departmentId", "departamento", "departments")],
    unicos=[
        Unico(_iexact("email", "email"), "ya existe otro empleado con ese correo (sin distinguir mayúsculas)"),
        Unico(_exacto("dui"), "ya existe otro empleado con ese DUI"),
        Unico(_exacto("codigo"), "ya existe otro empleado con ese código"),
    ],
    # Credenciales: el motor las guarda en Usuario.
    campos_especiales=("passwordHash", "password", "isVerified", "loginAttempts", "timeOut"),
)

# Campos de inicio de sesión de un empleado (van a su Usuario).
CAMPOS_USUARIO_EMPLEADO = [
    Campo("isVerified", "verificado", booleano()),
    Campo("loginAttempts", "intentos_login", entero(0, 32767)),
    Campo("timeOut", "bloqueado_hasta", fecha_hora()),
]

ADMINISTRADORES = Coleccion(
    "administrators", Usuario,
    campos=[
        Campo("name", "nombres", texto(150), por_defecto=""),
        Campo("lastName", "apellidos", texto(150), por_defecto=""),
        Campo("email", "email", texto(254, vacio_a_null=True), obligatorio=True),
        Campo("isVerified", "verificado", booleano()),
        Campo("loginAttempts", "intentos_login", entero(0, 32767)),
        Campo("timeOut", "bloqueado_hasta", fecha_hora()),
        Campo("isActive", "is_active", booleano(), por_defecto=True),
    ],
    unicos=[Unico(_iexact("email", "email"), "el correo ya lo usa otra cuenta")],
    campos_especiales=("passwordHash", "password"),
)

CLIENTES = Coleccion(
    "customers", Cliente,
    campos=[
        Campo("RUC", "ruc", texto(50, vacio_a_null=True), obligatorio=True),
        Campo("companyName", "razon_social", texto(255), obligatorio=True),
        Campo("contactName", "contacto", texto(255), obligatorio=True),
        Campo("phone", "telefono", texto(30)),
        Campo("email", "email", texto(254, vacio_a_null=True)),
        Campo("address", "direccion", texto()),
        Campo("additionalNotes", "notas", texto()),
    ],
    unicos=[
        Unico(_exacto("ruc"), "ya existe otro cliente con ese RUC"),
        Unico(_iexact("email", "email"), "ya existe otro cliente con ese correo (sin distinguir mayúsculas)"),
    ],
)

SERVICIOS = Coleccion(
    "services", Servicio,
    campos=[
        Campo("name", "nombre", texto(255), obligatorio=True),
        Campo("description", "descripcion", texto()),
        Campo("unitCost", "costo_unitario", decimal(), suma=True),
        Campo("serviceType", "tipo", opcion({v: v for v in ("Visita de campo", "Ensayo de laboratorio", "Servicio profesional")})),
    ],
)

PROYECTOS = Coleccion(
    "projects", Proyecto,
    campos=[
        Campo("projectName", "nombre", texto(255), obligatorio=True),
        Campo("projectCode", "codigo", texto(50)),
        Campo("startDate", "fecha_inicio", fecha_dia()),
        Campo("endDate", "fecha_fin", fecha_dia()),
        Campo("description", "descripcion", texto()),
        Campo("baseCost", "costo_base", decimal(), suma=True),
        Campo("dayTimeOverTimeCost", "costo_extra_diurno", decimal()),
        Campo("nightTimeOverTimeCost", "costo_extra_nocturno", decimal()),
        Campo("status", "estado", opcion({"not started": "no_iniciado", "in progress": "en_progreso", "completed": "completado"})),
        Campo("supervisorEngineer", "ingeniero_supervisor", texto(255)),
    ],
    refs=[Ref("customerId", "cliente", "customers")],
    hijos=[
        Hijos("assignedTechniciansIds", ProyectoTecnico, "proyecto", campos=[],
              # Si el técnico se borró, la asignación se migra sin empleado (en MongoDB quedaba colgando).
              refs=[Ref("technicianId", "empleado", "employees")], unico_en_padre=("empleado_id",)),
        Hijos("projectProgress", AvanceProyecto, "proyecto",
              campos=[Campo("image", "imagen_url", texto(1000)), Campo("publicId", "cloudinary_id", texto(255))],
              refs=[Ref("uploadedBy", "subido_por", USUARIOS)]),
    ],
)

REPORTES = Coleccion(
    "weeklyreports", ReporteSemanal,
    campos=[
        Campo("weekEnding", "semana_termina", fecha_dia()),
        Campo("notes", "notas", texto()),
        Campo("status", "estado", texto(50)),
        Campo("submittedAt", "enviado_en", fecha_hora()),
    ],
    refs=[Ref("projectId", "proyecto", "projects"), Ref("reportedBy", "reportado_por", "employees")],
)

CONTRATOS = Coleccion(
    "contracts", Contrato,
    campos=[
        Campo("contractType", "tipo", texto(100)),
        Campo("startDate", "fecha_inicio", fecha_dia()),
        Campo("endDate", "fecha_fin", fecha_dia()),
        Campo("salary", "salario", decimal(), suma=True),
        Campo("workShiftStart", "hora_entrada", hora()),
        Campo("workShiftEnd", "hora_salida", hora()),
        Campo("workShiftHours", "horas_jornada", decimal()),
        Campo("clauses", "clausulas", texto()),
        Campo("isActive", "activo", booleano()),
    ],
    # Si el empleado se borró, el contrato se migra sin empleado y con advertencia (no se pierde).
    refs=[Ref("employeeId", "empleado", "employees")],
    unicos=[Unico(lambda v: {"empleado_id": v["empleado_id"], "activo": True} if v.get("activo") else None,
                  "el empleado ya tiene otro contrato activo (se conserva el más antiguo)")],
    con_fechas=False,
)

HORAS_EXTRA = Coleccion(
    "overtimerecords", HoraExtra,
    campos=[
        Campo("periodStart", "periodo_inicio", fecha_dia()),
        Campo("periodEnd", "periodo_fin", fecha_dia()),
        Campo("authorizedBy", "autorizado_por", texto(255)),
        Campo("regularHours", "horas_regulares", decimal(), suma=True),
        Campo("overtimeHours", "horas_extra", decimal(), por_defecto=0, suma=True),
        Campo("costPerHour", "costo_hora", decimal(), por_defecto=0),
        Campo("totalOvertimePay", "total", decimal(), por_defecto=0, suma=True),
        Campo("overtimeType", "tipo", opcion({"daily": "diaria", "weekly": "semanal", "holiday": "feriado"})),
    ],
    refs=[Ref("projectId", "proyecto", "projects"), Ref("employeeId", "empleado", "employees")],
)

PLANILLAS = Coleccion(
    "payrolls", Planilla,
    campos=[
        Campo("periodStart", "periodo_inicio", fecha_dia()),
        Campo("periodEnd", "periodo_fin", fecha_dia()),
        Campo("totalAmount", "total", decimal(), por_defecto=0, suma=True),
        Campo("status", "estado", opcion({"draft": "borrador", "approved": "aprobada", "paid": "pagada"})),
        Campo("generatedAt", "generada_en", fecha_hora()),
        Campo("includeDeductions", "incluye_descuentos", booleano(), por_defecto=False),
        Campo("includeBonuses", "incluye_bonos", booleano(), por_defecto=False),
    ],
    refs=[Ref("departmentId", "departamento", "departments"), Ref("generatedBy", "generada_por", USUARIOS)],
    campos_especiales=("seedOriginalTotal",),
)


def _monto_linea(origen, destino, suma=False):
    return Campo(origen, destino, decimal(), por_defecto=0, suma=suma)


LINEAS_PLANILLA = Coleccion(
    "payrollentries", LineaPlanilla,
    campos=[
        Campo("baseSalary", "salario_base", decimal(), suma=True),
        Campo("workingDays", "dias_laborados", decimal()),
        Campo("shiftHours", "horas_turno", decimal(), por_defecto=8),
        Campo("dailyRateBasis", "base_diaria", opcion({"month30": "mes_30", "year365": "anio_365"}), por_defecto="mes_30"),
        _monto_linea("overtimeDayHours", "horas_extra_diurnas"),
        _monto_linea("overtimeNightHours", "horas_extra_nocturnas"),
        _monto_linea("restDayHours", "horas_descanso_diurnas"),
        _monto_linea("restNightHours", "horas_descanso_nocturnas"),
        _monto_linea("overtimeHours", "horas_extra"),
        _monto_linea("overtimeDayPay", "pago_extra_diurno"),
        _monto_linea("overtimeNightPay", "pago_extra_nocturno"),
        _monto_linea("overtimeOrdinaryPay", "pago_extra_ordinario"),
        _monto_linea("restDayPay", "pago_descanso_diurno"),
        _monto_linea("restNightPay", "pago_descanso_nocturno"),
        _monto_linea("overtimeRestPay", "pago_extra_descanso"),
        _monto_linea("overtimePay", "pago_extra", suma=True),
        _monto_linea("pendingAdjustment", "ajuste_pendiente"),
        _monto_linea("allowances", "bonificaciones"),
        _monto_linea("extraAllowances", "bonificaciones_extra"),
        _monto_linea("earnedSalary", "salario_devengado"),
        _monto_linea("grossEarnings", "total_devengado", suma=True),
        _monto_linea("isssDeduction", "descuento_isss", suma=True),
        _monto_linea("afpDeduction", "descuento_afp", suma=True),
        _monto_linea("netBeforeRent", "neto_antes_renta"),
        _monto_linea("rentDeduction", "descuento_renta", suma=True),
        _monto_linea("deductions", "descuentos"),
        _monto_linea("advance", "anticipo"),
        _monto_linea("otherDeductions", "otros_descuentos"),
        Campo("netPay", "liquido", decimal(), suma=True),
    ],
    # La planilla es obligatoria (la línea es parte de ella); si el empleado se borró, la línea se
    # migra sin empleado y conserva sus montos.
    refs=[Ref("payrollId", "planilla", "payrolls", obligatoria=True), Ref("employeeId", "empleado", "employees")],
    unicos=[Unico(_exacto("planilla_id", "empleado_id"), "el empleado ya tiene una línea en esa planilla")],
)

BOLETAS = Coleccion(
    "payslips", Boleta,
    campos=[
        Campo("period", "periodo", texto(100)),
        Campo("salary", "salario", decimal(), suma=True),
        Campo("generatedAt", "generada_en", fecha_hora()),
        Campo("sentVia", "enviada_por", texto(50)),
        Campo("sentAt", "enviada_en", fecha_hora()),
        Campo("deliveryStatus", "estado_entrega", texto(50)),
    ],
    refs=[Ref("payrollEntryID", "linea_planilla", "payrollentries")],
)

ITEM_CAMPOS = [
    Campo("quantity", "cantidad", decimal()),
    Campo("unitCost", "costo_unitario", decimal()),
    Campo("subtotal", "subtotal", decimal(), suma=True),
]

PROFORMAS = Coleccion(
    "proformainvoices", Proforma,
    campos=[
        Campo("issueDate", "fecha_emision", fecha_dia()),
        Campo("overtimeCharges", "cargos_horas_extra", decimal()),
        Campo("additionalCharges", "cargos_adicionales", decimal()),
        Campo("projectBaseCost", "costo_base_proyecto", decimal(), por_defecto=0),
        Campo("totalAmount", "total", decimal(), suma=True),
        Campo("status", "estado", opcion({"approved": "aprobada", "pending": "pendiente", "rejected": "rechazada"})),
        Campo("approvedAt", "aprobada_en", fecha_hora()),
        Campo("additionalNotes", "notas", texto()),
        Campo("sentAt", "enviada_en", fecha_hora()),
        Campo("sentTo", "enviada_a", texto(254)),
    ],
    refs=[Ref("customerId", "cliente", "customers"), Ref("projectId", "proyecto", "projects")],
    hijos=[Hijos("items", ProformaItem, "proforma", campos=ITEM_CAMPOS, refs=[Ref("serviceId", "servicio", "services")])],
)

CUENTAS = Coleccion(
    "accountsreceivables", CuentaPorCobrar,
    campos=[
        Campo("invoiceNumber", "numero_factura", texto(50, vacio_a_null=True), obligatorio=True),
        Campo("issueDate", "fecha_emision", fecha_texto(), obligatorio=True),
        Campo("dueDate", "fecha_vencimiento", fecha_texto(), obligatorio=True),
        Campo("subtotal", "subtotal", decimal(), suma=True),
        Campo("taxAmount", "impuesto", decimal(), suma=True),
        Campo("totalAmount", "total", decimal(), suma=True),
        Campo("paidAmount", "pagado", decimal(), obligatorio=True, suma=True),
        Campo("balanceDue", "saldo", decimal(), obligatorio=True, suma=True),
        Campo("status", "estado", opcion({"Pending": "pendiente", "Overdue": "vencida", "Paid": "pagada"}), obligatorio=True),
        Campo("additionalNotes", "notas", texto()),
    ],
    # Si la proforma se borró, la cuenta se migra sin proforma y conserva sus montos y pagos.
    refs=[Ref("proformaInvoiceId", "proforma", "proformainvoices")],
    hijos=[
        Hijos("items", CuentaPorCobrarItem, "cuenta", campos=ITEM_CAMPOS, refs=[Ref("serviceId", "servicio", "services")]),
        Hijos("paymentHistory", Pago, "cuenta", campos=[
            Campo("paymentDate", "fecha", fecha_dia()),
            Campo("receiptUrl", "comprobante_url", texto(1000)),
            Campo("publicId", "cloudinary_id", texto(255)),
            Campo("amount", "monto", decimal(), suma=True),
            Campo("method", "metodo", texto(50)),
            Campo("notes", "notas", texto()),
        ]),
    ],
    unicos=[Unico(_exacto("numero_factura"), "ya existe otra cuenta por cobrar con ese número de factura")],
)

# Orden de migración. Empleados va antes que administradores: el inicio de
# sesión del sistema actual busca primero en empleados, así que si un correo
# está en las dos colecciones, la cuenta que funciona es la del empleado.
ORDEN = [
    DEPARTAMENTOS, EMPLEADOS, ADMINISTRADORES, CLIENTES, SERVICIOS, PROYECTOS, REPORTES, CONTRATOS,
    HORAS_EXTRA, PLANILLAS, LINEAS_PLANILLA, BOLETAS, PROFORMAS, CUENTAS,
]

COLECCIONES = {c.nombre: c for c in ORDEN}

# Metadatos que no son datos del negocio.
CAMPOS_META = {"_id", "__v", "createdAt", "updatedAt"}
# Marcas de los scripts de demostración del fork. Si un documento de demostración
# se migra (opción --incluir-demo), se conservan en datos_extra porque el backend
# las usa (por ejemplo, para no contar la demostración en las predicciones).
MARCAS_DEMO = {"isSeedData", "seedSource", "seedOriginalTotal"}

# Mensajes para las restricciones CHECK de la base, por nombre (no dependen del idioma del servidor).
MENSAJES_RESTRICCIONES = {
    "usuario_tipo_valido": "tipo de usuario no válido",
    "usuario_email_unico": "el correo ya lo usa otra cuenta",
    "departamento_tarifa_no_negativa": "la tarifa de hora extra es negativa",
    "empleado_email_unico": "ya existe otro empleado con ese correo",
    "empleado_dui_unico": "ya existe otro empleado con ese DUI",
    "empleado_tipo_cuenta_valido": "tipo de cuenta bancaria no válido",
    "empleado_horas_jornada_validas": "las horas de jornada deben estar entre 0 y 24",
    "empleado_salario_no_negativo": "el salario mensual es negativo",
    "cliente_email_unico": "ya existe otro cliente con ese correo",
    "servicio_costo_no_negativo": "el costo unitario es negativo",
    "servicio_tipo_valido": "tipo de servicio no válido",
    "proyecto_fechas_en_orden": "la fecha de fin es anterior a la de inicio",
    "proyecto_estado_valido": "estado de proyecto no válido",
    "proyecto_costos_no_negativos": "hay un costo negativo",
    "proyecto_tecnico_unico": "el técnico ya está asignado al proyecto",
    "contrato_un_activo_por_empleado": "el empleado ya tiene otro contrato activo",
    "contrato_fechas_en_orden": "la fecha de fin del contrato es anterior a la de inicio",
    "contrato_salario_no_negativo": "el salario es negativo",
    "contrato_horas_validas": "las horas de jornada deben estar entre 0 y 24",
    "hora_extra_periodo_en_orden": "el fin del período es anterior al inicio",
    "hora_extra_valores_no_negativos": "hay horas o montos negativos",
    "hora_extra_tipo_valido": "tipo de hora extra no válido",
    "planilla_periodo_en_orden": "el fin del período es anterior al inicio",
    "planilla_estado_valido": "estado de planilla no válido",
    "linea_planilla_empleado_unico": "el empleado ya tiene una línea en esa planilla",
    "linea_planilla_base_diaria_valida": "base de cálculo diario no válida",
    "proforma_estado_valido": "estado de proforma no válido",
    "proforma_montos_no_negativos": "hay un monto negativo",
    "proforma_item_cantidad_positiva": "la cantidad debe ser mayor que 0",
    "proforma_item_montos_no_negativos": "hay un monto negativo en el ítem",
    "cuenta_estado_valido": "estado de cuenta no válido",
    "cuenta_montos_no_negativos": "hay un monto negativo",
    "cuenta_item_cantidad_positiva": "la cantidad debe ser mayor que 0",
    "cuenta_item_montos_no_negativos": "hay un monto negativo en el ítem",
    "pago_monto_positivo": "el monto del pago debe ser mayor que 0",
}
