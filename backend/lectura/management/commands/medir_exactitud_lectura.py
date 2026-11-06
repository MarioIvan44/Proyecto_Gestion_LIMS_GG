"""
python manage.py medir_exactitud_lectura [--conjunto prueba|entrenamiento|todos] [--tipo spt] [--csv salida.csv]

Mide, con hojas ya revisadas, qué tan seguido acierta la lectura:
- lectura exacta: el texto que devolvió el servicio ya era el valor correcto.
- propuesta exacta: la propuesta del sistema (con lo aprendido HOY) era el valor correcto.
- errores sin marcar: la propuesta estaba mal y NO se marcó para revisión. Es la
  cifra más importante: son los errores que un revisor apurado dejaría pasar.

Medir con el conjunto «entrenamiento» da cifras optimistas, porque el sistema
aprendió de esas mismas hojas. Para un número honesto, usar «prueba».
"""

import csv
from collections import defaultdict

from django.conf import settings
from django.core.management.base import BaseCommand

from lectura.aprendizaje import cargar_conocimiento
from lectura.models import CampoLeido, HojaEscaneada
from lectura.motor import numeros
from lectura.motor.plantillas import DECIMAL, ENTERO, OPCION
from lectura.motor.propuestas import MANUAL, CeldaEntrada, clave_opcion, proponer_hoja
from lectura.motor.texto import clave


def iguales(campo, a, b) -> bool:
    if a is None or b is None:
        return a is None and b is None
    if campo.tipo in (ENTERO, DECIMAL):
        da, db = numeros.a_decimal(a), numeros.a_decimal(b)
        return da is not None and da == db
    if campo.tipo == OPCION:
        return clave_opcion(a) == clave_opcion(b)
    return clave(a) == clave(b)


def porcentaje(n, total):
    return f"{100 * n / total:.1f} %" if total else "—"


def medir(hojas):
    """Devuelve {(tipo, campo): {conteo: n}}."""
    cuentas = defaultdict(lambda: defaultdict(int))
    revisadas = (CampoLeido.Estado.CONFIRMADO, CampoLeido.Estado.CORREGIDO)
    for hoja in hojas:
        plantilla = hoja.plantilla
        celdas = list(hoja.campos.all())
        entradas = [
            CeldaEntrada(c.fila, c.campo, c.texto_leido, float(c.confianza) if c.confianza is not None else None)
            for c in celdas if c.origen_propuesta != MANUAL
        ]
        r = proponer_hoja(
            plantilla, entradas, cargar_conocimiento(hoja.llenada_por), settings.LECTURA_UMBRAL_CONFIANZA,
        )
        propuestas = {(x.fila, x.campo): x for x in r.celdas}
        for c in celdas:
            k = cuentas[(hoja.tipo, c.campo)]
            if c.estado == CampoLeido.Estado.ILEGIBLE:
                k["ilegibles"] += 1
                continue
            if c.estado not in revisadas:
                continue
            k["celdas"] += 1
            p = propuestas.get((c.fila, c.campo))
            if p is None:
                k["no_leidas"] += 1
                continue
            campo = plantilla.campo(c.campo)
            acierto = iguales(campo, p.propuesta.valor, c.valor_final)
            k["lectura_exacta"] += iguales(campo, c.texto_leido, c.valor_final)
            k["propuesta_exacta"] += acierto
            k["marcadas"] += p.requiere_revision
            k["errores_sin_marcar"] += (not acierto) and not p.requiere_revision
    return cuentas


class Command(BaseCommand):
    help = "Mide la exactitud de la lectura con hojas revisadas."

    def add_arguments(self, parser):
        parser.add_argument("--conjunto", default="prueba", choices=["prueba", "entrenamiento", "todos"])
        parser.add_argument("--tipo")
        parser.add_argument("--csv")

    def handle(self, *args, **o):
        hojas = HojaEscaneada.objects.filter(estado=HojaEscaneada.Estado.REVISADA).select_related("llenada_por")
        if o["conjunto"] != "todos":
            hojas = hojas.filter(conjunto=o["conjunto"])
        if o["tipo"]:
            hojas = hojas.filter(tipo=o["tipo"])

        self.stdout.write(f"Hojas medidas: {hojas.count()} (conjunto: {o['conjunto']})")
        if o["conjunto"] != "prueba":
            self.stdout.write(self.style.WARNING("Incluye hojas de las que el sistema aprendió: cifras optimistas."))

        filas, totales = [], defaultdict(int)
        for (tipo, campo), k in sorted(medir(hojas).items()):
            leidas = k["celdas"] - k["no_leidas"]
            filas.append({
                "tipo": tipo, "campo": campo, "celdas": k["celdas"], "no_leidas": k["no_leidas"],
                "ilegibles": k["ilegibles"],
                "lectura_exacta": porcentaje(k["lectura_exacta"], leidas),
                "propuesta_exacta": porcentaje(k["propuesta_exacta"], leidas),
                "marcadas": porcentaje(k["marcadas"], leidas),
                "errores_sin_marcar": k["errores_sin_marcar"],
            })
            for n, v in k.items():
                totales[n] += v
        for f in filas:
            self.stdout.write(
                f"{f['tipo']:<14}{f['campo']:<16} celdas {f['celdas']:>5} · lectura {f['lectura_exacta']:>8} · "
                f"propuesta {f['propuesta_exacta']:>8} · marcadas {f['marcadas']:>8} · "
                f"errores sin marcar {f['errores_sin_marcar']}"
            )
        leidas = totales["celdas"] - totales["no_leidas"]
        self.stdout.write(
            f"TOTAL celdas {totales['celdas']} · lectura {porcentaje(totales['lectura_exacta'], leidas)} · "
            f"propuesta {porcentaje(totales['propuesta_exacta'], leidas)} · "
            f"errores sin marcar {totales['errores_sin_marcar']}"
        )
        if o["csv"] and filas:
            with open(o["csv"], "w", newline="", encoding="utf-8-sig") as f:
                w = csv.DictWriter(f, fieldnames=list(filas[0]))
                w.writeheader()
                w.writerows(filas)
            self.stdout.write(f"CSV: {o['csv']}")
