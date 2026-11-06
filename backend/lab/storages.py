"""
Dónde se guardan los archivos del laboratorio: Cloudinary (decisión del equipo, nov-2026).

Se usa un almacenamiento con nombre ("cloudinary" en STORAGES, ver config/settings/base.py) y
no el almacenamiento por defecto, porque el por defecto lo ocupa la app `lectura`, cuyas fotos
son datos de clientes y se guardan fuera del repositorio sin publicarse.

Los campos de archivo del LIMS apuntan aquí con `storage=almacenamiento_lab`. Se pasa la
función, no el objeto: así las migraciones guardan solo la referencia y la configuración de
Cloudinary se lee cuando se usa, no al importar el módulo.
"""

from django.core.files.storage import storages


def almacenamiento_lab():
    """El almacenamiento donde van los archivos del LIMS (certificados, informes, adjuntos)."""
    return storages["lab_archivos"]
