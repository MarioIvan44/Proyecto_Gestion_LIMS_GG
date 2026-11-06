"""
Validación al final de la migración: conteos, sumas, totales que no cuadran con
sus partes y filas cuyo documento ya no existe en MongoDB.
"""

from decimal import Decimal

from django.db import connection
from django.db.models import Sum

from finanzas.models import CuentaPorCobrar, CuentaPorCobrarItem, Pago, Proforma, ProformaItem
from nucleo.models import (
    AvanceProyecto, Cliente, Departamento, Empleado, Proyecto, ProyectoTecnico, ReporteSemanal, Servicio, Usuario,
)
from rrhh.models import Boleta, Contrato, HoraExtra, LineaPlanilla, Planilla

MODELOS = [
    Departamento, Usuario, Empleado, Cliente, Servicio, Proyecto, ProyectoTecnico, AvanceProyecto, ReporteSemanal,
    Contrato, HoraExtra, Planilla, LineaPlanilla, Boleta, Proforma, ProformaItem, CuentaPorCobrar, CuentaPorCobrarItem, Pago,
]
PRINCIPALES = [Departamento, Usuario, Empleado, Cliente, Servicio, Proyecto, ReporteSemanal, Contrato, HoraExtra,
               Planilla, LineaPlanilla, Boleta, Proforma, CuentaPorCobrar]
COLECCION_DE = {
    Departamento: "departments", Empleado: "employees", Cliente: "customers", Servicio: "services", Proyecto: "projects",
    ReporteSemanal: "weeklyreports", Contrato: "contracts", HoraExtra: "overtimerecords", Planilla: "payrolls",
    LineaPlanilla: "payrollentries", Boleta: "payslips", Proforma: "proformainvoices", CuentaPorCobrar: "accountsreceivables",
    Usuario: "administrators/employees",
}
TOLERANCIA = Decimal("0.01")
REDONDEO_POR_FILA = Decimal("0.00005")


def validar(motor, informe):
    _conteos(motor, informe)
    _sumas(motor, informe)
    _cuadres(motor, informe)
    _sin_documento(motor, informe)


def _conteos(motor, informe):
    for modelo in MODELOS:
        escritos = motor.escritos.get(modelo, set())
        en_pg = modelo.objects.filter(mongo_id__in=list(escritos)).count() if escritos else 0
        informe.conteos.append({
            "tabla": modelo._meta.db_table, "esperadas": len(escritos), "en_postgresql": en_pg,
            "total_en_tabla": modelo.objects.count(), "cuadra": en_pg == len(escritos),
        })


def _sumas(motor, informe):
    for (modelo, columna), (filas, suma_mongo) in sorted(motor.sumas.items(), key=lambda x: (x[0][0]._meta.db_table, x[0][1])):
        ids = list(motor.escritos.get(modelo, set()))
        suma_pg = modelo.objects.filter(mongo_id__in=ids, **{f"{columna}__isnull": False}).aggregate(s=Sum(columna))["s"] or Decimal(0)
        diferencia = suma_pg - suma_mongo
        informe.sumas.append({
            "tabla": modelo._meta.db_table, "columna": columna, "filas": filas,
            "mongo": f"{suma_mongo:.4f}", "postgresql": f"{suma_pg:.4f}", "diferencia": f"{diferencia:.6f}",
            "cuadra": abs(diferencia) <= filas * REDONDEO_POR_FILA + Decimal("0.000001"),
        })


def _consulta(sql, parametros):
    with connection.cursor() as cursor:
        cursor.execute(sql, parametros)
        return cursor.fetchall()


def _cuadre(informe, descripcion, coleccion, campo, filas, describir):
    revisadas, malas = 0, 0
    for fila in filas:
        revisadas += 1
        mongo_id, actual, esperado = fila[0], fila[1], fila[2]
        if actual is None or esperado is None:
            continue
        if abs(Decimal(actual) - Decimal(esperado)) > TOLERANCIA:
            malas += 1
            informe.advertencia(coleccion, mongo_id, campo, describir(fila))
    informe.cuadres.append({"descripcion": descripcion, "revisadas": revisadas, "no_cuadran": malas})


