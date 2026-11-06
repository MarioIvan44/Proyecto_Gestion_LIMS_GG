"""Normalización y alineación de textos."""

import re
import unicodedata
from difflib import SequenceMatcher

_MARCA_ENIE = ""  # carácter privado para que la Ñ no pierda la tilde al normalizar


def clave(texto) -> str:
    """
    Forma de comparar dos textos: mayúsculas, sin tildes (pero conserva la Ñ),
    espacios simples y sin puntuación en los bordes. «Arcilla  limosa.» y
    «ARCILLA LIMOSA» tienen la misma clave.
    """
    if texto is None:
        return ""
    t = str(texto).replace("ñ", _MARCA_ENIE).replace("Ñ", _MARCA_ENIE)
    t = unicodedata.normalize("NFKD", t)
    t = "".join(c for c in t if not unicodedata.combining(c))
    t = t.upper().replace(_MARCA_ENIE, "Ñ")
    t = re.sub(r"\s+", " ", t).strip(" .,;:")
    return t


def palabras(texto) -> list[str]:
    return str(texto or "").split()


def pares_de_caracteres(leido: str, real: str) -> list[tuple[str, str]]:
    """
    Alinea lo leído con lo correcto y devuelve pares (carácter leído, carácter real).
    Incluye los aciertos (a, a) para poder calcular probabilidades. Solo toma
    sustituciones de igual largo: si sobran o faltan letras no se sabe con
    certeza cuál corresponde a cuál, así que ese tramo se ignora.
    """
    pares = []
    for op, i1, i2, j1, j2 in SequenceMatcher(None, leido, real, autojunk=False).get_opcodes():
        if op == "equal" or (op == "replace" and i2 - i1 == j2 - j1):
            pares.extend(zip(leido[i1:i2], real[j1:j2]))
    return pares


def pares_de_palabras(leido: str, real: str) -> list[tuple[str, str]]:
    """
    Palabras que el revisor cambió una por una: («C/», «con»), («HINO», «LIMO»).
    Devuelve (clave de la palabra leída, palabra real tal como la escribió el revisor).
    """
    ps_leido, ps_real = palabras(leido), palabras(real)
    claves_leido = [clave(p) for p in ps_leido]
    claves_real = [clave(p) for p in ps_real]
    pares = []
    for op, i1, i2, j1, j2 in SequenceMatcher(None, claves_leido, claves_real, autojunk=False).get_opcodes():
        if op == "replace" and i2 - i1 == j2 - j1:
            for i, j in zip(range(i1, i2), range(j1, j2)):
                if claves_leido[i]:
                    pares.append((claves_leido[i], ps_real[j]))
    return pares


def distancia(a: str, b: str, costo_sustitucion=None) -> float:
    """
    Distancia de edición (Levenshtein). `costo_sustitucion(x, y)` permite que
    cambiar una letra por otra con la que se confunde a menudo cueste menos de 1.
    """
    if costo_sustitucion is None:
        def costo_sustitucion(x, y):
            return 0.0 if x == y else 1.0
    anterior = [float(j) for j in range(len(b) + 1)]
    for i, x in enumerate(a, 1):
        actual = [float(i)] + [0.0] * len(b)
        for j, y in enumerate(b, 1):
            actual[j] = min(
                anterior[j] + 1,
                actual[j - 1] + 1,
                anterior[j - 1] + costo_sustitucion(x, y),
            )
        anterior = actual
    return anterior[-1]
