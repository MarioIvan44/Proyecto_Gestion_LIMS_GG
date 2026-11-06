"""
Qué caracteres se confunden al leer la letra de la hoja.

La tabla se aprende de las revisiones: cada vez que el revisor corrige «1» por
«7» en un número, se suma un caso (numero, «1», «7»). También se cuentan los
aciertos (numero, «7», «7»), así la probabilidad es la proporción real:
p(real = 7 | se leyó 1) = veces(1→7) / veces(1→cualquiera).
"""

from collections import defaultdict
from dataclasses import dataclass, field

NUMERO = "numero"
TEXTO = "texto"

# SUPUESTO: confusiones típicas de letra por número, para tener algo antes de que
# haya revisiones. Solo se usan en campos numéricos, solo para caracteres que no
# son dígitos y solo si todavía no hay nada aprendido para ese carácter. Revisar
# con las primeras hojas reales y quitar las que no aparezcan.
CONFUSIONES_INICIALES_NUMERO = {
    "O": "0", "D": "0", "Q": "0",
    "I": "1", "L": "1", "|": "1",
    "Z": "2", "S": "5", "B": "8", "G": "6",
}

# Por debajo de esta probabilidad un cambio no se propone como candidato.
PROBABILIDAD_MINIMA_CANDIDATO = 0.10


@dataclass
class TablaConfusiones:
    # (tipo, leído, real) -> veces
    conteos: dict = field(default_factory=lambda: defaultdict(int))

    def sumar(self, tipo: str, leido: str, real: str, veces: int = 1):
        self.conteos[(tipo, leido, real)] += veces

    def total_desde(self, tipo: str, leido: str) -> int:
        return sum(n for (t, a, _), n in self.conteos.items() if t == tipo and a == leido)

    def probabilidad(self, tipo: str, leido: str, real: str) -> float:
        total = self.total_desde(tipo, leido)
        if total == 0:
            return 0.0
        return self.conteos.get((tipo, leido, real), 0) / total

    def costo(self, tipo: str):
        """Función de costo de sustitución para `texto.distancia`."""
        def _costo(x, y):
            if x == y:
                return 0.0
            # Un cambio frecuente cuesta poco, pero nunca 0: sigue siendo un cambio.
            return 1.0 - min(0.8, self.probabilidad(tipo, x, y))
        return _costo

    def alternativas(self, tipo: str, leido: str) -> list[tuple[str, float, str]]:
        """
        Caracteres que podrían ser en realidad `leido`, de más a menos probable.
        Cada elemento es (carácter, probabilidad, origen) con origen «aprendido» o «inicial».
        """
        if self.total_desde(tipo, leido) > 0:
            opciones = [
                (real, self.probabilidad(tipo, leido, real), "aprendido")
                for (t, a, real) in list(self.conteos)
                if t == tipo and a == leido and real != leido
            ]
            return sorted(
                (o for o in opciones if o[1] >= PROBABILIDAD_MINIMA_CANDIDATO),
                key=lambda o: -o[1],
            )
        if tipo == NUMERO and not leido.isdigit():
            inicial = CONFUSIONES_INICIALES_NUMERO.get(leido.upper())
            if inicial:
                return [(inicial, 0.5, "inicial")]
        return []
