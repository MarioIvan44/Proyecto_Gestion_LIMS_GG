"""
Propuesta de valor para cada celda leída.

Orden en que se intenta, de más a menos seguro:
1. lectura      el texto leído ya es un valor válido.
2. formato      solo cambió la forma («12,5» → «12.5»).
3. sinonimo     el revisor ya corrigió antes ese mismo texto por ese valor.
4. parecido     el texto se parece a un único valor de la lista cerrada,
                teniendo en cuenta las letras que se confunden.
5. confusion    en un número había letras que suelen ser dígitos («1O» → «10»).
6. validacion   una regla de la hoja no se cumplía y un solo cambio la arregla.

Todo lo que no sea «lectura» queda marcado para revisión. «sin_propuesta»: el
sistema no se atreve a proponer nada y el revisor escribe el valor.
"""

import re
from collections import defaultdict
from dataclasses import dataclass, field
from decimal import Decimal

from . import numeros
from .confusiones import NUMERO, TEXTO as TEXTO_LIBRE, TablaConfusiones
from .plantillas import DECIMAL, ENCABEZADO, ENTERO, OPCION, TEXTO, Campo, Plantilla
from .texto import clave, distancia, palabras
from .validaciones import Relacion, RelacionEntreFilas
from .vocabularios import PALABRAS, VOCABULARIOS

LECTURA = "lectura"
FORMATO = "formato"
SINONIMO = "sinonimo"
PARECIDO = "parecido"
CONFUSION = "confusion"
VALIDACION = "validacion"
VACIO = "vacio"
SIN_PROPUESTA = "sin_propuesta"
MANUAL = "manual"  # celda que el servicio no leyó y escribió el revisor

ORIGENES = (LECTURA, FORMATO, SINONIMO, PARECIDO, CONFUSION, VALIDACION, VACIO, SIN_PROPUESTA, MANUAL)

# Para aceptar un «parecido», el segundo mejor valor debe quedar al menos así de lejos.
MARGEN_PARECIDO = 0.5


# ---------------------------------------------------------------------------
# Conocimiento aprendido
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Sinonimo:
    valor: str
    confirmaciones: int
    rechazos: int

    @property
    def confiabilidad(self) -> float:
        # Estimación de Laplace: con 1 confirmación y 0 rechazos da 0.67; con 9 y 0, 0.91.
        return (self.confirmaciones + 1) / (self.confirmaciones + self.rechazos + 2)


@dataclass
class Conocimiento:
    # (vocabulario, clave del texto leído) -> [Sinonimo, ...]
    sinonimos: dict = field(default_factory=lambda: defaultdict(list))
    confusiones: TablaConfusiones = field(default_factory=TablaConfusiones)

    def agregar_sinonimo(self, vocabulario, clave_leida, valor, confirmaciones=1, rechazos=0):
        self.sinonimos[(vocabulario, clave_leida)].append(Sinonimo(valor, confirmaciones, rechazos))

    def sinonimo(self, vocabulario: str, clave_leida: str) -> Sinonimo | None:
        """El valor que más veces se confirmó para ese texto; None si no hay o hay empate."""
        opciones = [s for s in self.sinonimos.get((vocabulario, clave_leida), []) if s.confirmaciones > s.rechazos]
        if not opciones:
            return None
        apoyo = lambda s: s.confirmaciones - s.rechazos  # noqa: E731
        mejor = max(opciones, key=apoyo)
        if sum(1 for s in opciones if apoyo(s) == apoyo(mejor)) > 1:
            return None
        return mejor


# ---------------------------------------------------------------------------
# Propuesta de una celda
# ---------------------------------------------------------------------------


@dataclass
class Propuesta:
    valor: str | None
    origen: str
    confiabilidad: float = 1.0  # multiplica la confianza del servicio de lectura
    detalle: dict = field(default_factory=dict)


def clave_opcion(texto: str) -> str:
    # «sp - sm» y «SP-SM» son la misma opción.
    return re.sub(r"\s*-\s*", "-", clave(texto)).replace(" ", "")


def _proponer_opcion(campo: Campo, texto: str, con: Conocimiento) -> Propuesta:
    lista = VOCABULARIOS[campo.vocabulario]
    k = clave_opcion(texto)
    for valor in lista:
        if k == clave_opcion(valor):
            return Propuesta(valor, LECTURA)

    s = con.sinonimo(campo.vocabulario, k)
    if s:
        return Propuesta(s.valor, SINONIMO, s.confiabilidad, {
            "confirmaciones": s.confirmaciones, "rechazos": s.rechazos,
        })

    costo = con.confusiones.costo(TEXTO_LIBRE)
    distancias = sorted((distancia(k, clave_opcion(v), costo), v) for v in lista)
    (d1, v1), (d2, v2) = distancias[0], distancias[1]
    if d1 <= 1.0 and d2 - d1 >= MARGEN_PARECIDO:
        return Propuesta(v1, PARECIDO, max(0.1, 1 - d1 / max(len(v1), 1)), {
            "distancia": round(d1, 3), "segundo": v2, "distancia_segundo": round(d2, 3),
        })
    return Propuesta(None, SIN_PROPUESTA, 0.0, {
        "mas_parecidos": [v for _, v in distancias[:3]],
    })


