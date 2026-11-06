"""Interpretación de números escritos a mano."""

import re
from decimal import Decimal, InvalidOperation

_NUMERO = re.compile(r"^-?\d+(\.\d+)?$")


def limpiar(texto: str) -> tuple[str, bool]:
    """
    Quita espacios y cambia la coma decimal por punto («12,5» → «12.5»).
    Devuelve (texto limpio, si hubo que cambiar el formato).
    """
    original = str(texto).strip()
    limpio = re.sub(r"\s+", "", original).replace(",", ".")
    return limpio, limpio != original


def es_numero(texto: str, entero: bool = False) -> bool:
    if not _NUMERO.match(texto or ""):
        return False
    return not entero or "." not in texto


def a_decimal(texto) -> Decimal | None:
    """Número de un texto ya propuesto; None si está vacío o no es un número."""
    if texto is None or str(texto).strip() == "":
        return None
    limpio, _ = limpiar(texto)
    if not es_numero(limpio):
        return None
    try:
        return Decimal(limpio)
    except InvalidOperation:
        return None
