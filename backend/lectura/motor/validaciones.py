"""
Reglas entre campos de una misma hoja.

Sirven para DETECTAR errores de lectura, no para corregirlos: si una regla no se
cumple, las celdas involucradas quedan marcadas para revisión. Solo cuando un
único cambio de un solo carácter, con una confusión conocida, hace que la regla se
cumpla, se ofrece ese cambio como propuesta (y aun así lo confirma una persona).

Las reglas que dependen de criterios todavía no confirmados por la empresa
(rechazo en SPT, redondeo de IP) lo dicen en su mensaje.
"""

from dataclasses import dataclass
from decimal import Decimal
from typing import Callable


@dataclass(frozen=True)
class Resultado:
    cumple: bool
    mensaje: str


@dataclass(frozen=True)
class Relacion:
    """Regla que se evalúa sobre los campos de una fila (o del encabezado)."""

    nombre: str
    campos: tuple[str, ...]
    evaluar: Callable[[dict], Resultado | None]  # None: faltan datos para evaluarla
    ambito: str = "fila"  # «fila» o «encabezado»


@dataclass(frozen=True)
class RelacionEntreFilas:
    """Regla que compara un mismo campo entre filas (por ejemplo, profundidades)."""

    nombre: str
    campo: str
    evaluar: Callable[[list[tuple[int, Decimal]]], list[tuple[int, str]]]
    ambito: str = "hoja"


def _todos(valores, campos):
    return all(valores.get(c) is not None for c in campos)


# Valor que indica rechazo en el SPT. El criterio exacto de la empresa está pendiente
# de confirmar (ver preguntas para el encargado del área).
GOLPES_RECHAZO = 50


def _n_spt(valores):
    if not _todos(valores, ("golpes_2", "golpes_3", "n_spt")):
        return None
    golpes = [valores.get(c) for c in ("golpes_1", "golpes_2", "golpes_3") if valores.get(c) is not None]
    if any(g >= GOLPES_RECHAZO for g in golpes):
        return None  # Con rechazo, N no es la suma: se revisa con el criterio de la empresa.
    suma = valores["golpes_2"] + valores["golpes_3"]
    if valores["n_spt"] == suma:
        return Resultado(True, "")
    return Resultado(False, f"N = {valores['n_spt']}, pero tramo 2 + tramo 3 = {suma}.")


def _suma_100(valores):
    campos = ("pct_grava", "pct_arena", "pct_finos")
    if not _todos(valores, campos):
        return None
    suma = sum(valores[c] for c in campos)
    if suma == 100:
        return Resultado(True, "")
    return Resultado(False, f"Grava + arena + finos = {suma} %, no 100 %.")


def _ip(valores):
    if not _todos(valores, ("ll", "lp", "ip")):
        return None
    esperado = valores["ll"] - valores["lp"]
    if valores["ip"] == esperado:
        return Resultado(True, "")
    return Resultado(
        False,
        f"IP = {valores['ip']}, pero LL − LP = {esperado}. Si la diferencia es de 1, "
        "puede venir de redondear LL y LP antes de restar (criterio por confirmar).",
    )


def _profundidad_creciente(filas):
    avisos = []
    for (fila_ant, prof_ant), (fila, prof) in zip(filas, filas[1:]):
        if prof <= prof_ant:
            avisos.append((fila, f"La profundidad {prof} m no es mayor que la de la fila anterior ({prof_ant} m)."))
    return avisos


N_IGUAL_TRAMO2_MAS_TRAMO3 = Relacion("n_spt", ("golpes_2", "golpes_3", "n_spt"), _n_spt)
PORCENTAJES_SUMAN_100 = Relacion("porcentajes_100", ("pct_grava", "pct_arena", "pct_finos"), _suma_100)
IP_IGUAL_LL_MENOS_LP = Relacion("ip", ("ll", "lp", "ip"), _ip, ambito="encabezado")
PROFUNDIDAD_CRECIENTE = RelacionEntreFilas("profundidad_creciente", "profundidad", _profundidad_creciente)
