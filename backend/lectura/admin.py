from django.contrib import admin

from .models import CampoLeido, ConfusionCaracter, HojaEscaneada, Sinonimo


class CampoLeidoEnLinea(admin.TabularInline):
    model = CampoLeido
    extra = 0
    fields = ("fila", "campo", "texto_leido", "confianza", "valor_propuesto", "origen_propuesta", "valor_final", "estado")
    readonly_fields = ("texto_leido", "confianza", "valor_propuesto", "origen_propuesta")


@admin.register(HojaEscaneada)
class HojaEscaneadaAdmin(admin.ModelAdmin):
    list_display = ("creado_en", "tipo", "folio", "estado", "conjunto", "proveedor")
    list_filter = ("tipo", "estado", "conjunto")
    search_fields = ("folio",)
    inlines = [CampoLeidoEnLinea]


@admin.register(Sinonimo)
class SinonimoAdmin(admin.ModelAdmin):
    list_display = ("vocabulario", "clave", "valor", "confirmaciones", "rechazos", "origen")
    list_filter = ("vocabulario", "origen")
    search_fields = ("clave", "valor")


@admin.register(ConfusionCaracter)
class ConfusionCaracterAdmin(admin.ModelAdmin):
    list_display = ("tipo_campo", "escritor", "leido", "real", "veces")
    list_filter = ("tipo_campo",)