def _proponer_numero(campo: Campo, texto: str, con: Conocimiento) -> Propuesta:
    entero = campo.tipo == ENTERO
    limpio, cambio = numeros.limpiar(texto)
    if numeros.es_numero(limpio, entero):
        return Propuesta(limpio, FORMATO if cambio else LECTURA)

    cambios, confiabilidad, nuevo = [], 1.0, []
    for pos, c in enumerate(limpio):
        if c.isdigit() or (c == "." and not entero):
            nuevo.append(c)
            continue
        alternativas = [a for a in con.confusiones.alternativas(NUMERO, c) if a[0].isdigit()]
        if not alternativas:
            return Propuesta(None, SIN_PROPUESTA, 0.0)
        real, prob, origen = alternativas[0]
        nuevo.append(real)
        cambios.append({"posicion": pos, "leido": c, "propuesto": real, "origen": origen})
        confiabilidad *= prob
    candidato = "".join(nuevo)
    if numeros.es_numero(candidato, entero):
        return Propuesta(candidato, CONFUSION, confiabilidad, {"cambios": cambios})
    return Propuesta(None, SIN_PROPUESTA, 0.0)


def _proponer_texto(texto: str, con: Conocimiento) -> Propuesta:
    salida, reemplazos, confiabilidad = [], [], 1.0
    for p in palabras(texto):
        s = con.sinonimo(PALABRAS, clave(p))
        if s and clave(s.valor) != clave(p):
            salida.append(s.valor)
            reemplazos.append({"leido": p, "propuesto": s.valor, "confirmaciones": s.confirmaciones})
            confiabilidad = min(confiabilidad, s.confiabilidad)
        else:
            salida.append(p)
    valor = " ".join(salida)
    if reemplazos:
        return Propuesta(valor, SINONIMO, confiabilidad, {"reemplazos": reemplazos})
    return Propuesta(valor, LECTURA)


def proponer(campo: Campo, texto: str | None, con: Conocimiento) -> Propuesta:
    if texto is None or clave(texto) == "":
        return Propuesta(None, VACIO)
    if campo.tipo == OPCION:
        return _proponer_opcion(campo, texto, con)
    if campo.tipo in (ENTERO, DECIMAL):
        return _proponer_numero(campo, texto, con)
    return _proponer_texto(texto, con)


def candidatos_numericos(campo: Campo, valor: str, con: Conocimiento) -> list[tuple[str, float, dict]]:
    """
    Números a un solo carácter de distancia de `valor`, usando confusiones
    APRENDIDAS (por ejemplo «1» que en realidad era «7»). Sirve para intentar
    cumplir una regla de la hoja.
    """
    if campo.tipo not in (ENTERO, DECIMAL) or not valor:
        return []
    salida = []
    for pos, c in enumerate(valor):
        for real, prob, origen in con.confusiones.alternativas(NUMERO, c):
            if origen != "aprendido" or not real.isdigit():
                continue
            candidato = valor[:pos] + real + valor[pos + 1:]
            if numeros.es_numero(candidato, campo.tipo == ENTERO):
                salida.append((candidato, prob, {"posicion": pos, "leido": c, "propuesto": real}))
    return salida


# ---------------------------------------------------------------------------
# Hoja completa
# ---------------------------------------------------------------------------


@dataclass
class CeldaEntrada:
    fila: int
    campo: str
    texto: str | None
    confianza: float | None = None
    caja: dict | None = None


@dataclass
class ResultadoCelda:
    fila: int
    campo: str
    texto: str | None
    confianza: float | None
    caja: dict | None
    propuesta: Propuesta
    requiere_revision: bool = False
    motivos: list = field(default_factory=list)

    @property
    def confianza_final(self) -> float | None:
        if self.confianza is None:
            return None
        return round(self.confianza * self.propuesta.confiabilidad, 3)


@dataclass
class Advertencia:
    regla: str
    fila: int
    campos: tuple
    mensaje: str

    def a_dict(self):
        return {"regla": self.regla, "fila": self.fila, "campos": list(self.campos), "mensaje": self.mensaje}


@dataclass
class ResultadoHoja:
    celdas: list
    advertencias: list
    campos_desconocidos: list


def _filas_de(plantilla: Plantilla, relacion, valores_por_fila: dict) -> list[int]:
    if relacion.ambito == ENCABEZADO:
        return [0] if 0 in valores_por_fila else []
    return sorted(f for f in valores_por_fila if f > 0)


