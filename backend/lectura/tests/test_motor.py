"""Pruebas del motor (Python puro, sin base de datos). Todos los datos son inventados."""

from django.test import SimpleTestCase

from lectura.motor import propuestas as p
from lectura.motor.confusiones import NUMERO, TEXTO, TablaConfusiones
from lectura.motor.plantillas import ATTERBERG, CLASIFICACION, SPT
from lectura.motor.texto import clave, distancia, pares_de_caracteres, pares_de_palabras
from lectura.motor.vocabularios import PALABRAS, SIMBOLO_USCS

UMBRAL = 0.9


def con_vacio():
    return p.Conocimiento()


class TextoTests(SimpleTestCase):
    def test_clave_quita_tildes_y_conserva_la_enie(self):
        self.assertEqual(clave("  arcilla  limosa, café. "), "ARCILLA LIMOSA, CAFE")
        self.assertEqual(clave("Año"), "AÑO")

    def test_pares_de_caracteres_incluye_aciertos_y_sustituciones(self):
        self.assertEqual(pares_de_caracteres("1O", "10"), [("1", "1"), ("O", "0")])

    def test_pares_de_palabras_toma_cambios_uno_a_uno(self):
        self.assertEqual(pares_de_palabras("HINO arenoso", "LIMO arenoso"), [("HINO", "LIMO")])
        self.assertEqual(pares_de_palabras("limo c/ arena", "limo con arena"), [("C/", "con")])

    def test_distancia_con_costo_reducido(self):
        self.assertEqual(distancia("5M", "SM"), 1.0)
        self.assertAlmostEqual(distancia("5M", "SM", lambda x, y: 0 if x == y else 0.2), 0.2)


class PropuestaOpcionTests(SimpleTestCase):
    simbolo = CLASIFICACION.campo("simbolo")

    def test_valor_de_la_lista_aunque_cambien_espacios_y_mayusculas(self):
        r = p.proponer(self.simbolo, "sp - sm", con_vacio())
        self.assertEqual((r.valor, r.origen), ("SP-SM", p.LECTURA))

    def test_ambiguo_sin_aprendizaje_no_propone(self):
        # «5M» está a un carácter de SM y de GM: sin datos no hay por qué elegir.
        r = p.proponer(self.simbolo, "5M", con_vacio())
        self.assertEqual(r.origen, p.SIN_PROPUESTA)
        self.assertIsNone(r.valor)

    def test_con_confusion_aprendida_elige_el_parecido(self):
        con = con_vacio()
        con.confusiones.sumar(TEXTO, "5", "S", 4)
        r = p.proponer(self.simbolo, "5M", con)
        self.assertEqual((r.valor, r.origen), ("SM", p.PARECIDO))

    def test_sinonimo_aprendido_gana_al_parecido(self):
        con = con_vacio()
        con.agregar_sinonimo(SIMBOLO_USCS, "5M", "SM", confirmaciones=3)
        r = p.proponer(self.simbolo, "5m", con)
        self.assertEqual((r.valor, r.origen), ("SM", p.SINONIMO))
        self.assertAlmostEqual(r.confiabilidad, 0.8)

    def test_sinonimo_con_mas_rechazos_no_se_usa(self):
        con = con_vacio()
        con.agregar_sinonimo(SIMBOLO_USCS, "5M", "SM", confirmaciones=1, rechazos=2)
        self.assertIsNone(con.sinonimo(SIMBOLO_USCS, "5M"))

    def test_sinonimos_empatados_no_se_usan(self):
        con = con_vacio()
        con.agregar_sinonimo(SIMBOLO_USCS, "X", "SM", 2)
        con.agregar_sinonimo(SIMBOLO_USCS, "X", "GM", 2)
        self.assertIsNone(con.sinonimo(SIMBOLO_USCS, "X"))

    def test_valor_fuera_de_lista_queda_sin_propuesta(self):
        r = p.proponer(self.simbolo, "MH/CL", con_vacio())
        self.assertEqual(r.origen, p.SIN_PROPUESTA)


class PropuestaNumeroTests(SimpleTestCase):
    golpes = SPT.campo("golpes_1")
    profundidad = SPT.campo("profundidad")

    def test_numero_limpio(self):
        self.assertEqual(p.proponer(self.golpes, "12", con_vacio()).origen, p.LECTURA)

    def test_coma_decimal_es_formato(self):
        r = p.proponer(self.profundidad, "1,50", con_vacio())
        self.assertEqual((r.valor, r.origen), ("1.50", p.FORMATO))

    def test_letra_por_digito_con_confusion_inicial(self):
        r = p.proponer(self.golpes, "1O", con_vacio())
        self.assertEqual((r.valor, r.origen), ("10", p.CONFUSION))
        self.assertEqual(r.detalle["cambios"][0]["origen"], "inicial")

    def test_lo_aprendido_reemplaza_lo_inicial(self):
        con = con_vacio()
        con.confusiones.sumar(NUMERO, "S", "8", 3)
        con.confusiones.sumar(NUMERO, "S", "5", 1)
        r = p.proponer(self.golpes, "S", con)
        self.assertEqual(r.valor, "8")
        self.assertAlmostEqual(r.confiabilidad, 0.75)

    def test_entero_con_decimales_no_se_acepta(self):
        self.assertEqual(p.proponer(self.golpes, "12.5", con_vacio()).origen, p.SIN_PROPUESTA)

    def test_vacio(self):
        self.assertEqual(p.proponer(self.golpes, "  ", con_vacio()).origen, p.VACIO)


