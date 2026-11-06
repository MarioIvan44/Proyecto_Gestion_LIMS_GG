"""
python manage.py verificar_casos_prueba [--informe <carpeta>] [--casos <archivo>]

Compara el informe de una migración de la COPIA DE PRUEBA con el resultado
esperado de cada caso que insertó `copia_prueba/insertar_casos.mjs`.
"""

import csv
import json
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError

CARPETA_INFORMES = Path(__file__).resolve().parents[2] / "informes"


def _leer_csv(ruta):
    with open(ruta, encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


class Command(BaseCommand):
    help = "Comprueba que la migración de la copia de prueba trató cada caso como se esperaba."

    def add_arguments(self, parser):
        parser.add_argument("--informe", help="Carpeta del informe (por defecto, la más reciente).")
        parser.add_argument("--casos", default=str(CARPETA_INFORMES / "casos_prueba.json"))

    def handle(self, *args, **opciones):
        if opciones["informe"]:
            carpeta = Path(opciones["informe"])
        else:
            carpetas = sorted(p for p in CARPETA_INFORMES.iterdir() if p.is_dir())
            if not carpetas:
                raise CommandError("No hay informes.")
            carpeta = carpetas[-1]
        casos = json.loads(Path(opciones["casos"]).read_text(encoding="utf-8"))
        rechazos = _leer_csv(carpeta / "rechazos.csv")
        advertencias = _leer_csv(carpeta / "advertencias.csv")
        resumen = json.loads((carpeta / "resumen.json").read_text(encoding="utf-8"))

        rechazados = {r["mongo_id"] for r in rechazos}
        # Un elemento hijo rechazado deja una advertencia en su documento padre.
        con_advertencia = {a["mongo_id"] for a in advertencias}
        no_reconocidas = set(resumen["colecciones_no_reconocidas"])

        fallas = 0
        self.stdout.write(f"Informe: {carpeta}")
        for caso in casos:
            _id = caso["_id"]
            if caso["esperado"] == "no_migrado":
                obtenido = "no_migrado" if caso["coleccion"] in no_reconocidas else "migrado"
            elif _id in rechazados:
                obtenido = "rechazado"
            elif _id in con_advertencia:
                obtenido = "advertencia"
            else:
                obtenido = "importado"
            ok = obtenido == caso["esperado"]
            fallas += not ok
            marca = "OK " if ok else "MAL"
            self.stdout.write(f"  [{marca}] {caso['codigo']:4} {caso['coleccion']:20} esperado={caso['esperado']:12} "
                              f"obtenido={obtenido:12} {caso['detalle']}")
        if fallas:
            raise CommandError(f"{fallas} casos no se trataron como se esperaba.")
        self.stdout.write(self.style.SUCCESS(f"Los {len(casos)} casos se trataron como se esperaba."))
