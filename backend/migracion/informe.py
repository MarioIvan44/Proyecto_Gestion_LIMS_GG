"""
Informe de la migración: qué se migró, qué no y por qué.

Se escribe en `migracion/informes/<fecha-hora>/` (carpeta fuera de git, porque
puede contener datos personales):
- informe.md          resumen legible
- rechazos.csv        cada documento o elemento que no se migró, con el motivo
- advertencias.csv    cada cambio o hallazgo en lo que sí se migró
- resumen.json        los mismos números, para comparar corridas
"""

import csv
import json
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from pathlib import Path

from django.utils import timezone


@dataclass
class EstadisticaColeccion:
    coleccion: str
    tabla: str
    total_mongo: int = 0
    excluidos_demo: int = 0
    omitidos: int = 0
    insertados: int = 0
    actualizados: int = 0
    rechazados: int = 0
    con_advertencias: set = field(default_factory=set)

    @property
    def considerados(self):
        return self.total_mongo - self.excluidos_demo - self.omitidos


@dataclass
class EstadisticaHijos:
    coleccion: str
    arreglo: str
    tabla: str
    elementos: int = 0
    migrados: int = 0
    rechazados: int = 0
    eliminados: int = 0


class Informe:
    def __init__(self, opciones):
        self.inicio = timezone.now()
        self.fin = None
        self.opciones = opciones
        self.colecciones = {}
        self.hijos = {}
        self.rechazos = []
        self.advertencias = []
        self.conversiones = Counter()
        self.campos_extra = defaultdict(Counter)
        self.no_reconocidas = {}
        self.sin_documento_en_mongo = []
        self.conteos = []
        self.sumas = []
        self.cuadres = []
        self.correcciones = []
        self.correcciones_sin_usar = []

    # -- registro -------------------------------------------------------------

    def coleccion(self, nombre, tabla):
        if nombre not in self.colecciones:
            self.colecciones[nombre] = EstadisticaColeccion(nombre, tabla)
        return self.colecciones[nombre]

    def hijo(self, coleccion, arreglo, tabla):
        clave = (coleccion, arreglo)
        if clave not in self.hijos:
            self.hijos[clave] = EstadisticaHijos(coleccion, arreglo, tabla)
        return self.hijos[clave]

    def rechazo(self, coleccion, mongo_id, campo, motivo, conservada=False):
        self.rechazos.append({
            "coleccion": coleccion, "mongo_id": mongo_id, "campo": campo or "", "motivo": motivo,
            "nota": "se conserva la versión migrada en una corrida anterior" if conservada else "",
        })

    def advertencia(self, coleccion, mongo_id, campo, mensaje):
        self.advertencias.append({"coleccion": coleccion, "mongo_id": mongo_id, "campo": campo or "", "mensaje": mensaje})
        if coleccion in self.colecciones:
            self.colecciones[coleccion].con_advertencias.add(mongo_id)

    def confirmar(self, ctx):
        """Pasa al informe lo observado al convertir un documento que sí se migró."""
        for campo, mensaje in ctx.advertencias:
            self.advertencia(ctx.coleccion, ctx.mongo_id, campo, mensaje)
        for tipo, campo in ctx.conteos:
            self.conversiones[(ctx.coleccion, tipo, campo)] += 1

    def conversion(self, coleccion, tipo, campo, cantidad=1):
        self.conversiones[(coleccion, tipo, campo)] += cantidad

    # -- salida ---------------------------------------------------------------

    def resumen(self):
        return {
            "inicio": self.inicio.isoformat(),
            "fin": self.fin.isoformat() if self.fin else None,
            "opciones": self.opciones,
            "colecciones": [
                {**{k: v for k, v in asdict(e).items() if k != "con_advertencias"},
                 "considerados": e.considerados, "con_advertencias": len(e.con_advertencias)}
                for e in self.colecciones.values()
            ],
            "hijos": [asdict(h) for h in self.hijos.values()],
            "rechazos": len(self.rechazos),
            "advertencias": len(self.advertencias),
            "conversiones": [
                {"coleccion": c, "tipo": t, "campo": f, "cantidad": n} for (c, t, f), n in sorted(self.conversiones.items())
            ],
            "campos_extra": {c: dict(campos) for c, campos in self.campos_extra.items()},
            "colecciones_no_reconocidas": self.no_reconocidas,
            "filas_sin_documento_en_mongo": self.sin_documento_en_mongo,
            "conteos": self.conteos,
            "sumas": self.sumas,
            "cuadres": self.cuadres,
            "correcciones": self.correcciones,
            "correcciones_sin_usar": self.correcciones_sin_usar,
        }

    def escribir(self, carpeta: Path):
        carpeta.mkdir(parents=True, exist_ok=True)
        with open(carpeta / "rechazos.csv", "w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=["coleccion", "mongo_id", "campo", "motivo", "nota"])
            w.writeheader()
            w.writerows(self.rechazos)
        with open(carpeta / "advertencias.csv", "w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=["coleccion", "mongo_id", "campo", "mensaje"])
            w.writeheader()
            w.writerows(self.advertencias)
        (carpeta / "resumen.json").write_text(json.dumps(self.resumen(), ensure_ascii=False, indent=2, default=str), encoding="utf-8")
        (carpeta / "informe.md").write_text(self._markdown(), encoding="utf-8")

    def _markdown(self):
        o = self.opciones
        lineas = [
            "# Informe de migración MongoDB → PostgreSQL",
            "",
            f"- Inicio: {self.inicio:%Y-%m-%d %H:%M:%S %Z} · Fin: {self.fin:%Y-%m-%d %H:%M:%S %Z}" if self.fin else f"- Inicio: {self.inicio}",
            f"- Origen: MongoDB `{o.get('mongo_host')}`, base `{o.get('mongo_db')}` (versión {o.get('mongo_version')}), solo lectura",
            f"- Destino: PostgreSQL `{o.get('pg_host')}`, base `{o.get('pg_db')}`",
            f"- Modo: {'**SIMULACIÓN** (no se guardó nada en PostgreSQL)' if o.get('simular') else 'migración real'}",
            f"- Datos de demostración (`isSeedData`): {'incluidos' if o.get('incluir_demo') else 'excluidos'}",
            "",
            "## 1. Resumen por colección",
            "",
            "| Colección | Tabla | En MongoDB | Demo excluidos | Omitidos por corrección | Insertados | Actualizados | Rechazados | Con advertencias |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|",
        ]
        for e in self.colecciones.values():
            lineas.append(
                f"| {e.coleccion} | {e.tabla} | {e.total_mongo} | {e.excluidos_demo} | {e.omitidos} | {e.insertados} | {e.actualizados} "
                f"| {e.rechazados} | {len(e.con_advertencias)} |"
            )
        if self.hijos:
            lineas += ["", "Elementos de arreglos (subdocumentos) que pasan a tablas hijas:", "",
                       "| Colección.arreglo | Tabla | Elementos | Migrados | Rechazados | Eliminados (ya no están en el arreglo) |",
                       "|---|---|---:|---:|---:|---:|"]
            for h in self.hijos.values():
                lineas.append(f"| {h.coleccion}.{h.arreglo} | {h.tabla} | {h.elementos} | {h.migrados} | {h.rechazados} | {h.eliminados} |")

        lineas += ["", "## 2. Validación: conteos", "",
                   "Filas en PostgreSQL que vienen de cada colección, contra lo que el script dice haber migrado.", "",
                   "| Tabla | Esperadas | En PostgreSQL | ¿Cuadra? |", "|---|---:|---:|---|"]
        for c in self.conteos:
            lineas.append(f"| {c['tabla']} | {c['esperadas']} | {c['en_postgresql']} | {'sí' if c['cuadra'] else '**NO**'} |")

        lineas += ["", "## 3. Validación: sumas", "",
                   "Suma de cada columna de dinero u horas: valores originales de MongoDB (solo de lo migrado) contra PostgreSQL. "
                   "La diferencia esperada es solo el redondeo a 4 decimales.", "",
                   "| Tabla.columna | Filas | Suma MongoDB | Suma PostgreSQL | Diferencia | ¿Cuadra? |", "|---|---:|---:|---:|---:|---|"]
        for s in self.sumas:
            lineas.append(f"| {s['tabla']}.{s['columna']} | {s['filas']} | {s['mongo']} | {s['postgresql']} | {s['diferencia']} | {'sí' if s['cuadra'] else '**NO**'} |")

        if self.cuadres:
            lineas += ["", "## 4. Totales que no cuadran con sus partes", "",
                       "Se migraron tal cual (son documentos históricos); revisar con la empresa.", "",
                       "| Verificación | Revisadas | No cuadran |", "|---|---:|---:|"]
            for c in self.cuadres:
                lineas.append(f"| {c['descripcion']} | {c['revisadas']} | {c['no_cuadran']} |")

        lineas += ["", "## 4b. Correcciones aplicadas", "",
                   "Cambios decididos por la empresa (archivo de correcciones). MongoDB no se modificó.", ""]
        if self.correcciones:
            lineas += ["| Colección | _id | Cambio | Motivo |", "|---|---|---|---|"]
            for c in self.correcciones:
                lineas.append(f"| {c['coleccion']} | `{c['mongo_id']}` | {c['cambio']} | {c['motivo']} |")
        else:
            lineas.append("Ninguna.")
        if self.correcciones_sin_usar:
            lineas += ["", "**Correcciones que no se aplicaron** (el documento no apareció en MongoDB):", ""]
            for c in self.correcciones_sin_usar:
                lineas.append(f"- {c['coleccion']} `{c['_id']}`: {c['motivo']}")
        lineas += ["", "## 5. Rechazos", "",
                   f"{len(self.rechazos)} en total. Lista completa en `rechazos.csv`.", ""]
        if self.rechazos:
            lineas += ["| Colección | _id | Campo | Motivo |", "|---|---|---|---|"]
            for r in self.rechazos[:300]:
                nota = f" ({r['nota']})" if r["nota"] else ""
                lineas.append(f"| {r['coleccion']} | `{r['mongo_id']}` | {r['campo']} | {r['motivo']}{nota} |")
            if len(self.rechazos) > 300:
                lineas.append(f"| … | | | {len(self.rechazos) - 300} más en `rechazos.csv` |")

        lineas += ["", "## 6. Advertencias", "", f"{len(self.advertencias)} en total. Lista completa en `advertencias.csv`.", ""]
        if self.advertencias:
            lineas += ["| Colección | _id | Campo | Detalle |", "|---|---|---|---|"]
            for a in self.advertencias[:300]:
                lineas.append(f"| {a['coleccion']} | `{a['mongo_id']}` | {a['campo']} | {a['mensaje']} |")
            if len(self.advertencias) > 300:
                lineas.append(f"| … | | | {len(self.advertencias) - 300} más en `advertencias.csv` |")

        lineas += ["", "## 7. Conversiones aplicadas", "",
                   "Cambios de forma que no alteran el dato (se cuentan, no se listan uno por uno).", ""]
        if self.conversiones:
            lineas += ["| Colección | Tipo | Campo | Cantidad |", "|---|---|---|---:|"]
            for (c, t, f), n in sorted(self.conversiones.items()):
                lineas.append(f"| {c} | {t} | {f} | {n} |")
        else:
            lineas.append("Ninguna.")

        lineas += ["", "## 8. Campos fuera del esquema", "",
                   "Se guardaron en la columna `datos_extra` de cada fila.", ""]
        if self.campos_extra:
            lineas += ["| Colección | Campo | Documentos |", "|---|---|---:|"]
            for c, campos in self.campos_extra.items():
                for nombre, n in campos.most_common():
                    lineas.append(f"| {c} | {nombre} | {n} |")
        else:
            lineas.append("Ninguno.")

        lineas += ["", "## 9. Colecciones que no se migran", ""]
        if self.no_reconocidas:
            lineas += ["La aplicación no las usa; quedan en MongoDB sin cambios.", "", "| Colección | Documentos |", "|---|---:|"]
            for c, n in self.no_reconocidas.items():
                lineas.append(f"| {c} | {n} |")
        else:
            lineas.append("Ninguna.")

        lineas += ["", "## 10. Filas sin documento en MongoDB", "",
                   "Filas migradas antes cuyo documento ya no existe en MongoDB. No se borran; solo se informan.", ""]
        if self.sin_documento_en_mongo:
            lineas += ["| Tabla | mongo_id |", "|---|---|"]
            for fila in self.sin_documento_en_mongo:
                lineas.append(f"| {fila['tabla']} | `{fila['mongo_id']}` |")
        else:
            lineas.append("Ninguna.")
        return "\n".join(lineas) + "\n"
