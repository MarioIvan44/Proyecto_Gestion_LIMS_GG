from django.urls import path

from . import views

app_name = "lectura"

urlpatterns = [
    path("plantillas/", views.plantillas, name="plantillas"),
    path("hojas/", views.hojas, name="hojas"),
    path("hojas/<uuid:hoja_id>/", views.hoja, name="hoja"),
    path("hojas/<uuid:hoja_id>/imagen/", views.imagen, name="imagen"),
    path("hojas/<uuid:hoja_id>/leer/", views.leer, name="leer"),
    path("hojas/<uuid:hoja_id>/campos/", views.campos, name="campos"),
    path("hojas/<uuid:hoja_id>/confirmar-sin-observaciones/", views.confirmar_sin_observaciones, name="confirmar"),
    path("hojas/<uuid:hoja_id>/cerrar/", views.cerrar, name="cerrar"),
    path("hojas/<uuid:hoja_id>/reabrir/", views.reabrir, name="reabrir"),
    path("aprendizaje/", views.resumen_aprendizaje, name="aprendizaje"),
]
