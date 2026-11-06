"""
Conversión de valores de MongoDB a tipos de PostgreSQL.

Regla general: un valor solo se convierte si la conversión es exacta (por ejemplo
el texto "45.50" a número). Si para migrarlo habría que adivinar o inventar algo,
se lanza `Rechazo` y el documento queda en el informe con el motivo. Los cambios
que sí se hacen (texto vacío a NULL, redondeos, fechas con hora) también quedan
registrados en el informe: nada se corrige en silencio.
"""

import math
import re
from dataclasses import dataclass, field
from datetime import date, datetime, time, timezone
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

from bson import Decimal128, ObjectId

CUATRO_DECIMALES = Decimal("0.0001")
RUIDO_FLOTANTE = Decimal("0.000000001")
LIMITE_MONTO = Decimal("10000000000")  # NUMERIC(14,4): hasta 10 dígitos enteros
NUMERO_TEXTO = re.compile(r"^-?\d+(\.\d+)?$")
HORA_TEXTO = re.compile(r"^([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?$")
FECHA_TEXTO = re.compile(r"^\d{4}-\d{2}-\d{2}$")
BCRYPT = re.compile(r"^\$2[abxy]?\$\d{2}\$[./A-Za-z0-9]{53}$")


class Rechazo(Exception):
    """El valor no se puede migrar sin adivinar ni inventar datos."""

    def __init__(self, campo, motivo):
        super().__init__(f"{campo}: {motivo}")
        self.campo = campo
        self.motivo = motivo


@dataclass
class Contexto:
    """
    Lo que se va observando al convertir un documento. Se guarda aparte y solo
    pasa al informe si el documento se migra (si se rechaza, cuenta el motivo
    del rechazo y no sus advertencias).
    """

    coleccion: str
    mongo_id: str
    advertencias: list = field(default_factory=list)
    conteos: list = field(default_factory=list)

    def advertir(self, campo, mensaje):
        self.advertencias.append((campo, mensaje))

    def contar(self, tipo, campo):
        self.conteos.append((tipo, campo))


def _vacio(valor):
    return valor is None


# ---------------------------------------------------------------------------
# Convertidores. Cada uno recibe (valor, ctx, campo) y devuelve el valor para
# PostgreSQL o lanza Rechazo.
# ---------------------------------------------------------------------------


def texto(max_largo=None, vacio_a_null=False):
    """
    Texto. Un "" se conserva tal cual (la API lo devuelve así hoy), salvo en
    campos únicos (`vacio_a_null=True`): ahí pasa a NULL, porque dos "" chocarían
    entre sí y NULL significa «sin valor».
    """

    def convertir(valor, ctx, campo):
        if _vacio(valor):
            return None
        if isinstance(valor, bool):
            raise Rechazo(campo, f"se esperaba texto y vino un booleano ({valor})")
        if isinstance(valor, int) or (isinstance(valor, float) and valor.is_integer()):
            ctx.contar("número guardado como texto", campo)
            valor = str(int(valor))
        elif isinstance(valor, ObjectId):
            valor = str(valor)
        elif not isinstance(valor, str):
            raise Rechazo(campo, f"se esperaba texto y vino {type(valor).__name__}")
        if valor == "" and vacio_a_null:
            ctx.contar("texto vacío a NULL (campo único)", campo)
            return None
        if max_largo is not None and len(valor) > max_largo:
            raise Rechazo(campo, f"tiene {len(valor)} caracteres y el máximo es {max_largo}")
        return valor

    return convertir