def _cuadres(motor, informe):
    ids = lambda modelo: list(motor.escritos.get(modelo, set()))  # noqa: E731

    _cuadre(informe, "Proforma: total = (ítems + cargos + costo base) × 1.13", "proformainvoices", "totalAmount", _consulta(
        """SELECT p.mongo_id, p.total,
                  ROUND((COALESCE(SUM(i.subtotal), 0) + COALESCE(p.cargos_horas_extra, 0) + COALESCE(p.cargos_adicionales, 0)
                         + COALESCE(p.costo_base_proyecto, 0)) * 1.13, 4)
             FROM finanzas_proforma p LEFT JOIN finanzas_proformaitem i ON i.proforma_id = p.id
            WHERE p.mongo_id = ANY(%s) GROUP BY p.id""", [ids(Proforma)]),
        lambda f: f"el total es {f[1]} y (ítems + cargos + costo base) × 1.13 da {f[2]}")

    for modelo, tabla, coleccion in [(ProformaItem, "finanzas_proformaitem", "proformainvoices.items"),
                                     (CuentaPorCobrarItem, "finanzas_cuentaporcobraritem", "accountsreceivables.items")]:
        _cuadre(informe, f"{coleccion}: subtotal = cantidad × costo unitario", coleccion, "subtotal", _consulta(
            f"SELECT mongo_id, subtotal, ROUND(cantidad * costo_unitario, 4) FROM {tabla} WHERE mongo_id = ANY(%s)", [ids(modelo)]),
            lambda f: f"el subtotal es {f[1]} y cantidad × costo unitario da {f[2]}")

    _cuadre(informe, "Planilla: total = suma del líquido de sus líneas", "payrolls", "totalAmount", _consulta(
        """SELECT pl.mongo_id, pl.total, COALESCE(SUM(l.liquido), 0), COUNT(l.id)
             FROM rrhh_planilla pl LEFT JOIN rrhh_lineaplanilla l ON l.planilla_id = pl.id
            WHERE pl.mongo_id = ANY(%s) GROUP BY pl.id""", [ids(Planilla)]),
        lambda f: f"el total es {f[1]} y la suma del líquido de sus {f[3]} líneas migradas da {f[2]}")

    _cuadre(informe, "Cuenta por cobrar: pagado = suma de pagos", "accountsreceivables", "paidAmount", _consulta(
        """SELECT c.mongo_id, c.pagado, COALESCE(SUM(p.monto), 0), COUNT(p.id)
             FROM finanzas_cuentaporcobrar c LEFT JOIN finanzas_pago p ON p.cuenta_id = c.id
            WHERE c.mongo_id = ANY(%s) GROUP BY c.id""", [ids(CuentaPorCobrar)]),
        lambda f: f"lo pagado es {f[1]} y la suma de sus {f[3]} pagos migrados da {f[2]}")

    _cuadre(informe, "Cuenta por cobrar: saldo = total − pagado", "accountsreceivables", "balanceDue", _consulta(
        "SELECT mongo_id, saldo, total - pagado FROM finanzas_cuentaporcobrar WHERE mongo_id = ANY(%s)", [ids(CuentaPorCobrar)]),
        lambda f: f"el saldo es {f[1]} y total − pagado da {f[2]}")

    _cuadre(informe, "Empleado: salario mensual = salario del contrato activo", "employees", "monthlySalary", _consulta(
        """SELECT e.mongo_id, e.salario_mensual, c.salario
             FROM nucleo_empleado e JOIN rrhh_contrato c ON c.empleado_id = e.id AND c.activo
            WHERE e.mongo_id = ANY(%s)""", [ids(Empleado)]),
        lambda f: f"el salario mensual es {f[1]} y el contrato activo dice {f[2]}")


def _sin_documento(motor, informe):
    for modelo in PRINCIPALES:
        vistos = set(motor.todos_ids.get(modelo, set()))
        if modelo is Usuario:
            vistos |= motor.todos_ids.get(Empleado, set())
        filas = modelo.objects.filter(mongo_id__isnull=False).exclude(mongo_id__in=list(vistos)).values_list("mongo_id", flat=True)
        for mongo_id in filas:
            informe.sin_documento_en_mongo.append({"tabla": modelo._meta.db_table, "mongo_id": mongo_id})
