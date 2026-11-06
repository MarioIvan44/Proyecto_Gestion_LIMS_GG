"""
python manage.py migrar_mongo --simular
python manage.py migrar_mongo --destino <base> [--incluir-demo]

Copia la base MongoDB del sistema administrativo a PostgreSQL. MongoDB solo se lee.
Se puede correr las veces que haga falta: no duplica datos (ver migracion/README.md).
"""

from pathlib import Path

import pymongo
from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction
from django.utils import timezone
from pymongo.uri_parser import parse_uri

from migracion.correcciones import CorreccionInvalida, Correcciones
from migracion.informe import Informe
from migracion.motor import Motor, SoloLectura
from migracion.validacion import validar


class Command(BaseCommand):
    help = "Migra la base MongoDB del sistema administrativo a PostgreSQL y escribe un informe de validación."

    def add_arguments(self, parser):
        parser.add_argument("--simular", action="store_true",
                            help="Hace todo dentro de una transacción y al final la deshace: no guarda nada.")
        parser.add_argument("--destino", help="Nombre de la base PostgreSQL de destino. Obligatorio si no es simulación, "
                                              "para no escribir por error en otra base.")
        parser.add_argument("--incluir-demo", action="store_true",
                            help="Incluye los documentos de demostración (isSeedData). Solo para pruebas.")
        parser.add_argument("--mongo-uri", default=settings.MONGO_URI, help="Por defecto, MONGO_URI de backend/.env.")
        parser.add_argument("--mongo-db", default=settings.MONGO_DB, help="Por defecto, MONGO_DB de backend/.env.")
        parser.add_argument("--correcciones", default=str(Path(__file__).resolve().parents[2] / "correcciones.yaml"),
                            help="Archivo de correcciones decididas por la empresa (si existe).")
        parser.add_argument("--informes", default=str(Path(__file__).resolve().parents[2] / "informes"),
                            help="Carpeta donde se crea la carpeta del informe.")

    def handle(self, *args, **opciones):
        base_pg = connection.settings_dict["NAME"]
        if not opciones["simular"] and opciones["destino"] != base_pg:
            raise CommandError(f"La base configurada es «{base_pg}». Para escribir en ella pasa --destino {base_pg} "
                               "(o usa --simular).")
        if not opciones["mongo_uri"] or not opciones["mongo_db"]:
            raise CommandError("Faltan MONGO_URI y MONGO_DB (en backend/.env o como opciones).")

        try:
            correcciones = Correcciones.desde_archivo(opciones["correcciones"])
        except CorreccionInvalida as e:
            raise CommandError(str(e))

        nodos = parse_uri(opciones["mongo_uri"])["nodelist"]
        mongo_host = ",".join(f"{h}:{p}" for h, p in nodos)
        cliente = pymongo.MongoClient(opciones["mongo_uri"], tz_aware=True, appname="migracion-plataforma-jupaca",
                                      serverSelectionTimeoutMS=10000)
        db = cliente[opciones["mongo_db"]]
        if opciones["mongo_db"] not in cliente.list_database_names():
            raise CommandError(f"La base «{opciones['mongo_db']}» no existe en {mongo_host}.")

        informe = Informe({
            "mongo_host": mongo_host, "mongo_db": opciones["mongo_db"], "mongo_version": cliente.server_info().get("version"),
            "pg_host": f"{connection.settings_dict['HOST']}:{connection.settings_dict['PORT']}", "pg_db": base_pg,
            "simular": opciones["simular"], "incluir_demo": opciones["incluir_demo"],
        })
        self.stdout.write(f"Origen: {mongo_host}/{opciones['mongo_db']} (solo lectura) -> destino: {base_pg}"
                          f"{' [SIMULACIÓN]' if opciones['simular'] else ''}")

        if len(correcciones):
            self.stdout.write(f"Correcciones a aplicar: {len(correcciones)}")
        motor = Motor(SoloLectura(db), informe, incluir_demo=opciones["incluir_demo"], log=self.stdout.write,
                      correcciones=correcciones)
        with transaction.atomic():
            motor.ejecutar()
            validar(motor, informe)
            informe.correcciones_sin_usar = [
                {"coleccion": c["coleccion"], "_id": str(c["_id"]), "motivo": c["motivo"]} for c in correcciones.sin_usar()
            ]
            if opciones["simular"]:
                transaction.set_rollback(True)
        cliente.close()

        informe.fin = timezone.now()
        carpeta = Path(opciones["informes"]) / f"{informe.inicio.astimezone():%Y%m%d-%H%M%S}{'-simulacion' if opciones['simular'] else ''}"
        informe.escribir(carpeta)

        sin_cuadrar = [c for c in informe.conteos if not c["cuadra"]] + [s for s in informe.sumas if not s["cuadra"]]
        self.stdout.write(f"Rechazos: {len(informe.rechazos)} · Advertencias: {len(informe.advertencias)} · "
                          f"Conteos y sumas que no cuadran: {len(sin_cuadrar)}")
        self.stdout.write(self.style.SUCCESS(f"Informe: {carpeta / 'informe.md'}"))
        if sin_cuadrar:
            raise CommandError("Hay conteos o sumas que no cuadran; revisa las secciones 2 y 3 del informe.")