def evaluar_reglas(plantilla: Plantilla, valores_por_fila: dict[int, dict[str, str | None]]) -> list[Advertencia]:
    """
    Evalúa las reglas de la plantilla sobre los valores actuales (texto) de cada
    fila. Se usa al leer y cada vez que el revisor guarda cambios.
    """
    advertencias = []
    numericos = {
        fila: {c: numeros.a_decimal(v) for c, v in valores.items()}
        for fila, valores in valores_por_fila.items()
    }
    for relacion in plantilla.relaciones:
        if isinstance(relacion, RelacionEntreFilas):
            serie = [
                (f, numericos[f][relacion.campo]) for f in sorted(numericos)
                if f > 0 and numericos[f].get(relacion.campo) is not None
            ]
            for fila, mensaje in relacion.evaluar(serie):
                advertencias.append(Advertencia(relacion.nombre, fila, (relacion.campo,), mensaje))
            continue
        for fila in _filas_de(plantilla, relacion, numericos):
            r = relacion.evaluar(numericos[fila])
            if r is not None and not r.cumple:
                advertencias.append(Advertencia(relacion.nombre, fila, relacion.campos, r.mensaje))
    return advertencias


def _intentar_resolver(relacion: Relacion, fila: int, celdas: dict, plantilla: Plantilla, con: Conocimiento):
    """Devuelve (celda, candidato, prob, detalle) si exactamente un cambio cumple la regla."""
    actuales = {c: numeros.a_decimal(celdas[c].propuesta.valor) if c in celdas else None for c in relacion.campos}
    exitos = []
    for nombre in relacion.campos:
        celda = celdas.get(nombre)
        if celda is None or celda.propuesta.valor is None:
            continue
        for candidato, prob, detalle in candidatos_numericos(plantilla.campo(nombre), celda.propuesta.valor, con):
            prueba = dict(actuales, **{nombre: Decimal(candidato)})
            r = relacion.evaluar(prueba)
            if r is not None and r.cumple:
                exitos.append((celda, candidato, prob, detalle))
    return exitos[0] if len(exitos) == 1 else None


def proponer_hoja(
    plantilla: Plantilla, entradas: list[CeldaEntrada], con: Conocimiento, umbral_confianza: float,
) -> ResultadoHoja:
    celdas, desconocidos, vistos = [], [], set()
    for e in entradas:
        campo = plantilla.campo(e.campo)
        if campo is None or (campo.ubicacion == ENCABEZADO) != (e.fila == 0):
            desconocidos.append({"fila": e.fila, "campo": e.campo, "texto": e.texto, "motivo": "campo fuera de la plantilla"})
            continue
        if (e.fila, e.campo) in vistos:
            desconocidos.append({"fila": e.fila, "campo": e.campo, "texto": e.texto, "motivo": "celda repetida"})
            continue
        vistos.add((e.fila, e.campo))
        confianza = e.confianza
        if confianza is not None and not 0 <= confianza <= 1:
            confianza = None  # el servicio devolvió algo fuera de rango: se trata como «sin confianza»
        celdas.append(ResultadoCelda(e.fila, e.campo, e.texto, confianza, e.caja, proponer(campo, e.texto, con)))

    por_fila: dict[int, dict[str, ResultadoCelda]] = defaultdict(dict)
    for c in celdas:
        por_fila[c.fila][c.campo] = c

    # Reglas que no se cumplen: intentar un único cambio que las arregle.
    for relacion in plantilla.relaciones:
        if isinstance(relacion, RelacionEntreFilas):
            continue
        for fila in _filas_de(plantilla, relacion, por_fila):
            valores = {n: numeros.a_decimal(c.propuesta.valor) for n, c in por_fila[fila].items()}
            r = relacion.evaluar(valores)
            if r is None or r.cumple:
                continue
            arreglo = _intentar_resolver(relacion, fila, por_fila[fila], plantilla, con)
            if arreglo:
                celda, candidato, prob, detalle = arreglo
                celda.propuesta = Propuesta(candidato, VALIDACION, prob, {
                    "regla": relacion.nombre, "valor_antes": celda.propuesta.valor,
                    "mensaje_regla": r.mensaje, **detalle,
                })

    advertencias = evaluar_reglas(
        plantilla, {f: {n: c.propuesta.valor for n, c in cs.items()} for f, cs in por_fila.items()},
    )

    for c in celdas:
        if c.propuesta.origen not in (LECTURA, VACIO):
            c.motivos.append(f"propuesta por {c.propuesta.origen}")
        if c.confianza is None:
            c.motivos.append("el servicio no informó confianza")
        elif c.confianza_final < umbral_confianza:
            c.motivos.append(f"confianza {c.confianza_final} menor que {umbral_confianza}")
    for a in advertencias:
        for nombre in a.campos:
            celda = por_fila.get(a.fila, {}).get(nombre)
            if celda:
                celda.motivos.append(a.mensaje)
    for c in celdas:
        c.requiere_revision = bool(c.motivos)

    return ResultadoHoja(celdas, advertencias, desconocidos)
