"""Pruebas de las conversiones y de los identificadores (no necesitan base de datos)."""

from datetime import date, datetime, time, timezone
from decimal import Decimal

from bson import ObjectId
from django.test import SimpleTestCase

from nucleo.ids import uuid7, uuid7_desde_objectid

from .conversiones import (
    Contexto, Rechazo, a_json, booleano, decimal, fecha_dia, fecha_texto, hora, opcion, texto,
)


def ctx():
    return Contexto("coleccion", "000000000000000000000000")


class ConversionesTests(SimpleTestCase):
    def test_decimal_quita_ruido_de_punto_flotante_sin_advertir(self):
        c = ctx()
        self.assertEqual(decimal()(0.1 + 0.2, c, "monto"), Decimal("0.3000"))
        self.assertEqual(c.advertencias, [])
        self.assertIn(("ruido de punto flotante quitado", "monto"), c.conteos)

    def test_decimal_advierte_si_redondea_de_verdad(self):
        c = ctx()
        self.assertEqual(decimal()(13.123456, c, "total"), Decimal("13.1235"))
        self.assertEqual(len(c.advertencias), 1)

    def test_decimal_conserva_el_iva_de_cuatro_decimales(self):
        self.assertEqual(decimal()(13.845, ctx(), "impuesto"), Decimal("13.8450"))

    def test_decimal_convierte_texto_exacto_y_rechaza_lo_demas(self):
        c = ctx()
        self.assertEqual(decimal()("45.50", c, "costo"), Decimal("45.5000"))
        self.assertIn(("número guardado como texto", "costo"), c.conteos)
        for malo in ("abc", " 45", "1,5", True):
            with self.assertRaises(Rechazo):
                decimal()(malo, ctx(), "costo")

    def test_texto_vacio_solo_pasa_a_null_en_campos_unicos(self):
        self.assertEqual(texto()("", ctx(), "notas"), "")
        self.assertIsNone(texto(vacio_a_null=True)("", ctx(), "email"))
        with self.assertRaises(Rechazo):
            texto(5)("demasiado largo", ctx(), "codigo")

    def test_booleano(self):
        self.assertTrue(booleano()("true", ctx(), "activo"))
        self.assertFalse(booleano()(0, ctx(), "activo"))
        with self.assertRaises(Rechazo):
            booleano()("si", ctx(), "activo")

    def test_fecha_dia_toma_el_dia_utc_y_advierte_si_tenia_hora(self):
        c = ctx()
        medianoche = datetime(2026, 10, 13, tzinfo=timezone.utc)
        self.assertEqual(fecha_dia()(medianoche, c, "fecha"), date(2026, 10, 13))
        self.assertEqual(c.advertencias, [])
        con_hora = datetime(2026, 10, 9, 15, 30, tzinfo=timezone.utc)
        self.assertEqual(fecha_dia()(con_hora, c, "fecha"), date(2026, 10, 9))
        self.assertEqual(len(c.advertencias), 1)

    def test_fecha_texto_rechaza_formatos_ambiguos(self):
        self.assertEqual(fecha_texto()("2026-11-02", ctx(), "issueDate"), date(2026, 11, 2))
        with self.assertRaises(Rechazo):
            fecha_texto()("13/10/2026", ctx(), "issueDate")

    def test_hora(self):
        self.assertEqual(hora()("07:30", ctx(), "inicio"), time(7, 30))
        with self.assertRaises(Rechazo):
            hora()("8:00 AM", ctx(), "inicio")

    def test_opcion(self):
        estados = {"in progress": "en_progreso"}
        self.assertEqual(opcion(estados)("in progress", ctx(), "status"), "en_progreso")
        with self.assertRaises(Rechazo):
            opcion(estados)("on hold", ctx(), "status")

    def test_a_json_usa_el_formato_de_javascript(self):
        momento = datetime(2026, 9, 7, 0, 0, 0, 123000, tzinfo=timezone.utc)
        self.assertEqual(a_json(momento), "2026-09-07T00:00:00.123Z")


class IdsTests(SimpleTestCase):
    def test_uuid_derivado_conserva_el_orden_de_los_objectid(self):
        oids = sorted(ObjectId() for _ in range(50))
        uuids = [str(uuid7_desde_objectid(o)) for o in oids]
        self.assertEqual(uuids, sorted(uuids))

    def test_uuid_derivado_es_estable_y_version_7(self):
        oid = ObjectId()
        self.assertEqual(uuid7_desde_objectid(oid), uuid7_desde_objectid(str(oid)))
        self.assertEqual(uuid7_desde_objectid(oid).version, 7)
        self.assertNotEqual(uuid7_desde_objectid(oid, 0), uuid7_desde_objectid(oid, 1))

    def test_uuid7_nuevo_va_despues_de_los_migrados(self):
        self.assertGreater(str(uuid7()), str(uuid7_desde_objectid(ObjectId())))
