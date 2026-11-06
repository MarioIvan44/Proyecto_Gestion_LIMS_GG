"""
API JSON de lectura de hojas, para la pantalla de revisión en React.

Usa la sesión de Django (cookie) y su protección CSRF: React debe mandar la
cabecera X-CSRFToken en cada POST/PATCH. Sin sesión, todo responde 401.

Rutas (prefijo /api/lectura/):
  GET   plantillas/                      campos de cada tipo de hoja
  GET   hojas/?estado=&tipo=             lista
  POST  hojas/                           subir foto (multipart: imagen, tipo, folio?, proyecto?, llenada_por?, conjunto?)
  GET   hojas/<id>/                      detalle con celdas y advertencias
  GET   hojas/<id>/imagen/               la foto (para mostrarla al lado)
  POST  hojas/<id>/leer/                 volver a leer (por ejemplo, después de un error)
  PATCH hojas/<id>/campos/               guardar revisión: {"cambios": [...]}
  POST  hojas/<id>/confirmar-sin-observaciones/
  POST  hojas/<id>/cerrar/               {"aceptar_advertencias": false}
  POST  hojas/<id>/reabrir/
  GET   aprendizaje/                     resumen de lo aprendido
"""

import json
from functools import wraps

from django.db.models import Count, F
from django.http import FileResponse, JsonResponse
from django.shortcuts import get_object_or_404
from django.views.decorators.http import require_GET, require_http_methods, require_POST

from nucleo.models import Empleado, Proyecto

from . import servicios
from .models import CampoLeido, ConfusionCaracter, HojaEscaneada, Sinonimo
from .motor.plantillas import PLANTILLAS
from .motor.vocabularios import VOCABULARIOS

MAXIMO_LISTA = 200


def _error(mensaje, estado, datos=None):
    return JsonResponse({"error": mensaje, **(datos or {})}, status=estado)


def requiere_sesion(vista):
    @wraps(vista)
    def envoltura(request, *args, **kwargs):
        if not request.user.is_authenticated:
            return _error("Inicia sesión.", 401)
        try:
            return vista(request, *args, **kwargs)
        except servicios.ErrorDeFlujo as e:
            return _error(e.mensaje, e.estado_http, e.datos)
    return envoltura


def _json(request):
    try:
        return json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        raise servicios.DatosInvalidos("El cuerpo no es JSON válido.")


def _hoja_resumen(h: HojaEscaneada):
    return {
        "id": str(h.id), "tipo": h.tipo, "tipo_nombre": h.get_tipo_display(), "estado": h.estado,
        "conjunto": h.conjunto, "folio": h.folio, "proyecto": str(h.proyecto_id) if h.proyecto_id else None,
        "proveedor": h.proveedor, "error": h.error, "creado_en": h.creado_en.isoformat(),
        "revisada_en": h.revisada_en.isoformat() if h.revisada_en else None,
    }


def _celda(c: CampoLeido):
    return {
        "fila": c.fila, "campo": c.campo, "texto_leido": c.texto_leido,
        "confianza": float(c.confianza) if c.confianza is not None else None, "caja": c.caja,
        "valor_propuesto": c.valor_propuesto, "origen_propuesta": c.origen_propuesta,
        "detalle_propuesta": c.detalle_propuesta, "requiere_revision": c.requiere_revision,
        "motivos_revision": c.motivos_revision, "valor_final": c.valor_final, "estado": c.estado,
        "motivo": c.motivo,
    }


def _hoja_detalle(h: HojaEscaneada):
    campos = list(h.campos.all())
    return {
        **_hoja_resumen(h),
        "version_plantilla": h.version_plantilla,
        "celdas": [_celda(c) for c in campos],
        "advertencias": servicios.advertencias_actuales(h),
        "celdas_descartadas": h.datos_extra.get("celdas_descartadas", []),
        "conteo": {
            "total": len(campos),
            "pendientes": sum(c.estado == CampoLeido.Estado.PENDIENTE for c in campos),
            "marcadas": sum(c.requiere_revision and c.estado == CampoLeido.Estado.PENDIENTE for c in campos),
        },
    }


@require_GET
@requiere_sesion
def plantillas(request):
    return JsonResponse({
        "plantillas": [p.a_dict() for p in PLANTILLAS.values()],
        "vocabularios": {k: list(v) for k, v in VOCABULARIOS.items()},
    })


