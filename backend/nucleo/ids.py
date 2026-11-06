"""
Identificadores UUID versión 7: empiezan con la hora de creación, así que ordenados
como texto quedan en orden cronológico, igual que los ObjectId de MongoDB. El
backend Node depende de esa propiedad (por ejemplo, ordena listas por _id).

Estructura (128 bits): 48 de tiempo en milisegundos | versión 7 | 12 bits |
variante RFC | 62 bits.
"""

import os
import time
import uuid

from bson import ObjectId

_MASCARA_62 = (1 << 62) - 1


def _armar(milisegundos: int, cola: int) -> uuid.UUID:
    """`cola` son 74 bits: los 12 primeros van antes de la variante y los 62 últimos después."""
    rand_a = (cola >> 62) & 0xFFF
    rand_b = cola & _MASCARA_62
    valor = ((milisegundos & ((1 << 48) - 1)) << 80) | (0x7 << 76) | (rand_a << 64) | (0b10 << 62) | rand_b
    return uuid.UUID(int=valor)


def uuid7() -> uuid.UUID:
    """UUID versión 7 con la hora actual."""
    return _armar(time.time_ns() // 1_000_000, int.from_bytes(os.urandom(10), "big") >> 6)


def uuid7_desde_objectid(oid, variante: int = 0) -> uuid.UUID:
    """
    UUID versión 7 derivado de un ObjectId: conserva su hora y sus 8 bytes
    restantes, así que el orden entre UUID es el mismo que entre los ObjectId.
    `variante` (0 a 1023) distingue filas que salen del mismo documento (por
    ejemplo, un empleado y su cuenta de acceso).
    """
    binario = (oid if isinstance(oid, ObjectId) else ObjectId(str(oid))).binary
    segundos = int.from_bytes(binario[:4], "big")
    resto = int.from_bytes(binario[4:], "big")  # 64 bits
    return _armar(segundos * 1000, (resto << 10) | (variante & 0x3FF))