class PropuestaTextoTests(SimpleTestCase):
    def test_reemplaza_palabras_aprendidas(self):
        con = con_vacio()
        con.agregar_sinonimo(PALABRAS, "HINO", "LIMO", 2)
        con.agregar_sinonimo(PALABRAS, "C/", "con", 5)
        r = p.proponer(SPT.campo("descripcion"), "HINO c/ arena", con)
        self.assertEqual((r.valor, r.origen), ("LIMO con arena", p.SINONIMO))
        self.assertEqual(len(r.detalle["reemplazos"]), 2)


class HojaTests(SimpleTestCase):
    def test_regla_n_spt_marca_las_tres_celdas(self):
        entradas = [
            p.CeldaEntrada(1, "golpes_2", "8", 0.99),
            p.CeldaEntrada(1, "golpes_3", "7", 0.99),
            p.CeldaEntrada(1, "n_spt", "16", 0.99),
        ]
        r = p.proponer_hoja(SPT, entradas, con_vacio(), UMBRAL)
        self.assertEqual([a.regla for a in r.advertencias], ["n_spt"])
        self.assertTrue(all(c.requiere_revision for c in r.celdas))

    def test_un_solo_cambio_aprendido_que_cumple_la_regla_se_propone(self):
        con = con_vacio()
        con.confusiones.sumar(NUMERO, "1", "7", 3)
        con.confusiones.sumar(NUMERO, "1", "1", 7)
        entradas = [
            p.CeldaEntrada(1, "golpes_2", "8", 0.97),
            p.CeldaEntrada(1, "golpes_3", "1", 0.95),
            p.CeldaEntrada(1, "n_spt", "15", 0.97),
        ]
        r = p.proponer_hoja(SPT, entradas, con, UMBRAL)
        g3 = next(c for c in r.celdas if c.campo == "golpes_3")
        self.assertEqual((g3.propuesta.valor, g3.propuesta.origen), ("7", p.VALIDACION))
        self.assertEqual(r.advertencias, [])
        self.assertTrue(g3.requiere_revision)  # aun así lo confirma una persona

    def test_rechazo_no_exige_la_suma(self):
        entradas = [
            p.CeldaEntrada(1, "golpes_2", "50", 0.99),
            p.CeldaEntrada(1, "golpes_3", "10", 0.99),
            p.CeldaEntrada(1, "n_spt", "50", 0.99),
        ]
        self.assertEqual(p.proponer_hoja(SPT, entradas, con_vacio(), UMBRAL).advertencias, [])

    def test_lectura_limpia_con_confianza_alta_no_se_marca(self):
        r = p.proponer_hoja(SPT, [p.CeldaEntrada(1, "golpes_1", "4", 0.98)], con_vacio(), UMBRAL)
        self.assertFalse(r.celdas[0].requiere_revision)

    def test_confianza_baja_se_marca(self):
        r = p.proponer_hoja(SPT, [p.CeldaEntrada(1, "golpes_1", "4", 0.6)], con_vacio(), UMBRAL)
        self.assertTrue(r.celdas[0].requiere_revision)

    def test_profundidad_que_no_crece(self):
        entradas = [p.CeldaEntrada(1, "profundidad", "1.50", 0.99), p.CeldaEntrada(2, "profundidad", "1.00", 0.99)]
        r = p.proponer_hoja(SPT, entradas, con_vacio(), UMBRAL)
        self.assertEqual([(a.regla, a.fila) for a in r.advertencias], [("profundidad_creciente", 2)])

    def test_porcentajes_y_ip(self):
        clasif = [
            p.CeldaEntrada(1, "pct_grava", "0", 0.99), p.CeldaEntrada(1, "pct_arena", "20", 0.99),
            p.CeldaEntrada(1, "pct_finos", "30", 0.99),
        ]
        self.assertEqual(p.proponer_hoja(CLASIFICACION, clasif, con_vacio(), UMBRAL).advertencias[0].regla, "porcentajes_100")
        att = [p.CeldaEntrada(0, "ll", "32", 0.99), p.CeldaEntrada(0, "lp", "20", 0.99), p.CeldaEntrada(0, "ip", "12", 0.99)]
        self.assertEqual(p.proponer_hoja(ATTERBERG, att, con_vacio(), UMBRAL).advertencias, [])

    def test_celdas_fuera_de_plantilla_o_repetidas_se_descartan(self):
        entradas = [
            p.CeldaEntrada(1, "no_existe", "x", 0.9),
            p.CeldaEntrada(0, "golpes_1", "3", 0.9),  # golpes no va en el encabezado
            p.CeldaEntrada(1, "golpes_1", "3", 0.9),
            p.CeldaEntrada(1, "golpes_1", "4", 0.9),
        ]
        r = p.proponer_hoja(SPT, entradas, con_vacio(), UMBRAL)
        self.assertEqual(len(r.celdas), 1)
        self.assertEqual(len(r.campos_desconocidos), 3)

    def test_confianza_fuera_de_rango_se_ignora(self):
        r = p.proponer_hoja(SPT, [p.CeldaEntrada(1, "golpes_1", "4", 7.0)], con_vacio(), UMBRAL)
        self.assertIsNone(r.celdas[0].confianza)
        self.assertTrue(r.celdas[0].requiere_revision)


class TablaConfusionesTests(SimpleTestCase):
    def test_probabilidad_y_costo(self):
        t = TablaConfusiones()
        t.sumar(NUMERO, "1", "7", 1)
        t.sumar(NUMERO, "1", "1", 3)
        self.assertAlmostEqual(t.probabilidad(NUMERO, "1", "7"), 0.25)
        self.assertAlmostEqual(t.costo(NUMERO)("1", "7"), 0.75)
        self.assertEqual(t.alternativas(NUMERO, "1"), [("7", 0.25, "aprendido")])
