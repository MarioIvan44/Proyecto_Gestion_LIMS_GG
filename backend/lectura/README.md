# Lectura de hojas del laboratorio

Convierte la foto de una hoja llenada a mano (SPT de campo, clasificación SUCS M23-REG 02 o límites de Atterberg M04-REG01) en datos. Una persona revisa cada celda con la foto al lado, y el sistema aprende de cada corrección.

## Cómo funciona

```
foto ─► servicio de lectura ─► propuesta por celda ─► revisión con la foto al lado ─► hoja revisada
          (texto + confianza)    (sinónimos, confusiones,    (confirma / corrige /         │
                                  reglas de la hoja)          ilegible)                     ▼
                                        ▲                                       aprendizaje
                                        └──────────── sinónimos y confusiones ◄──┘
```

1. **Subir la foto.** Se acepta JPEG, PNG, HEIC o PDF. El tipo se detecta por los primeros bytes del archivo, no por la extensión. Cada foto guarda su huella SHA-256, así que la misma foto no se puede subir dos veces.
2. **Leer.** El servicio de lectura devuelve, por cada celda, el texto y su confianza (de 0 a 1).
3. **Proponer.** El motor (`motor/`, Python puro) arma una propuesta para cada celda y marca las dudosas. Intenta, en este orden:

   | Origen | Ejemplo | Se marca para revisión |
   |---|---|---|
   | `lectura` | «12» en un campo numérico | Solo si la confianza es baja |
   | `formato` | «1,50» → «1.50» | Sí |
   | `sinonimo` | «HINO» → «LIMO», si un revisor ya hizo ese cambio | Sí |
   | `parecido` | «5M» → «SM», si se sabe que el 5 suele ser una S | Sí |
   | `confusion` | «1O» → «10» | Sí |
   | `validacion` | N = 15 y tramo 2 = 8, pero el tramo 3 se leyó «1»: se propone «7» | Sí |
   | `sin_propuesta` | «MH/CL» no está en la lista: lo decide el revisor | Sí |

4. **Revisar.** El revisor confirma, corrige o marca como ilegible cada celda. Con «Confirmar sin observaciones» acepta de una vez las celdas no marcadas; ese botón lo aprieta una persona, el sistema nunca confirma solo.
5. **Cerrar.** No se puede cerrar con celdas pendientes. Si una regla de la hoja no se cumple (por ejemplo, los porcentajes no suman 100), hay que corregir o aceptar la advertencia de forma explícita, y queda guardada.
6. **Aprender.** Al cerrar, el sistema aprende de la hoja (`aprendizaje.py`).

## ¿El sistema se «entrena solo»?

Sí, pero en dos capas distintas:

- **Leer la letra (reconocer trazos) lo hace el servicio de lectura.** Entrenar un reconocedor de letra propio desde cero requiere miles de ejemplos etiquetados, y hoy hay 36 folios de referencia. Por eso esa parte se compra hecha.
- **Lo que el servicio no sabe del laboratorio lo aprende este sistema**, con cada hoja revisada:
  - **Sinónimos y abreviaturas.** Cada vez que el revisor cambia «c/» por «con», o «5M» por «SM», se suma una confirmación. La próxima vez se propone ese mismo cambio, con una confiabilidad que sube con cada confirmación y baja con cada rechazo.
  - **Confusiones de caracteres por técnico.** Se cuenta qué se leyó y qué era en realidad («1» que era «7»), en general y por técnico (`llenada_por`), porque cada persona escribe distinto.
  - **Reglas de la hoja** (N = tramo 2 + tramo 3, IP = LL − LP, porcentajes que suman 100, profundidades crecientes). Detectan lecturas imposibles y ayudan a elegir entre candidatos.

Además, cada hoja revisada queda como un **ejemplo etiquetado** (foto + valores correctos). Cuando haya suficientes, sirven para entrenar un modelo personalizado en el servicio elegido, si ese servicio lo permite.

**Medición honesta.** Las hojas del conjunto `prueba` nunca se usan para aprender; sirven para medir con hojas que el sistema no ha visto. Ningún porcentaje de exactitud se promete hasta medirlo con las hojas de referencia.

## Servicios de lectura evaluados

Todavía no se ha probado ninguno con las hojas reales. Esta tabla es una evaluación preliminar para elegir cuáles entran en la prueba comparativa. Lo marcado «por verificar» no está comprobado.

