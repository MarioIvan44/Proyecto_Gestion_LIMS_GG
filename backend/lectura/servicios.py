"""
Flujo de una hoja: subir la foto → leerla → revisar celda por celda → cerrar.

Al cerrar se aprende de las correcciones (ver `aprendizaje.py`). Nada pasa a
«revisada» sin que una persona haya confirmado o corregido cada celda.
"""

import hashlib
import logging
from decimal import Decimal

from django.conf import settings
from django.core.files.base import ContentFile
from django.db import IntegrityError, transaction
from django.utils import timezone

from . import aprendizaje
from .models import CampoLeido, HojaEscaneada
from .motor import numeros
from .motor.plantillas import DECIMAL, ENCABEZADO, ENTERO, OPCION, PLANTILLAS
from .motor.propuestas import MANUAL, clave_opcion, evaluar_reglas, proponer_hoja
from .motor.proveedores import ErrorDeLectura, obtener_proveedor
from .motor.vocabularios import VOCABULARIOS

log = logging.getLogger(__name__)


class ErrorDeFlujo(Exception):
    estado_http = 400

    def __init__(self, mensaje, datos=None):
        super().__init__(mensaje)
        self.mensaje = mensaje
        self.datos = datos or {}


class DatosInvalidos(ErrorDeFlujo):
    estado_http = 400


class EstadoInvalido(ErrorDeFlujo):
    estado_http = 409


class HojaDuplicada(ErrorDeFlujo):
    estado_http = 409


# ---------------------------------------------------------------------------
# Subir y leer
# ---------------------------------------------------------------------------

_HEIC = {b"heic", b"heix", b"hevc", b"mif1", b"msf1"}


def detectar_tipo(datos: bytes) -> tuple[str, str]:
    """Tipo real del archivo por sus primeros bytes (no por la extensión)."""
    if datos.startswith(b"\xff\xd8\xff"):
        return "image/jpeg", "jpg"
    if datos.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png", "png"
    if datos[4:8] == b"ftyp" and datos[8:12] in _HEIC:
        return "image/heic", "heic"
    if datos.startswith(b"%PDF-"):
        return "application/pdf", "pdf"
    raise DatosInvalidos("El archivo no es una foto JPEG, PNG o HEIC ni un PDF.")


def registrar_hoja(datos: bytes, tipo: str, usuario, *, proyecto=None, folio=None, llenada_por=None,
                   conjunto=HojaEscaneada.Conjunto.ENTRENAMIENTO, leer=True) -> HojaEscaneada:
    if tipo not in PLANTILLAS:
        raise DatosInvalidos(f"Tipo de hoja desconocido: «{tipo}».", {"tipos": list(PLANTILLAS)})
    if conjunto not in HojaEscaneada.Conjunto.values:
        raise DatosInvalidos(f"Conjunto desconocido: «{conjunto}».")
    if not datos:
        raise DatosInvalidos("El archivo está vacío.")
    maximo = settings.LECTURA_TAMANO_MAXIMO_MB * 1024 * 1024
    if len(datos) > maximo:
        raise DatosInvalidos(f"La foto pesa más de {settings.LECTURA_TAMANO_MAXIMO_MB} MB.")
    tipo_contenido, extension = detectar_tipo(datos)

    huella = hashlib.sha256(datos).hexdigest()
    existente = HojaEscaneada.objects.filter(imagen_sha256=huella).first()
    if existente:
        raise HojaDuplicada("Esta foto ya se subió.", {"hoja": str(existente.id)})

    hoja = HojaEscaneada(
        tipo=tipo, conjunto=conjunto, proyecto=proyecto, folio=folio or None, llenada_por=llenada_por,
        subida_por=usuario, imagen_sha256=huella, imagen_tipo=tipo_contenido,
    )
    hoja.imagen.save(f"hoja.{extension}", ContentFile(datos), save=False)
    try:
        hoja.save()
    except IntegrityError:
        hoja.imagen.delete(save=False)
        raise HojaDuplicada("Esta foto ya se subió.")
    except Exception:
        hoja.imagen.delete(save=False)
        raise
    if leer:
        leer_hoja(hoja, datos)
    return hoja


def _decimal_confianza(valor):
    return None if valor is None else Decimal(str(round(valor, 3)))


