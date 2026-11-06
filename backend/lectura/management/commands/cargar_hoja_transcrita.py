"""
python manage.py cargar_hoja_transcrita --imagen foto.jpg --tipo spt --transcripcion hoja.json
       --usuario correo@empresa [--conjunto entrenamiento|prueba] [--folio F-001]

Carga una hoja que YA está digitalizada correctamente (por ejemplo, las hojas de
referencia transcritas a mano): sube la foto, la manda a leer y usa la
transcripción como valor final de cada celda. Así el sistema aprende (conjunto
«entrenamiento») o se mide (conjunto «prueba») con documentos que ya conocemos.

Formato de la transcripción. Debe estar COMPLETA: una celda que el servicio leyó
y que no aparece aquí se toma como vacía en la hoja.
{"celdas": [{"fila": 0, "campo": "sondeo", "valor": "S-1"},
            {"fila": 1, "campo": "golpes_1", "valor": "5"},
            {"fila": 1, "campo": "descripcion", "valor": null, "ilegible": true}]}
"""

import json
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from lectura import servicios
from lectura.models import CampoLeido, HojaEscaneada
from nucleo.models import Usuario


class Command(BaseCommand):
    help = "Carga una hoja con su transcripción correcta (para aprender o medir)."

    def add_arguments(self, parser):
        parser.add_argument("--imagen", required=True)
        parser.add_argument("--tipo", required=True)
        parser.add_argument("--transcripcion", required=True)
        parser.add_argument("--usuario", required=True, help="Correo de quien hizo o verificó la transcripción.")
        parser.add_argument("--conjunto", default="entrenamiento", choices=["entrenamiento", "prueba"])
        parser.add_argument("--folio")

    def handle(self, *args, **o):
        usuario = Usuario.objects.filter(email__iexact=o["usuario"]).first()
        if usuario is None:
            raise CommandError(f"No existe el usuario {o['usuario']}.")
        transcripcion = json.loads(Path(o["transcripcion"]).read_text(encoding="utf-8"))
        celdas = transcripcion.get("celdas")
        if not isinstance(celdas, list):
            raise CommandError("La transcripción debe tener una lista «celdas».")

        hoja = None
        try:
            with transaction.atomic():
                hoja = servicios.registrar_hoja(
                    Path(o["imagen"]).read_bytes(), o["tipo"], usuario,
                    folio=o["folio"] or transcripcion.get("folio"), conjunto=o["conjunto"],
                )
                if hoja.estado != HojaEscaneada.Estado.EN_REVISION:
                    raise CommandError(f"No se pudo leer la hoja: {hoja.error}")
                cambios = [
                    {
                        "fila": c.get("fila"), "campo": c.get("campo"), "valor_final": c.get("valor"),
                        "ilegible": c.get("ilegible", False),
                        "motivo": c.get("motivo") or "transcripción de referencia",
                    }
                    for c in celdas
                ]
                transcritas = {(int(c["fila"]), c["campo"]) for c in cambios if c["fila"] is not None}
                for c in hoja.campos.filter(estado=CampoLeido.Estado.PENDIENTE):
                    if (c.fila, c.campo) not in transcritas:
                        cambios.append({
                            "fila": c.fila, "campo": c.campo, "valor_final": None,
                            "motivo": "vacía en la transcripción",
                        })
                servicios.guardar_revision(hoja, cambios, usuario)
                servicios.cerrar_revision(hoja, usuario, aceptar_advertencias=True)
        except Exception as e:
            # Se deshizo todo en la base: borrar también la foto para no dejarla suelta.
            if hoja is not None and hoja.imagen:
                hoja.imagen.delete(save=False)
            if isinstance(e, servicios.ErrorDeFlujo):
                raise CommandError(f"{e.mensaje} {e.datos}")
            raise

        hoja.refresh_from_db()
        corregidas = hoja.campos.filter(estado=CampoLeido.Estado.CORREGIDO).count()
        self.stdout.write(
            f"Hoja {hoja.id} cargada ({o['conjunto']}): {hoja.campos.count()} celdas, "
            f"{corregidas} distintas de la propuesta."
        )
