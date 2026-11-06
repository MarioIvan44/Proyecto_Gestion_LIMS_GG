"""
Aprendizaje a partir de las hojas revisadas.

Esto NO entrena un modelo de reconocimiento de letra: eso lo hace el servicio de
lectura. Aquí se aprende lo que el servicio no sabe de este laboratorio:

1. Sinónimos: texto leído → valor que puso el revisor («HINO» → «LIMO»,
   «5M» → «SM», abreviaturas propias del laboratorio).
2. Confusiones de caracteres: qué se lee mal y qué era en realidad, en general y
   por técnico que llenó la hoja (cada letra se confunde distinto).

Se aprende una sola vez por hoja, al cerrar su revisión, y nunca de hojas del
conjunto «prueba». Las tablas se pueden reconstruir desde cero con
`python manage.py reentrenar_lectura`, porque todo sale de las revisiones guardadas.
"""

from django.db import transaction
from django.db.models import F
from django.utils import timezone

from .models import CampoLeido, ConfusionCaracter, HojaEscaneada, Sinonimo
from .motor import confusiones as conf
from .motor.plantillas import DECIMAL, ENTERO, OPCION, PLANTILLAS, TEXTO
from .motor.propuestas import SINONIMO, Conocimiento, clave_opcion
from .motor.texto import clave, pares_de_caracteres, pares_de_palabras
from .motor.vocabularios import PALABRAS, VOCABULARIOS

ESTADOS_APRENDIBLES = (CampoLeido.Estado.CONFIRMADO, CampoLeido.Estado.CORREGIDO)

# Cuántos sinónimos se pasan como pistas al servicio de lectura.
MAXIMO_PISTAS = 50


def cargar_conocimiento(escritor=None) -> Conocimiento:
    """
    Lo aprendido hasta ahora. Si se indica el técnico que llenó la hoja, sus
    confusiones se suman a las generales (así pesan el doble).
    """
    con = Conocimiento()
    for s in Sinonimo.objects.all().only("vocabulario", "clave", "valor", "confirmaciones", "rechazos"):
        con.agregar_sinonimo(s.vocabulario, s.clave, s.valor, s.confirmaciones, s.rechazos)
    filas = ConfusionCaracter.objects.filter(escritor__isnull=True)
    if escritor is not None:
        filas = filas | ConfusionCaracter.objects.filter(escritor=escritor)
    for c in filas:
        con.confusiones.sumar(c.tipo_campo, c.leido, c.real, c.veces)
    return con


def pistas(tipo_hoja: str) -> dict:
    """Vocabularios y sinónimos frecuentes, para servicios que aceptan contexto."""
    plantilla = PLANTILLAS[tipo_hoja]
    vocabularios = {c.vocabulario for c in plantilla.campos if c.vocabulario} | {PALABRAS}
    sinonimos = (
        Sinonimo.objects.filter(vocabulario__in=vocabularios, confirmaciones__gt=F("rechazos"))
        .order_by("-confirmaciones")[:MAXIMO_PISTAS]
    )
    return {
        "vocabularios": {v: list(VOCABULARIOS[v]) for v in vocabularios if v in VOCABULARIOS},
        "sinonimos": [{"vocabulario": s.vocabulario, "texto": s.clave, "valor": s.valor} for s in sinonimos],
    }


def _sumar_sinonimo(vocabulario, clave_leida, valor, confirmacion=True):
    fila, _ = Sinonimo.objects.get_or_create(vocabulario=vocabulario, clave=clave_leida[:200], valor=valor[:200])
    campo = "confirmaciones" if confirmacion else "rechazos"
    Sinonimo.objects.filter(pk=fila.pk).update(**{campo: F(campo) + 1, "actualizado_en": timezone.now()})