def leer_hoja(hoja: HojaEscaneada, datos: bytes | None = None) -> HojaEscaneada:
    """Pide la lectura al servicio y guarda una propuesta por celda."""
    if hoja.estado == HojaEscaneada.Estado.REVISADA:
        raise EstadoInvalido("La hoja ya está revisada.")
    if hoja.campos.exclude(estado=CampoLeido.Estado.PENDIENTE).exists():
        raise EstadoInvalido("La hoja ya tiene celdas revisadas; volver a leerla borraría esa revisión.")
    if datos is None:
        with hoja.imagen.open("rb") as f:
            datos = f.read()

    plantilla = hoja.plantilla
    try:
        proveedor = obtener_proveedor(settings.LECTURA_PROVEEDOR, {"simulado_dir": settings.LECTURA_SIMULADO_DIR})
        resultado = proveedor.leer(datos, hoja.imagen_tipo, plantilla, aprendizaje.pistas(hoja.tipo))
    except ErrorDeLectura as e:
        hoja.estado, hoja.error = HojaEscaneada.Estado.ERROR, str(e)
        hoja.save(update_fields=["estado", "error"])
        return hoja
    except Exception as e:  # errores de red o del servicio: la hoja queda para reintentar
        log.exception("Error del servicio de lectura con la hoja %s", hoja.id)
        hoja.estado, hoja.error = HojaEscaneada.Estado.ERROR, f"Error del servicio de lectura: {type(e).__name__}"
        hoja.save(update_fields=["estado", "error"])
        return hoja

    conocimiento = aprendizaje.cargar_conocimiento(hoja.llenada_por)
    r = proponer_hoja(plantilla, resultado.celdas, conocimiento, settings.LECTURA_UMBRAL_CONFIANZA)

    with transaction.atomic():
        hoja.campos.all().delete()
        CampoLeido.objects.bulk_create([
            CampoLeido(
                hoja=hoja, fila=c.fila, campo=c.campo, texto_leido=c.texto,
                confianza=_decimal_confianza(c.confianza), caja=c.caja,
                valor_propuesto=c.propuesta.valor, origen_propuesta=c.propuesta.origen,
                detalle_propuesta=c.propuesta.detalle, requiere_revision=c.requiere_revision,
                motivos_revision=c.motivos,
            )
            for c in r.celdas
        ])
        hoja.estado = HojaEscaneada.Estado.EN_REVISION
        hoja.error = None
        hoja.proveedor = proveedor.nombre
        hoja.version_plantilla = plantilla.version
        hoja.respuesta_proveedor = resultado.respuesta_cruda
        hoja.datos_extra = {**hoja.datos_extra, "celdas_descartadas": r.campos_desconocidos}
        hoja.save()
    return hoja


# ---------------------------------------------------------------------------
# Revisión
# ---------------------------------------------------------------------------


def valores_actuales(hoja: HojaEscaneada) -> dict[int, dict[str, str | None]]:
    """Valor de cada celda: el final si ya se revisó, si no la propuesta."""
    valores: dict[int, dict] = {}
    for c in hoja.campos.all():
        valor = c.valor_propuesto if c.estado == CampoLeido.Estado.PENDIENTE else c.valor_final
        valores.setdefault(c.fila, {})[c.campo] = valor
    return valores


def advertencias_actuales(hoja: HojaEscaneada) -> list[dict]:
    return [a.a_dict() for a in evaluar_reglas(hoja.plantilla, valores_actuales(hoja))]


def _validar_cambio(plantilla, cambio: dict, posicion: int) -> tuple[dict | None, str | None]:
    """Devuelve (cambio normalizado, error)."""
    try:
        fila = int(cambio.get("fila"))
    except (TypeError, ValueError):
        return None, f"[{posicion}] «fila» debe ser un número."
    nombre = cambio.get("campo")
    campo = plantilla.campo(nombre) if isinstance(nombre, str) else None
    if campo is None:
        return None, f"[{posicion}] El campo «{nombre}» no existe en la hoja."
    if fila < 0 or (campo.ubicacion == ENCABEZADO) != (fila == 0):
        return None, f"[{posicion}] «{nombre}» va en la fila {'0 (encabezado)' if campo.ubicacion == ENCABEZADO else '1 o mayor'}."

    ilegible = bool(cambio.get("ilegible"))
    motivo = (cambio.get("motivo") or "").strip() or None
    valor = cambio.get("valor_final")
    valor = None if valor is None or str(valor).strip() == "" else str(valor).strip()

    if ilegible:
        valor = None
    elif valor is not None and campo.tipo in (ENTERO, DECIMAL):
        limpio, _ = numeros.limpiar(valor)
        if not numeros.es_numero(limpio, campo.tipo == ENTERO):
            tipo = "un número entero" if campo.tipo == ENTERO else "un número"
            return None, f"[{posicion}] «{campo.etiqueta}» debe ser {tipo} (se recibió «{valor}»)."
        valor = limpio
    elif valor is not None and campo.tipo == OPCION:
        lista = VOCABULARIOS[campo.vocabulario]
        canonico = next((v for v in lista if clave_opcion(v) == clave_opcion(valor)), None)
        if canonico:
            valor = canonico
        elif not motivo:
            return None, (
                f"[{posicion}] «{valor}» no está en la lista de «{campo.etiqueta}». "
                "Si la hoja dice eso, escribe el motivo."
            )
    return {"fila": fila, "campo": nombre, "valor": valor, "ilegible": ilegible, "motivo": motivo}, None


