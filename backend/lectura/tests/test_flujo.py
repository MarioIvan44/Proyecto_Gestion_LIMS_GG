"""
Flujo completo contra PostgreSQL con el proveedor simulado. Todos los datos son
inventados (no salen de hojas de clientes).
"""

import hashlib
import io
import json
import shutil
import tempfile
from decimal import Decimal

from django.core.management import call_command
from django.db import IntegrityError, transaction
from django.test import TestCase, override_settings

from lectura import aprendizaje
from lectura.models import CampoLeido, ConfusionCaracter, HojaEscaneada, Sinonimo
from lectura.motor.propuestas import PARECIDO, SINONIMO, VALIDACION
from nucleo.models import Empleado, Usuario

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64


def foto(n: int) -> bytes:
    """JPEG falso distinto para cada número (cambia la huella)."""
    return JPEG + n.to_bytes(4, "big")


class FlujoBase(TestCase):
    def setUp(self):
        self.media = tempfile.mkdtemp(prefix="lectura-media-")
        self.simulado = tempfile.mkdtemp(prefix="lectura-sim-")
        self.ajustes = override_settings(
            MEDIA_ROOT=self.media, LECTURA_PROVEEDOR="simulado", LECTURA_SIMULADO_DIR=self.simulado,
            LECTURA_UMBRAL_CONFIANZA=0.9,
        )
        self.ajustes.enable()
        self.usuario = Usuario.objects.create_user("revisor@ejemplo.test", "clave-prueba-123")
        self.client.force_login(self.usuario)

    def tearDown(self):
        self.ajustes.disable()
        shutil.rmtree(self.media, ignore_errors=True)
        shutil.rmtree(self.simulado, ignore_errors=True)

    def lectura_simulada(self, datos: bytes, celdas: list):
        nombre = hashlib.sha256(datos).hexdigest() + ".json"
        with open(f"{self.simulado}/{nombre}", "w", encoding="utf-8") as f:
            json.dump({"celdas": celdas}, f)

    def subir(self, datos: bytes, tipo="clasificacion", **extra):
        from django.core.files.uploadedfile import SimpleUploadedFile

        return self.client.post(
            "/api/lectura/hojas/", {"imagen": SimpleUploadedFile("hoja.jpg", datos), "tipo": tipo, **extra},
        )

    def revisar(self, hoja_id, cambios):
        return self.client.patch(
            f"/api/lectura/hojas/{hoja_id}/campos/", json.dumps({"cambios": cambios}), content_type="application/json",
        )

    def cerrar(self, hoja_id, aceptar=False):
        return self.client.post(
            f"/api/lectura/hojas/{hoja_id}/cerrar/", json.dumps({"aceptar_advertencias": aceptar}),
            content_type="application/json",
        )