@require_http_methods(["GET", "POST"])
@requiere_sesion
def hojas(request):
    if request.method == "GET":
        consulta = HojaEscaneada.objects.all()
        for filtro in ("estado", "tipo", "conjunto"):
            if request.GET.get(filtro):
                consulta = consulta.filter(**{filtro: request.GET[filtro]})
        return JsonResponse({"hojas": [_hoja_resumen(h) for h in consulta[:MAXIMO_LISTA]]})

    archivo = request.FILES.get("imagen")
    if archivo is None:
        raise servicios.DatosInvalidos("Falta la foto («imagen»).")
    proyecto = llenada_por = None
    if request.POST.get("proyecto"):
        proyecto = get_object_or_404(Proyecto, pk=request.POST["proyecto"])
    if request.POST.get("llenada_por"):
        llenada_por = get_object_or_404(Empleado, pk=request.POST["llenada_por"])
    hoja = servicios.registrar_hoja(
        archivo.read(), request.POST.get("tipo", ""), request.user,
        proyecto=proyecto, folio=request.POST.get("folio"), llenada_por=llenada_por,
        conjunto=request.POST.get("conjunto") or HojaEscaneada.Conjunto.ENTRENAMIENTO,
    )
    return JsonResponse(_hoja_detalle(hoja), status=201)


@require_GET
@requiere_sesion
def hoja(request, hoja_id):
    return JsonResponse(_hoja_detalle(get_object_or_404(HojaEscaneada, pk=hoja_id)))


@require_GET
@requiere_sesion
def imagen(request, hoja_id):
    h = get_object_or_404(HojaEscaneada, pk=hoja_id)
    respuesta = FileResponse(h.imagen.open("rb"), content_type=h.imagen_tipo)
    respuesta["Cache-Control"] = "private, no-store"
    return respuesta


@require_POST
@requiere_sesion
def leer(request, hoja_id):
    h = servicios.leer_hoja(get_object_or_404(HojaEscaneada, pk=hoja_id))
    return JsonResponse(_hoja_detalle(h))


@require_http_methods(["PATCH"])
@requiere_sesion
def campos(request, hoja_id):
    h = get_object_or_404(HojaEscaneada, pk=hoja_id)
    servicios.guardar_revision(h, _json(request).get("cambios"), request.user)
    return JsonResponse(_hoja_detalle(h))


@require_POST
@requiere_sesion
def confirmar_sin_observaciones(request, hoja_id):
    h = get_object_or_404(HojaEscaneada, pk=hoja_id)
    total = servicios.confirmar_sin_observaciones(h, request.user)
    return JsonResponse({"confirmadas": total, **_hoja_detalle(h)})


@require_POST
@requiere_sesion
def cerrar(request, hoja_id):
    h = get_object_or_404(HojaEscaneada, pk=hoja_id)
    h = servicios.cerrar_revision(h, request.user, bool(_json(request).get("aceptar_advertencias")))
    return JsonResponse(_hoja_detalle(h))


@require_POST
@requiere_sesion
def reabrir(request, hoja_id):
    h = servicios.reabrir_revision(get_object_or_404(HojaEscaneada, pk=hoja_id), request.user)
    return JsonResponse(_hoja_detalle(h))


@require_GET
@requiere_sesion
def resumen_aprendizaje(request):
    sinonimos = Sinonimo.objects.filter(confirmaciones__gt=F("rechazos")).order_by("-confirmaciones")[:100]
    confusiones = (
        ConfusionCaracter.objects.filter(escritor__isnull=True).exclude(leido=F("real")).order_by("-veces")[:100]
    )
    return JsonResponse({
        "hojas_aprendidas": HojaEscaneada.objects.filter(aprendida_en__isnull=False).count(),
        "por_estado": dict(HojaEscaneada.objects.values_list("estado").annotate(n=Count("id"))),
        "sinonimos": [
            {"vocabulario": s.vocabulario, "texto": s.clave, "valor": s.valor,
             "confirmaciones": s.confirmaciones, "rechazos": s.rechazos, "origen": s.origen}
            for s in sinonimos
        ],
        "confusiones": [
            {"tipo_campo": c.tipo_campo, "leido": c.leido, "real": c.real, "veces": c.veces} for c in confusiones
        ],
    })
