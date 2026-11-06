"""
Servicios de lectura de imágenes («proveedores»).

Todos cumplen la misma interfaz: reciben la imagen y la plantilla de la hoja, y
devuelven celdas con texto y confianza. Así se pueden comparar varios servicios
con las mismas hojas de referencia y cambiar de uno a otro sin tocar el resto
del sistema.

Por ahora hay dos:
- «manual»: no lee nada; el revisor captura todo con la foto al lado.
- «simulado»: devuelve una lectura guardada en un JSON (para pruebas y demos con
  datos inventados).

Los servicios reales se agregan aquí después de la prueba comparativa con las
hojas de referencia, una clase por servicio, con su clave en `backend/.env`.

`pistas` lleva los vocabularios y los sinónimos aprendidos, para los servicios
que aceptan una lista de palabras esperadas o instrucciones de contexto.
"""

import hashlib
import json
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path

from .plantillas import Plantilla
from .propuestas import CeldaEntrada


class ErrorDeLectura(Exception):
    """El servicio no pudo leer la imagen. El mensaje se guarda en la hoja."""


@dataclass
class ResultadoLectura:
    celdas: list[CeldaEntrada]
    respuesta_cruda: dict = field(default_factory=dict)


class ProveedorLectura(ABC):
    nombre: str = ""

    @abstractmethod
    def leer(self, imagen: bytes, tipo_contenido: str, plantilla: Plantilla, pistas: dict) -> ResultadoLectura:
        ...


class ProveedorManual(ProveedorLectura):
    nombre = "manual"

    def leer(self, imagen, tipo_contenido, plantilla, pistas):
        return ResultadoLectura([], {"nota": "captura manual: el servicio no lee la imagen"})


class ProveedorSimulado(ProveedorLectura):
    """
    Busca `<sha256 de la imagen>.json` en `directorio` con este formato:
    {"celdas": [{"fila": 1, "campo": "golpes_1", "texto": "5", "confianza": 0.93}]}
    """

    nombre = "simulado"

    def __init__(self, directorio):
        if not directorio:
            raise ErrorDeLectura("Falta LECTURA_SIMULADO_DIR para el proveedor simulado.")
        self.directorio = Path(directorio)

    def leer(self, imagen, tipo_contenido, plantilla, pistas):
        ruta = self.directorio / f"{hashlib.sha256(imagen).hexdigest()}.json"
        if not ruta.exists():
            raise ErrorDeLectura(f"No hay lectura simulada para esta imagen ({ruta.name}).")
        datos = json.loads(ruta.read_text(encoding="utf-8"))
        celdas = [
            CeldaEntrada(
                fila=int(c["fila"]), campo=str(c["campo"]), texto=c.get("texto"),
                confianza=c.get("confianza"), caja=c.get("caja"),
            )
            for c in datos.get("celdas", [])
        ]
        return ResultadoLectura(celdas, datos)


def obtener_proveedor(nombre: str, configuracion: dict) -> ProveedorLectura:
    if nombre == ProveedorManual.nombre:
        return ProveedorManual()
    if nombre == ProveedorSimulado.nombre:
        return ProveedorSimulado(configuracion.get("simulado_dir"))
    raise ErrorDeLectura(f"Proveedor de lectura desconocido: «{nombre}».")