def _sumar_confusiones(tipo_campo, escritor, pares):
    for leido, real in pares:
        for quien in {None, escritor}:
            fila, _ = ConfusionCaracter.objects.get_or_create(
                tipo_campo=tipo_campo, escritor=quien, leido=leido, real=real,
            )
            ConfusionCaracter.objects.filter(pk=fila.pk).update(veces=F("veces") + 1)


def _aprender_campo(c: CampoLeido, plantilla, escritor):
    campo = plantilla.campo(c.campo)
    if campo is None or not c.texto_leido or c.valor_final is None:
        return
    leido, final = c.texto_leido, c.valor_final

    # Si se había propuesto un sinónimo y el revisor puso otra cosa, ese sinónimo pierde apoyo.
    if c.origen_propuesta == SINONIMO and c.valor_propuesto is not None and c.valor_propuesto != final:
        if campo.tipo == OPCION:
            _sumar_sinonimo(campo.vocabulario, clave_opcion(leido), c.valor_propuesto, confirmacion=False)
        elif campo.tipo == TEXTO:
            for r in c.detalle_propuesta.get("reemplazos", []):
                if clave(r["propuesto"]) not in clave(final):
                    _sumar_sinonimo(PALABRAS, clave(r["leido"]), r["propuesto"], confirmacion=False)

    if campo.tipo == OPCION:
        # Solo se aprenden valores de la lista cerrada; lo demás es una decisión puntual del revisor.
        if final in VOCABULARIOS[campo.vocabulario] and clave_opcion(leido) != clave_opcion(final):
            _sumar_sinonimo(campo.vocabulario, clave_opcion(leido), final)
        _sumar_confusiones(conf.TEXTO, escritor, pares_de_caracteres(clave_opcion(leido), clave_opcion(final)))
    elif campo.tipo in (ENTERO, DECIMAL):
        _sumar_confusiones(conf.NUMERO, escritor, pares_de_caracteres(leido.strip().upper(), final.strip()))
    else:
        for clave_leida, real in pares_de_palabras(leido, final):
            _sumar_sinonimo(PALABRAS, clave_leida, real)
        _sumar_confusiones(conf.TEXTO, escritor, pares_de_caracteres(clave(leido), clave(final)))


def _aprender(hoja: HojaEscaneada):
    plantilla = hoja.plantilla
    escritor = hoja.llenada_por
    for c in hoja.campos.filter(estado__in=ESTADOS_APRENDIBLES):
        _aprender_campo(c, plantilla, escritor)
    HojaEscaneada.objects.filter(pk=hoja.pk).update(aprendida_en=timezone.now())


@transaction.atomic
def aprender_de_hoja(hoja: HojaEscaneada) -> bool:
    """Se llama al cerrar la revisión. Devuelve si se aprendió algo."""
    if hoja.conjunto != HojaEscaneada.Conjunto.ENTRENAMIENTO or hoja.estado != HojaEscaneada.Estado.REVISADA:
        return False
    if hoja.aprendida_en is not None:
        # Ya se había aprendido de ella (se reabrió y se volvió a cerrar): rehacer
        # todo para no contar dos veces las mismas correcciones.
        reconstruir()
        return True
    _aprender(hoja)
    return True


@transaction.atomic
def reconstruir() -> dict:
    """Borra lo aprendido y lo vuelve a calcular desde todas las hojas revisadas."""
    Sinonimo.objects.filter(origen=Sinonimo.Origen.APRENDIDO).delete()
    ConfusionCaracter.objects.all().delete()
    hojas = HojaEscaneada.objects.filter(
        estado=HojaEscaneada.Estado.REVISADA, conjunto=HojaEscaneada.Conjunto.ENTRENAMIENTO,
    ).select_related("llenada_por").order_by("revisada_en")
    total = 0
    for hoja in hojas:
        _aprender(hoja)
        total += 1
    return {
        "hojas": total,
        "sinonimos": Sinonimo.objects.count(),
        "confusiones": ConfusionCaracter.objects.filter(escritor__isnull=True).exclude(leido=F("real")).count(),
    }