| Herramienta | ¿Sirve para integrarla? | Notas |
|---|---|---|
| Google Lens / Google Keep | No | Son apps para personas, sin interfaz para conectarlas al sistema. Sirven para probar a mano qué tan legible es una hoja. |
| Modelos de lenguaje con visión, por API | Sí, candidato | Leen letra difícil usando el contexto de la hoja y devuelven JSON por campo. No dan una confianza por celda confiable, así que hay que estimarla. Tienen costo por hoja y la respuesta puede variar entre intentos. |
| Pen to Print | Por verificar | App de letra a mano para personas; falta confirmar si tiene interfaz para empresas. |
| Transkribus | Por verificar | Especializado en manuscritos y permite entrenar un modelo propio con transcripciones. Está pensado para texto corrido; falta ver cómo maneja tablas. |
| Google Cloud Document AI | Sí, candidato | Formularios y tablas con letra a mano, confianza por campo, extractor entrenable con ejemplos. |
| Amazon Textract | Sí, candidato | Formularios y tablas, letra a mano, confianza por palabra. |
| Parseur / Extend | Por verificar | Plataformas de extracción sobre OCR o IA: menos programación, pero menos control. |

Propuesta: comparar dos o tres candidatos con los mismos folios de referencia, usando `medir_exactitud_lectura`, y quedarse con el de menos **errores sin marcar**. Esa es la cifra que importa, porque son los errores que un revisor apurado dejaría pasar. Cada servicio se agrega como una clase en `motor/proveedores.py`, con su clave en `backend/.env`.

Hoy existen dos proveedores: `manual` (no lee; se captura todo con la foto al lado) y `simulado` (lecturas guardadas en JSON, para pruebas con datos inventados).

## API (`/api/lectura/`)

Usa la sesión de Django y su protección CSRF: React debe enviar la cabecera `X-CSRFToken`. Sin sesión, la API responde 401. Las rutas están listadas en [`views.py`](views.py).

Ejemplo de revisión:

```json
PATCH /api/lectura/hojas/<id>/campos/
{"cambios": [
  {"fila": 1, "campo": "golpes_3", "valor_final": "7"},
  {"fila": 1, "campo": "simbolo", "valor_final": "MH/CL", "motivo": "la hoja dice MH/CL"},
  {"fila": 2, "campo": "descripcion", "ilegible": true}
]}
```

Para la tabla, la fila 0 es el encabezado de la hoja; las filas 1, 2, 3... son los renglones.

## Comandos

```bash
python manage.py cargar_hoja_transcrita --imagen foto.jpg --tipo spt --transcripcion hoja.json --usuario correo --conjunto entrenamiento
python manage.py medir_exactitud_lectura --conjunto prueba --csv exactitud.csv
python manage.py reentrenar_lectura
```

- `cargar_hoja_transcrita` carga hojas que ya están digitalizadas correctamente, para enseñar (`entrenamiento`) o medir (`prueba`).
- `medir_exactitud_lectura` mide, por campo, la exactitud de la lectura, la exactitud de la propuesta, las celdas marcadas y los errores sin marcar.
- `reentrenar_lectura` rehace todo lo aprendido desde las hojas revisadas.

## Base de datos

| Tabla | Qué guarda |
|---|---|
| `HojaEscaneada` | Foto, tipo de hoja, estado, conjunto, técnico que la llenó, servicio y respuesta completa del servicio |
| `CampoLeido` | Por celda: texto leído, confianza, propuesta y su origen, motivos de revisión, valor final, quién lo revisó y por qué |
| `Sinonimo` | Texto leído → valor, con confirmaciones y rechazos. Tiene origen `aprendido`, o `cargado` para un glosario que entregue la empresa |
| `ConfusionCaracter` | Carácter leído → real, con número de veces, en general y por técnico |

Sigue las convenciones de toda la base: UUID v7, `datos_extra` y restricciones `CHECK` en la propia base.

Las fotos son datos de clientes. Se guardan en `LECTURA_MEDIA_ROOT`, fuera del repositorio, y solo se entregan con sesión iniciada.

## Supuestos y pendientes

- **Plantillas en borrador (`0-borrador`).** Los campos de cada hoja salen de las hojas de referencia; falta confirmarlos contra la hoja impresa.
- **Umbral de confianza de 0.90** (`LECTURA_UMBRAL_CONFIANZA`). Hay que calibrarlo con las hojas de referencia.
- **Confusiones iniciales letra→número** (O→0, S→5...). Solo se usan mientras no haya nada aprendido; se revisan con las primeras hojas reales.
- **Rechazo en el SPT con 50 golpes.** Con rechazo no se exige N = tramo 2 + tramo 3. El criterio exacto de la empresa está pendiente.
- **IP = LL − LP se exige exacto.** Si la diferencia es de 1, el mensaje avisa que puede venir del redondeo; el criterio está pendiente.
- **Falta pasar las hojas revisadas a sondeos y muestras**, que es lo que alimenta el Anexo 02 y las exportaciones. Esas tablas todavía no existen.
