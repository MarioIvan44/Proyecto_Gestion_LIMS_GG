"""
Carga los departamentos de la empresa y los roles de cada uno desde un archivo JSON.

    python manage.py cargar_roles nucleo/roles_departamentos.json
    python manage.py cargar_roles nucleo/roles_departamentos.json --simular

Se puede correr varias veces: actualiza lo que ya existe y agrega lo que falta (busca los
departamentos por nombre y los roles por departamento + código). No borra nada: si un rol
desaparece del archivo, el comando lo avisa y queda a criterio quitarlo a mano, para no dejar
gente sin permisos sin darse cuenta.

Formato del archivo (ver nucleo/roles_departamentos.json):

    {
      "departamentos": [
        {
          "nombre": "Laboratorio",
          "descripcion": "Ensayos a materiales y geotecnia",
          "roles": [
            {
              "codigo": "jefe",
              "nombre": "Jefe de laboratorio",
              "es_jefatura": true,
              "permisos": ["lab.change_ensayo", "lab.view_ensayo"]
            }
          ]
        }
      ]
    }

El grupo de Django de cada rol se llama "<departamento en minúsculas y con guiones>_<codigo>",
por ejemplo laboratorio_jefe, siguiendo el estilo que ya usa Gestión GG (gestion_laboratorio).
Los permisos son los de Django, con el formato "app.codename"; si alguno no existe, el comando
lo dice y no lo asigna.
"""

import json
from pathlib import Path

from django.contrib.auth.models import Group, Permission
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils.text import slugify

from nucleo.models import Departamento, RolDepartamento


def nombre_de_grupo(departamento_nombre, codigo_rol):
    """laboratorio_jefe, gerencia_asistente..."""
    return f"{slugify(departamento_nombre).replace('-', '_')}_{slugify(codigo_rol).replace('-', '_')}"


class Command(BaseCommand):
    help = "Carga departamentos y sus roles (grupos de Django) desde un archivo JSON."

    def add_arguments(self, parser):
        parser.add_argument("archivo", type=Path, help="Ruta del archivo JSON con la lista.")
        parser.add_argument(
            "--simular",
            action="store_true",
            help="Muestra lo que haría sin guardar nada.",
        )

    def handle(self, *args, **opciones):
        archivo = opciones["archivo"]
        simular = opciones["simular"]

        if not archivo.exists():
            raise CommandError(f"No existe el archivo {archivo}")
        try:
            datos = json.loads(archivo.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            raise CommandError(f"El archivo no es JSON válido: {e}") from e

        departamentos = datos.get("departamentos")
        if not departamentos:
            raise CommandError(
                f"{archivo} no trae departamentos todavía. "
                "Hay que llenarlo con la lista de la empresa (ver PENDIENTES.md)."
            )

        resumen = {"departamentos": 0, "roles": 0, "permisos": 0}
        avisos = []

        with transaction.atomic():
            vistos = set()
            for d in departamentos:
                nombre_depto = (d.get("nombre") or "").strip()
                if not nombre_depto:
                    raise CommandError("Hay un departamento sin nombre en el archivo.")

                depto, creado = Departamento.objects.get_or_create(
                    nombre=nombre_depto,
                    defaults={"descripcion": d.get("descripcion"), "activo": True},
                )
                if not creado and d.get("descripcion") and depto.descripcion != d["descripcion"]:
                    depto.descripcion = d["descripcion"]
                    depto.save(update_fields=["descripcion"])
                resumen["departamentos"] += 1
                self.stdout.write(
                    f"{'+ nuevo ' if creado else '  ya estaba '} departamento: {nombre_depto}"
                )

                for r in d.get("roles", []):
                    codigo = (r.get("codigo") or "").strip()
                    nombre_rol = (r.get("nombre") or "").strip()
                    if not codigo or not nombre_rol:
                        raise CommandError(
                            f"En {nombre_depto} hay un rol sin código o sin nombre."
                        )

                    nombre_grupo = nombre_de_grupo(nombre_depto, codigo)
                    grupo, _ = Group.objects.get_or_create(name=nombre_grupo)
                    rol, rol_creado = RolDepartamento.objects.update_or_create(
                        departamento=depto,
                        codigo=codigo,
                        defaults={
                            "grupo": grupo,
                            "nombre": nombre_rol,
                            "descripcion": r.get("descripcion"),
                            "es_jefatura": bool(r.get("es_jefatura", False)),
                            "es_supuesto": bool(r.get("es_supuesto", True)),
                        },
                    )
                    vistos.add(rol.pk)
                    resumen["roles"] += 1
                    self.stdout.write(
                        f"    {'+ nuevo' if rol_creado else '  actualizado'} rol: "
                        f"{nombre_rol} (grupo {nombre_grupo})"
                    )

                    permisos_pedidos = r.get("permisos", [])
                    if permisos_pedidos:
                        permisos, faltantes = self._buscar_permisos(permisos_pedidos)
                        grupo.permissions.set(permisos)
                        resumen["permisos"] += len(permisos)
                        for f in faltantes:
                            avisos.append(f"{nombre_grupo}: no existe el permiso {f}")

            sobrantes = RolDepartamento.objects.exclude(pk__in=vistos)
            for rol in sobrantes:
                avisos.append(
                    f"el rol {rol} está en la base pero no en el archivo "
                    f"(no se borró: revisar a mano quién lo tiene)"
                )

            if simular:
                transaction.set_rollback(True)
                self.stdout.write(self.style.WARNING("\n--simular: no se guardó nada."))

        for aviso in avisos:
            self.stdout.write(self.style.WARNING(f"AVISO: {aviso}"))

        self.stdout.write(
            self.style.SUCCESS(
                f"\n{resumen['departamentos']} departamentos, {resumen['roles']} roles, "
                f"{resumen['permisos']} permisos asignados."
            )
        )

    @staticmethod
    def _buscar_permisos(codigos):
        encontrados, faltantes = [], []
        for codigo in codigos:
            if "." not in codigo:
                faltantes.append(f"{codigo} (falta el app_label, por ejemplo lab.view_ensayo)")
                continue
            app_label, codename = codigo.split(".", 1)
            permiso = Permission.objects.filter(
                content_type__app_label=app_label, codename=codename
            ).first()
            if permiso:
                encontrados.append(permiso)
            else:
                faltantes.append(codigo)
        return encontrados, faltantes
