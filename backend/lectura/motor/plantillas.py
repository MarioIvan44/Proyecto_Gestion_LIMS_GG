"""
Qué campos tiene cada tipo de hoja del laboratorio.

BORRADOR (versión «0-borrador»): los campos salen de las hojas de referencia
(SPT de campo, M23-REG 02 y M04-REG01) y del Anexo 02. Falta confirmarlos uno por
uno contra la hoja impresa y ajustar nombres y orden antes de leer hojas reales.
Cualquier cambio sube la versión, y cada hoja guarda con qué versión se leyó.

Celdas: la fila 0 es el encabezado de la hoja (sondeo, fecha...); las filas 1, 2,
3... son los renglones de la tabla, en el orden en que aparecen en la hoja.
"""

from dataclasses import dataclass, field

from . import validaciones as v
from .vocabularios import ENSAYO_ATTERBERG, PLASTICIDAD, SIMBOLO_USCS

ENTERO = "entero"
DECIMAL = "decimal"
TEXTO = "texto"
OPCION = "opcion"

ENCABEZADO = "encabezado"
FILA = "fila"

VERSION = "0-borrador"


@dataclass(frozen=True)
class Campo:
    nombre: str
    etiqueta: str  # texto que ve el revisor
    tipo: str
    ubicacion: str = FILA
    vocabulario: str | None = None
    unidad: str | None = None

    def a_dict(self):
        return {
            "nombre": self.nombre, "etiqueta": self.etiqueta, "tipo": self.tipo,
            "ubicacion": self.ubicacion, "vocabulario": self.vocabulario, "unidad": self.unidad,
        }


@dataclass(frozen=True)
class Plantilla:
    tipo: str
    nombre: str
    campos: tuple[Campo, ...]
    relaciones: tuple = field(default=())
    version: str = VERSION

    def campo(self, nombre: str) -> Campo | None:
        return next((c for c in self.campos if c.nombre == nombre), None)

    def a_dict(self):
        return {
            "tipo": self.tipo, "nombre": self.nombre, "version": self.version,
            "campos": [c.a_dict() for c in self.campos],
        }


def _enc(nombre, etiqueta, tipo=TEXTO, **kw):
    return Campo(nombre, etiqueta, tipo, ubicacion=ENCABEZADO, **kw)


SPT = Plantilla(
    tipo="spt",
    nombre="Registro de campo SPT",
    campos=(
        _enc("sondeo", "Sondeo"),
        _enc("fecha", "Fecha"),
        _enc("operador", "Operador"),
        Campo("profundidad", "Profundidad", DECIMAL, unidad="m"),
        Campo("golpes_1", "Golpes tramo 1", ENTERO),
        Campo("golpes_2", "Golpes tramo 2", ENTERO),
        Campo("golpes_3", "Golpes tramo 3", ENTERO),
        Campo("n_spt", "N", ENTERO),
        Campo("recuperacion_cm", "Recuperación", ENTERO, unidad="cm"),
        Campo("descripcion", "Descripción", TEXTO),
    ),
    relaciones=(v.N_IGUAL_TRAMO2_MAS_TRAMO3, v.PROFUNDIDAD_CRECIENTE),
)

CLASIFICACION = Plantilla(
    tipo="clasificacion",
    nombre="Clasificación SUCS (M23-REG 02)",
    campos=(
        _enc("sondeo", "Sondeo"),
        Campo("muestra", "Muestra", TEXTO),
        Campo("profundidad", "Profundidad", DECIMAL, unidad="m"),
        Campo("pct_grava", "% grava", DECIMAL, unidad="%"),
        Campo("pct_arena", "% arena", DECIMAL, unidad="%"),
        Campo("pct_finos", "% finos", DECIMAL, unidad="%"),
        Campo("simbolo", "Símbolo SUCS", OPCION, vocabulario=SIMBOLO_USCS),
        Campo("plasticidad", "Plasticidad de finos", OPCION, vocabulario=PLASTICIDAD),
        Campo("descripcion", "Descripción", TEXTO),
    ),
    relaciones=(v.PORCENTAJES_SUMAN_100,),
)

ATTERBERG = Plantilla(
    tipo="atterberg",
    nombre="Límites de Atterberg (M04-REG01)",
    campos=(
        _enc("sondeo", "Sondeo"),
        _enc("muestra", "Muestra"),
        _enc("profundidad", "Profundidad", DECIMAL, unidad="m"),
        _enc("ll", "Límite líquido (LL)", DECIMAL),
        _enc("lp", "Límite plástico (LP)", DECIMAL),
        _enc("ip", "Índice de plasticidad (IP)", DECIMAL),
        Campo("ensayo", "Determinación (LL o LP)", OPCION, vocabulario=ENSAYO_ATTERBERG),
        Campo("golpes", "Golpes", ENTERO),
        Campo("humedad", "Humedad", DECIMAL, unidad="%"),
    ),
    relaciones=(v.IP_IGUAL_LL_MENOS_LP,),
)

PLANTILLAS = {p.tipo: p for p in (SPT, CLASIFICACION, ATTERBERG)}