def decimal():
    def convertir(valor, ctx, campo):
        if _vacio(valor):
            return None
        if isinstance(valor, bool):
            raise Rechazo(campo, f"se esperaba un número y vino un booleano ({valor})")
        if isinstance(valor, Decimal128):
            numero = valor.to_decimal()
        elif isinstance(valor, int):
            numero = Decimal(valor)
        elif isinstance(valor, float):
            if math.isnan(valor) or math.isinf(valor):
                raise Rechazo(campo, f"valor no numérico ({valor})")
            numero = Decimal(repr(valor))
        elif isinstance(valor, str):
            if not NUMERO_TEXTO.match(valor):
                raise Rechazo(campo, f"el texto '{valor}' no es un número")
            numero = Decimal(valor)
            ctx.contar("número guardado como texto", campo)
        else:
            raise Rechazo(campo, f"se esperaba un número y vino {type(valor).__name__}")
        try:
            redondeado = numero.quantize(CUATRO_DECIMALES, rounding=ROUND_HALF_UP)
        except InvalidOperation:
            raise Rechazo(campo, f"número fuera de rango ({numero})")
        if redondeado != numero:
            if abs(redondeado - numero) < RUIDO_FLOTANTE:
                ctx.contar("ruido de punto flotante quitado", campo)
            else:
                ctx.advertir(campo, f"tenía más de 4 decimales: {numero} se guardó como {redondeado}")
        if abs(redondeado) >= LIMITE_MONTO:
            raise Rechazo(campo, f"número demasiado grande ({numero})")
        return redondeado

    return convertir


def entero(minimo=None, maximo=None):
    def convertir(valor, ctx, campo):
        if _vacio(valor):
            return None
        if isinstance(valor, bool):
            raise Rechazo(campo, f"se esperaba un entero y vino un booleano ({valor})")
        if isinstance(valor, float) and valor.is_integer():
            valor = int(valor)
        elif isinstance(valor, str) and re.fullmatch(r"-?\d+", valor):
            ctx.contar("número guardado como texto", campo)
            valor = int(valor)
        if not isinstance(valor, int):
            raise Rechazo(campo, f"se esperaba un entero y vino {valor!r}")
        if (minimo is not None and valor < minimo) or (maximo is not None and valor > maximo):
            raise Rechazo(campo, f"valor fuera de rango ({valor})")
        return valor

    return convertir


def booleano():
    def convertir(valor, ctx, campo):
        if _vacio(valor):
            return None
        if isinstance(valor, bool):
            return valor
        if isinstance(valor, str) and valor.strip().lower() in {"true", "false"}:
            ctx.contar("booleano guardado como texto", campo)
            return valor.strip().lower() == "true"
        if isinstance(valor, int) and valor in (0, 1):
            ctx.contar("booleano guardado como 0/1", campo)
            return bool(valor)
        raise Rechazo(campo, f"se esperaba verdadero/falso y vino {valor!r}")

    return convertir


def _fecha_razonable(campo, momento):
    if not 1900 <= momento.year <= 2100:
        raise Rechazo(campo, f"fecha fuera de rango ({momento.isoformat()})")


def _parsear_iso(campo, texto_fecha):
    try:
        momento = datetime.fromisoformat(texto_fecha.replace("Z", "+00:00"))
    except ValueError:
        raise Rechazo(campo, f"fecha no reconocida: '{texto_fecha}'")
    if momento.tzinfo is None:
        momento = momento.replace(tzinfo=timezone.utc)
    return momento.astimezone(timezone.utc)


def _a_utc(valor):
    return valor.replace(tzinfo=timezone.utc) if valor.tzinfo is None else valor.astimezone(timezone.utc)


def fecha_dia():
    """Fechas «de día»: la aplicación las guarda como medianoche UTC."""

    def convertir(valor, ctx, campo):
        if _vacio(valor):
            return None
        if isinstance(valor, str):
            if FECHA_TEXTO.match(valor):
                ctx.contar("fecha guardada como texto", campo)
                try:
                    return date.fromisoformat(valor)
                except ValueError:
                    raise Rechazo(campo, f"fecha inexistente: '{valor}'")
            momento = _parsear_iso(campo, valor)
            ctx.contar("fecha guardada como texto", campo)
        elif isinstance(valor, datetime):
            momento = _a_utc(valor)
        else:
            raise Rechazo(campo, f"se esperaba una fecha y vino {valor!r}")
        _fecha_razonable(campo, momento)
        if momento.timetz().replace(tzinfo=None) != time(0, 0):
            ctx.advertir(campo, f"tenía hora ({momento.isoformat()}); se guardó el día UTC {momento.date().isoformat()}")
        return momento.date()

    return convertir