class FlujoTests(FlujoBase):
    def test_sin_sesion_responde_401(self):
        self.client.logout()
        self.assertEqual(self.client.get("/api/lectura/hojas/").status_code, 401)

    def test_rechaza_archivos_que_no_son_fotos(self):
        r = self.subir(b"esto no es una imagen")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(HojaEscaneada.objects.count(), 0)

    def test_misma_foto_dos_veces_es_duplicada(self):
        datos = foto(1)
        self.lectura_simulada(datos, [])
        self.assertEqual(self.subir(datos).status_code, 201)
        r = self.subir(datos)
        self.assertEqual(r.status_code, 409)
        self.assertIn("hoja", r.json())

    def test_sin_lectura_simulada_queda_en_error_y_se_puede_reintentar(self):
        datos = foto(2)
        r = self.subir(datos)
        self.assertEqual(r.json()["estado"], "error")
        self.lectura_simulada(datos, [{"fila": 1, "campo": "pct_finos", "texto": "40", "confianza": 0.95}])
        r = self.client.post(f"/api/lectura/hojas/{r.json()['id']}/leer/")
        self.assertEqual(r.json()["estado"], "en_revision")
        self.assertEqual(len(r.json()["celdas"]), 1)

    def test_aprende_un_sinonimo_y_lo_propone_en_la_hoja_siguiente(self):
        # Hoja 1: el servicio lee «5M»; sin aprendizaje no hay propuesta. El revisor pone SM.
        d1 = foto(10)
        self.lectura_simulada(d1, [
            {"fila": 1, "campo": "simbolo", "texto": "5M", "confianza": 0.7},
            {"fila": 1, "campo": "pct_finos", "texto": "35", "confianza": 0.98},
        ])
        h1 = self.subir(d1).json()
        simbolo = next(c for c in h1["celdas"] if c["campo"] == "simbolo")
        self.assertIsNone(simbolo["valor_propuesto"])
        self.assertTrue(simbolo["requiere_revision"])

        # «Confirmar sin observaciones» solo toca lo que no está marcado.
        r = self.client.post(f"/api/lectura/hojas/{h1['id']}/confirmar-sin-observaciones/")
        self.assertEqual(r.json()["confirmadas"], 1)
        self.assertEqual(self.cerrar(h1["id"]).status_code, 409)  # el símbolo sigue pendiente

        self.assertEqual(self.revisar(h1["id"], [{"fila": 1, "campo": "simbolo", "valor_final": "sm"}]).status_code, 200)
        r = self.cerrar(h1["id"])
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["estado"], "revisada")

        s = Sinonimo.objects.get(vocabulario="simbolo_uscs", clave="5M")
        self.assertEqual((s.valor, s.confirmaciones), ("SM", 1))
        self.assertTrue(ConfusionCaracter.objects.filter(tipo_campo="texto", leido="5", real="S", escritor=None).exists())

        # Hoja 2: el mismo «5M» ahora llega con propuesta SM, todavía marcada para revisión.
        d2 = foto(11)
        self.lectura_simulada(d2, [{"fila": 1, "campo": "simbolo", "texto": "5M", "confianza": 0.95}])
        h2 = self.subir(d2).json()
        celda = h2["celdas"][0]
        self.assertEqual((celda["valor_propuesto"], celda["origen_propuesta"]), ("SM", SINONIMO))
        self.assertTrue(celda["requiere_revision"])

    def test_valor_fuera_de_lista_exige_motivo(self):
        d = foto(20)
        self.lectura_simulada(d, [{"fila": 1, "campo": "simbolo", "texto": "MH/CL", "confianza": 0.9}])
        h = self.subir(d).json()
        r = self.revisar(h["id"], [{"fila": 1, "campo": "simbolo", "valor_final": "MH/CL"}])
        self.assertEqual(r.status_code, 400)
        r = self.revisar(h["id"], [{"fila": 1, "campo": "simbolo", "valor_final": "MH/CL", "motivo": "la hoja dice MH/CL"}])
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.cerrar(h["id"]).status_code, 200)
        self.assertFalse(Sinonimo.objects.exists())  # no se aprende un valor fuera de la lista

    def test_numero_invalido_no_guarda_nada(self):
        d = foto(21)
        self.lectura_simulada(d, [{"fila": 1, "campo": "pct_finos", "texto": "4O", "confianza": 0.9}])
        h = self.subir(d).json()
        r = self.revisar(h["id"], [
            {"fila": 1, "campo": "pct_arena", "valor_final": "30"},
            {"fila": 1, "campo": "pct_finos", "valor_final": "cuarenta"},
        ])
        self.assertEqual(r.status_code, 400)
        self.assertEqual(len(r.json()["errores"]), 1)
        self.assertFalse(CampoLeido.objects.filter(campo="pct_arena").exists())

    def test_advertencias_exigen_aceptacion_al_cerrar(self):
        d = foto(30)
        self.lectura_simulada(d, [
            {"fila": 1, "campo": "pct_grava", "texto": "0", "confianza": 0.99},
            {"fila": 1, "campo": "pct_arena", "texto": "20", "confianza": 0.99},
            {"fila": 1, "campo": "pct_finos", "texto": "30", "confianza": 0.99},
        ])
        h = self.subir(d).json()
        self.assertEqual(h["advertencias"][0]["regla"], "porcentajes_100")
        self.revisar(h["id"], [
            {"fila": 1, "campo": c, "valor_final": v} for c, v in (("pct_grava", "0"), ("pct_arena", "20"), ("pct_finos", "30"))
        ])
        self.assertEqual(self.cerrar(h["id"]).status_code, 409)
        r = self.cerrar(h["id"], aceptar=True)
        self.assertEqual(r.status_code, 200)
        hoja = HojaEscaneada.objects.get(pk=h["id"])
        self.assertEqual(hoja.datos_extra["advertencias_aceptadas"][0]["regla"], "porcentajes_100")

    def test_confusion_por_tecnico_y_resolucion_por_regla(self):
        tecnico = Empleado.objects.create(nombres="Técnico", apellidos="De Prueba")
        # Tres hojas en las que el técnico escribió 7 y se leyó 1.
        for n in range(3):
            d = foto(40 + n)
            self.lectura_simulada(d, [{"fila": 1, "campo": "golpes_1", "texto": "1", "confianza": 0.95}])
            h = self.subir(d, tipo="spt", llenada_por=str(tecnico.id)).json()
            self.revisar(h["id"], [{"fila": 1, "campo": "golpes_1", "valor_final": "7"}])
            self.assertEqual(self.cerrar(h["id"]).status_code, 200)
        self.assertEqual(
            ConfusionCaracter.objects.get(tipo_campo="numero", escritor=tecnico, leido="1", real="7").veces, 3,
        )
        # Nueva hoja del mismo técnico: tramo 3 leído «1», pero N = 15 con tramo 2 = 8.
        d = foto(50)
        self.lectura_simulada(d, [
            {"fila": 1, "campo": "golpes_2", "texto": "8", "confianza": 0.97},
            {"fila": 1, "campo": "golpes_3", "texto": "1", "confianza": 0.95},
            {"fila": 1, "campo": "n_spt", "texto": "15", "confianza": 0.97},
        ])
        h = self.subir(d, tipo="spt", llenada_por=str(tecnico.id)).json()
        g3 = next(c for c in h["celdas"] if c["campo"] == "golpes_3")
        self.assertEqual((g3["valor_propuesto"], g3["origen_propuesta"]), ("7", VALIDACION))
        self.assertEqual(h["advertencias"], [])

    def test_hojas_de_prueba_no_ensenan(self):
        d = foto(60)
        self.lectura_simulada(d, [{"fila": 1, "campo": "simbolo", "texto": "5M", "confianza": 0.9}])
        h = self.subir(d, conjunto="prueba").json()
        self.revisar(h["id"], [{"fila": 1, "campo": "simbolo", "valor_final": "SM"}])
        self.cerrar(h["id"])
        self.assertFalse(Sinonimo.objects.exists())

    def test_reabrir_y_cerrar_no_cuenta_dos_veces(self):
        d = foto(70)
        self.lectura_simulada(d, [{"fila": 1, "campo": "simbolo", "texto": "5M", "confianza": 0.9}])
        h = self.subir(d).json()
        self.revisar(h["id"], [{"fila": 1, "campo": "simbolo", "valor_final": "SM"}])
        self.cerrar(h["id"])
        self.client.post(f"/api/lectura/hojas/{h['id']}/reabrir/")
        self.cerrar(h["id"])
        self.assertEqual(Sinonimo.objects.get(clave="5M").confirmaciones, 1)

    def test_reentrenar_y_medir(self):
        for n, (leido, real) in enumerate((("5M", "SM"), ("5M", "SM"), ("CL", "CL"))):
            d = foto(80 + n)
            self.lectura_simulada(d, [{"fila": 1, "campo": "simbolo", "texto": leido, "confianza": 0.95}])
            h = self.subir(d).json()
            self.revisar(h["id"], [{"fila": 1, "campo": "simbolo", "valor_final": real}])
            self.cerrar(h["id"])
        Sinonimo.objects.update(confirmaciones=99)  # basura que reentrenar debe corregir
        resultado = aprendizaje.reconstruir()
        self.assertEqual(resultado["hojas"], 3)
        self.assertEqual(Sinonimo.objects.get(clave="5M").confirmaciones, 2)
        salida = io.StringIO()
        call_command("medir_exactitud_lectura", "--conjunto", "entrenamiento", stdout=salida)
        # Solo «CL» se leyó bien (1 de 3); con lo aprendido, las 3 propuestas aciertan.
        self.assertIn("lectura   33.3 %", salida.getvalue())
        self.assertIn("propuesta  100.0 %", salida.getvalue())


class RestriccionesTests(FlujoBase):
    def test_la_base_rechaza_confianza_fuera_de_rango_y_estados_invalidos(self):
        d = foto(90)
        self.lectura_simulada(d, [{"fila": 1, "campo": "pct_finos", "texto": "40", "confianza": 0.95}])
        h = HojaEscaneada.objects.get(pk=self.subir(d).json()["id"])
        with self.assertRaises(IntegrityError), transaction.atomic():
            CampoLeido.objects.filter(hoja=h).update(confianza=Decimal("1.5"))
        with self.assertRaises(IntegrityError), transaction.atomic():
            CampoLeido.objects.filter(hoja=h).update(estado="confirmado")  # sin fecha de revisión
        with self.assertRaises(IntegrityError), transaction.atomic():
            HojaEscaneada.objects.filter(pk=h.pk).update(estado="revisada")  # sin fecha