@transaction.atomic
def guardar_revision(hoja: HojaEscaneada, cambios: list, usuario) -> HojaEscaneada:
    """
    Cada cambio: {"fila", "campo", "valor_final", "ilegible"?, "motivo"?}.
    Se valida todo antes de guardar nada.
    """
    if hoja.estado != HojaEscaneada.Estado.EN_REVISION:
        raise EstadoInvalido("Solo se pueden revisar hojas en revisión.", {"estado": hoja.estado})
    if not isinstance(cambios, list) or not cambios:
        raise DatosInvalidos("Envía una lista de cambios.")

    normalizados, errores = [], []
    for i, cambio in enumerate(cambios):
        n, error = _validar_cambio(hoja.plantilla, cambio if isinstance(cambio, dict) else {}, i)
        errores.append(error) if error else normalizados.append(n)
    if errores:
        raise DatosInvalidos("Hay cambios con errores; no se guardó nada.", {"errores": errores})

    ahora = timezone.now()
    for n in normalizados:
        celda, _ = CampoLeido.objects.select_for_update().get_or_create(
            hoja=hoja, fila=n["fila"], campo=n["campo"],
            defaults={"origen_propuesta": MANUAL, "requiere_revision": True, "motivos_revision": ["capturado a mano"]},
        )
        if n["ilegible"]:
            celda.estado = CampoLeido.Estado.ILEGIBLE
        elif n["valor"] == celda.valor_propuesto:
            celda.estado = CampoLeido.Estado.CONFIRMADO
        else:
            celda.estado = CampoLeido.Estado.CORREGIDO
        celda.valor_final = n["valor"]
        celda.motivo = n["motivo"]
        celda.revisado_por = usuario
        celda.revisado_en = ahora
        celda.save()
    return hoja


@transaction.atomic
def confirmar_sin_observaciones(hoja: HojaEscaneada, usuario) -> int:
    """
    Confirma de una vez las celdas pendientes que NO están marcadas para revisión.
    Lo pide el revisor con un botón; el sistema no lo hace por su cuenta.
    """
    if hoja.estado != HojaEscaneada.Estado.EN_REVISION:
        raise EstadoInvalido("Solo se pueden revisar hojas en revisión.", {"estado": hoja.estado})
    celdas = hoja.campos.select_for_update().filter(estado=CampoLeido.Estado.PENDIENTE, requiere_revision=False)
    ahora, total = timezone.now(), 0
    for c in celdas:
        c.valor_final, c.estado = c.valor_propuesto, CampoLeido.Estado.CONFIRMADO
        c.revisado_por, c.revisado_en = usuario, ahora
        c.save(update_fields=["valor_final", "estado", "revisado_por", "revisado_en"])
        total += 1
    return total


@transaction.atomic
def cerrar_revision(hoja: HojaEscaneada, usuario, aceptar_advertencias=False) -> HojaEscaneada:
    hoja = HojaEscaneada.objects.select_for_update().get(pk=hoja.pk)
    if hoja.estado != HojaEscaneada.Estado.EN_REVISION:
        raise EstadoInvalido("Solo se pueden cerrar hojas en revisión.", {"estado": hoja.estado})
    pendientes = list(hoja.campos.filter(estado=CampoLeido.Estado.PENDIENTE).values("fila", "campo"))
    if pendientes:
        raise EstadoInvalido("Quedan celdas sin revisar.", {"pendientes": pendientes})
    advertencias = advertencias_actuales(hoja)
    if advertencias and not aceptar_advertencias:
        raise EstadoInvalido(
            "La hoja tiene advertencias. Corrígelas o ciérrala indicando que las aceptas.",
            {"advertencias": advertencias},
        )
    hoja.estado = HojaEscaneada.Estado.REVISADA
    hoja.revisada_por, hoja.revisada_en = usuario, timezone.now()
    hoja.datos_extra = {**hoja.datos_extra, "advertencias_aceptadas": advertencias}
    hoja.save()
    aprendizaje.aprender_de_hoja(hoja)
    return hoja


@transaction.atomic
def reabrir_revision(hoja: HojaEscaneada, usuario) -> HojaEscaneada:
    if hoja.estado != HojaEscaneada.Estado.REVISADA:
        raise EstadoInvalido("Solo se pueden reabrir hojas revisadas.", {"estado": hoja.estado})
    hoja.estado = HojaEscaneada.Estado.EN_REVISION
    reaperturas = hoja.datos_extra.get("reaperturas", [])
    hoja.datos_extra = {**hoja.datos_extra, "reaperturas": [*reaperturas, {
        "por": str(usuario.pk) if usuario else None, "en": timezone.now().isoformat(),
    }]}
    hoja.save()
    return hoja