def fecha_hora():
    def convertir(valor, ctx, campo):
        if _vacio(valor):
            return None
        if isinstance(valor, str):
            momento = _parsear_iso(campo, valor)
            ctx.contar("fecha guardada como texto", campo)
        elif isinstance(valor, datetime):
            momento = _a_utc(valor)
        elif isinstance(valor, (int, float)) and not isinstance(valor, bool):
            # Date.now() guardado como número (milisegundos desde 1970).
            momento = datetime.fromtimestamp(valor / 1000, tz=timezone.utc)
            ctx.contar("fecha guardada como milisegundos", campo)
        else:
            raise Rechazo(campo, f"se esperaba fecha y hora y vino {valor!r}")
        _fecha_razonable(campo, momento)
        return momento

    return convertir


def fecha_texto():
    """Fechas que la aplicación guarda como texto «AAAA-MM-DD» (cuentas por cobrar)."""

    def convertir(valor, ctx, campo):
        if _vacio(valor) or valor == "":
            return None
        if isinstance(valor, datetime):
            momento = _a_utc(valor)
            ctx.contar("fecha guardada como Date en vez de texto", campo)
        elif isinstance(valor, str):
            if FECHA_TEXTO.match(valor):
                try:
                    dia = date.fromisoformat(valor)
                except ValueError:
                    raise Rechazo(campo, f"fecha inexistente: '{valor}'")
                _fecha_razonable(campo, dia)
                return dia
            momento = _parsear_iso(campo, valor)
            ctx.contar("fecha con hora en texto", campo)
        else:
            raise Rechazo(campo, f"se esperaba una fecha y vino {valor!r}")
        _fecha_razonable(campo, momento)
        if momento.timetz().replace(tzinfo=None) != time(0, 0):
            ctx.advertir(campo, f"tenía hora ({valor}); se guardó el día UTC {momento.date().isoformat()}")
        return momento.date()

    return convertir


def hora():
    def convertir(valor, ctx, campo):
        if _vacio(valor) or valor == "":
            return None
        if not isinstance(valor, str):
            raise Rechazo(campo, f"se esperaba una hora HH:MM y vino {valor!r}")
        coincide = HORA_TEXTO.match(valor)
        if not coincide:
            raise Rechazo(campo, f"la hora '{valor}' no tiene el formato HH:MM")
        return time(int(coincide.group(1)), int(coincide.group(2)), int(coincide.group(3) or 0))

    return convertir


def opcion(equivalencias):
    """Valor de una lista cerrada. `equivalencias` va del valor de MongoDB al de PostgreSQL."""

    def convertir(valor, ctx, campo):
        if _vacio(valor):
            return None
        if valor not in equivalencias:
            permitidos = ", ".join(f"'{v}'" for v in equivalencias)
            raise Rechazo(campo, f"el valor '{valor}' no está en la lista ({permitidos})")
        return equivalencias[valor]

    return convertir


def a_json(valor):
    """Convierte un valor de MongoDB a algo que se pueda guardar en jsonb (para datos_extra)."""
    if isinstance(valor, ObjectId):
        return str(valor)
    if isinstance(valor, datetime):
        # Mismo formato que Date.toISOString() de JavaScript (milisegundos y Z).
        momento = _a_utc(valor)
        return momento.strftime("%Y-%m-%dT%H:%M:%S.") + f"{momento.microsecond // 1000:03d}Z"
    if isinstance(valor, Decimal128):
        return str(valor.to_decimal())
    if isinstance(valor, Decimal):
        return str(valor)
    if isinstance(valor, bytes):
        return valor.hex()
    if isinstance(valor, dict):
        return {str(k): a_json(v) for k, v in valor.items()}
    if isinstance(valor, (list, tuple)):
        return [a_json(v) for v in valor]
    if isinstance(valor, float) and (math.isnan(valor) or math.isinf(valor)):
        return str(valor)
    return valor


def objectid_de(valor):
    """Devuelve el ObjectId de una referencia, aceptando también su texto de 24 caracteres."""
    if isinstance(valor, ObjectId):
        return valor, False
    if isinstance(valor, str) and ObjectId.is_valid(valor):
        return ObjectId(valor), True
    return None, False
