# Migración MongoDB → PostgreSQL

Copia la base MongoDB del sistema administrativo (14 colecciones) a la base central PostgreSQL. El plan y las decisiones están en [`PLAN_MIGRACION.md`](../../PLAN_MIGRACION.md).

## Reglas

- **MongoDB solo se lee.** El script solo hace `find` y conteos. Con Atlas, usa un usuario con rol `read`.
- **Primero contra una copia.** Nunca se apunta a Atlas mientras se prueba.
- **Se puede repetir.** Cada fila guarda el `_id` de su documento en `mongo_id`. Al repetir, la fila se actualiza y no se duplica.
- **Nada se corrige en silencio.** Lo que no se puede migrar queda en el informe con su motivo. Las correcciones que decida la empresa van en un archivo aparte (ver «Correcciones»).

## Requisitos

- Python 3.12 y el entorno de `backend/` (`pip install -r requirements.txt`).
- `backend/.env` con `DATABASE_URL`, `MONGO_URI` y `MONGO_DB` (ver `backend/.env.example`).
- Las tablas creadas: `python manage.py migrate`.

## Uso

```bash
# Ensayo: hace todo y al final lo deshace; deja el informe.
python manage.py migrar_mongo --simular

# Migración real. --destino debe coincidir con la base de DATABASE_URL (evita escribir en otra por error).
python manage.py migrar_mongo --destino <base>
```

Opciones:

| Opción | Para qué |
|---|---|
| `--simular` | No guarda nada en PostgreSQL. |
| `--destino <base>` | Obligatoria si no es simulación. |
| `--incluir-demo` | Incluye los documentos de demostración (`isSeedData: true`). Solo para pruebas. |
| `--correcciones <archivo>` | Archivo de correcciones. Por defecto, `migracion/correcciones.yaml` si existe. |
| `--mongo-uri`, `--mongo-db` | Cambian el origen de `.env` para una corrida. |

El comando termina con error si algún conteo o suma no cuadra.

## El informe

Cada corrida crea `migracion/informes/<fecha-hora>/`. Esa carpeta está fuera de git porque puede contener datos personales.

- `informe.md`: el resumen por colección, la validación de conteos y sumas, los totales que no cuadran con sus partes, las correcciones aplicadas, los rechazos, las advertencias, las conversiones, los campos fuera del esquema, las colecciones que no se migran y las filas cuyo documento ya no existe en MongoDB.
- `rechazos.csv` y `advertencias.csv`: la lista completa, una fila por documento o elemento.
- `resumen.json`: los mismos números, para comparar corridas.

Qué pasa con cada tipo de dato sucio:

| Caso | Resultado |
|---|---|
| Línea de planilla cuya planilla no existe | Rechazo (la línea es parte de la planilla) |
| Otra referencia a algo que no existe (por ejemplo, un empleado o una proforma borrados) | Se migra con la relación vacía, con advertencia (no se pierde el registro) |
| Número o booleano guardado como texto exacto (`"45.50"`, `"true"`) | Se convierte y se cuenta |
| Texto que no es número, fecha no reconocida, hora que no es HH:MM, estado fuera de la lista | Rechazo |
| Más de 4 decimales | Se redondea a 4, con advertencia |
| Fecha «de día» que no está a medianoche UTC | Se toma el día UTC, con advertencia |
| `""` en un campo único (correo, DUI, RUC, número de factura) | Pasa a NULL y se cuenta. En los demás campos se conserva `""` |
| Duplicado en un campo único | Se conserva el documento más antiguo y se rechaza el otro |
| Totales que no cuadran con sus partes | Se migran tal cual, con advertencia |
| Campo fuera del esquema | Se guarda en la columna `datos_extra` |
| Elemento quitado de un arreglo en MongoDB desde la corrida anterior | Se borra su fila hija y se informa |
| Documento borrado en MongoDB desde la corrida anterior | Su fila no se borra; se informa |

## Correcciones

Archivo YAML con lo que la empresa decide corregir. MongoDB no se toca: la corrección se aplica a una copia del documento en memoria y queda listada en el informe. El formato y los ejemplos están en `correcciones.py`. Escribe siempre el `_id` entre comillas.

## Copia de prueba local (datos inventados)

En `copia_prueba/` hay scripts que arman un MongoDB local con:

- datos base del equipo;
- el historial de demostración del fork (`seedShowcase`);
- 31 casos válidos y sucios, cada uno con su resultado esperado.

Solo corren contra `localhost`.

```bash
FORK_BACKEND=<ruta>/JupacaProyecta-PTC-2026/backend \
DB_URI=mongodb://127.0.0.1:27018/jupaca_copia \
CREDENCIALES_PRUEBA=<archivo fuera del repo> \
CASOS_PRUEBA=backend/migracion/informes/casos_prueba.json \
./copia_prueba/armar_copia.sh
```

```bash
python manage.py migrar_mongo --destino <base de prueba> --incluir-demo
```

```bash
python manage.py verificar_casos_prueba
```

`verificar_casos_prueba` compara el informe con el resultado esperado de cada caso.

## Copia de Atlas

1. En Atlas, crea un usuario de base de datos con el rol `read` sobre la base del sistema.
2. Saca el respaldo con ese usuario. La cadena de conexión va en una variable de entorno, no en el comando ni en el chat:

   ```bash
   mongodump --uri "$ATLAS_SOLO_LECTURA" --out <carpeta fuera del repo>
   ```

3. Restáuralo en el MongoDB local, con otro nombre de base:

   ```bash
   mongorestore --uri mongodb://127.0.0.1:27018 --nsFrom '<base>.*' --nsTo 'jupaca_atlas.*' <carpeta>
   ```

4. En `backend/.env`, apunta `MONGO_DB=jupaca_atlas` y `DATABASE_URL` a una base PostgreSQL vacía. Después ejecuta `migrate`, luego `migrar_mongo --simular` y por último la migración real.
5. Revisa el informe con la empresa y anota sus decisiones en `correcciones.yaml`. Repite hasta que el informe quede aceptado.
