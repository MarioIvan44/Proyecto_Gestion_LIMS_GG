# Contexto para continuar en otro chat · JUPACA PROYECTA (base central + Gestión GG + LIMS)

Pegá este archivo completo al inicio del chat nuevo. Al final está la lista de archivos que hay
que adjuntar y lo que falta por hacer.

---

## 1. Quién soy y qué estoy haciendo

Trabajo con mi equipo en los sistemas de una empresa de geotecnia y laboratorio de materiales
(JUPACA PROYECTA). Son tres sistemas que comparten empleados, clientes y proyectos:

- **base central / RRHH**: su base venía de MongoDB y se migró a PostgreSQL. La maneja un
  backend de **Django** (es la dueña del esquema: tablas `nucleo_*`, `rrhh_*`, `finanzas_*`,
  `lectura_*`).
- **Gestión GG** (geotecnia): tablas `gestion_*`. Hoy se crean **solo con SQL**, no con
  migraciones de Django.
- **LIMS** (laboratorio): esquema `lab`. Se empezó en Supabase pero **no tiene datos** ahí.

Estoy juntando todo en **una sola base PostgreSQL** para cargarla en pgAdmin 4.

**Es un proyecto serio de trabajo: no inventes datos, códigos, normas ni valores que no salgan
de mis archivos. Si algo no está claro, preguntame antes de ponerlo.**

**No subas nada a GitHub (ni commit ni push). Dejá los archivos en la carpeta y yo los subo.**

## 2. Decisiones ya tomadas por el equipo (no hay que volver a discutirlas)

- Los archivos (certificados, informes, fotos de remisiones) van a **Cloudinary**.
- El **LIMS se integra como app dentro del backend Django** de la base central.
- Los permisos se manejan **en Django, sin RLS** (Django se conecta como dueño de las tablas,
  así que RLS no protegería nada).
- **Cada departamento con sus propios roles y accesos.**
- Los proyectos son de toda la empresa: varias áreas trabajan sobre un mismo proyecto.
- El plazo del cliente se cuenta **desde el pago del anticipo**; 12 etapas; la cuadrilla no usa
  el sistema (registran oficina y laboratorio); alertas A1 a A14 sin A5.
- El **esquema `lab` se conserva tal cual** y los modelos de Django van con `managed = False`
  sobre esas tablas (para no perder triggers, columnas calculadas, llaves compuestas y vistas).
- Los contactos de cliente pasaron de `lab.contactos_cliente` a la central como
  `nucleo_contactocliente`.

## 3. Estado del repositorio

Carpeta: `C:\Users\alejandro salazar\Desktop\Proyecto_Gestion_LIMS_GG`
(GitHub: `MarioIvan44/Proyecto_Gestion_LIMS_GG`, rama `main`).

**Importante (corregido el 6-nov por la tarde):** el repositorio solo traía la configuración de
Django, pero las apps `nucleo`, `rrhh`, `finanzas`, `lectura` y `migracion` **sí existían**: están
en **Proyecto2-Geotecnia** (GitHub `CarlosMariommm/Proyecto2-Geotecnia`, commit `c9c5212`), y sus
migraciones generan exactamente la parte central de `base_total_jupaca.sql`. Ya se copiaron a este
repositorio (Proyecto2-Geotecnia no se tocó). La **única app que falta es `gestion`**.

En un chat anterior (6-nov-2026) ya se hizo y se probó esto:

```
backend/
  requirements.txt                  (nuevo: Django 6.1.3, psycopg, dj-database-url,
                                     python-decouple, bcrypt, cloudinary)
  config/settings/base.py           (modificado: + apps nucleo, rrhh, finanzas, migracion,
                                     lectura y lab, + middleware del LIMS, + STORAGES con Cloudinary)
  config/urls.py                    + api/lectura/ (como en Proyecto2-Geotecnia)
  nucleo/                           el ORIGINAL de Proyecto2-Geotecnia + cambios del 6-nov
    models.py                       ModeloBase/ModeloHijo (UUID v7) + Cliente con tipo_persona,
                                    nit y dui + Proyecto.ubicacion + ContactoCliente + RolDepartamento
    ids.py, signals.py, admin.py    del original (ids.py necesita pymongo por bson)
    hashers.py                      el original: recorta a 72 bytes y costo 10, como bcryptjs
    roles_departamentos.json        VACÍO a propósito: espera la lista de departamentos
    management/commands/cargar_roles.py
    migrations/0001_initial.py      la del original (mismo nombre y mismo SQL que la de antes)
    migrations/0002_ubicacion_tipo_persona_documento.py
    migrations/0003_contactocliente.py
    migrations/0004_roldepartamento.py
  rrhh/, finanzas/, lectura/, migracion/   copiadas tal cual de Proyecto2-Geotecnia (6-nov tarde)
  lab/                              (NUEVO: el LIMS)
    models.py                       26 tablas del esquema lab + 3 vistas, managed = False
    middleware.py                   fija lab.usuario_id por transacción (para los triggers) y
                                    deshace la petición si la vista falla (process_exception)
    storages.py                     almacenamiento de Cloudinary para los archivos del lab
    sql/0001_lims.sql               el DDL del esquema lab (= Parte 3 con 3 cambios)
    migrations/0001_initial.py      RunSQL(0001_lims.sql) + CreateModel en state_operations
    README.md                       cómo funciona y cómo cambiar el esquema
  sql/
    generar.sh                      (NUEVO) regenera pgAdminBase.sql desde las migraciones
    parche_gestion_gg_2026-11-06.sql  correlativo >999 y feriados 2027
  scripts/envolver_migracion_lab.py rearma la migración de lab si se vuelve a generar
PENDIENTES.md                       pendientes, supuestos y lo que quedó probado
```

### Cómo se probó (se puede repetir)

Se levantó PostgreSQL 16 y se compararon dos bases: una con `base_total_jupaca.sql` cargado y
otra con las migraciones de Django aplicadas. Resultado: **el esquema que generan las
migraciones de `nucleo` es idéntico al del SQL** (mismas columnas en el mismo orden, mismas
restricciones con los mismos nombres); la única diferencia es cómo PostgreSQL escribe los
`CHECK ... IN (...)`, que es solo de forma. El esquema `lab` también salió idéntico a la Parte 3,
salvo `lab.contactos_cliente`, que es la tabla que se movió a `nucleo`.

Además se corrieron 30 comprobaciones usando los modelos de Django contra la base: los triggers
calculan la fecha de ensayo (colado + edad) y la edad real, copian el área y la resistencia
requerida; las columnas calculadas dan el valor correcto (213.54 kg/cm² para 380 kN sobre
18145.84 mm²) y no se pueden escribir; solo el supervisor aprueba; corregir algo aprobado exige
motivo; la auditoría guarda el motivo y el usuario; las vistas traen el cliente de la central.

Comandos útiles (con el entorno virtual activado, desde `backend/`):

```bash
python manage.py check
python manage.py makemigrations --check --dry-run   # debe decir "No changes detected"
python manage.py migrate
python manage.py cargar_roles nucleo/roles_departamentos.json --simular
bash sql/generar.sh                                 # OJO: ver el aviso del punto 5
```

## 4. Detalles del código que conviene saber antes de tocarlo

1. **`db_table` con comillas.** En `lab/models.py` las tablas se escriben `'lab"."ensayos'`.
   Es la forma de referirse a `lab.ensayos` en Django, **no es un error de tipeo**.
2. **12 llaves foráneas sin sufijo `_id`.** En el esquema `lab` hay columnas de llave foránea
   que se llaman `creado_por`, `movido_por`, `asignado_por`, `revisado_por`, `aprobado_por`,
   `elaborado_por`, `subido_por`, `importado_por`, `recibido_lab_por`,
   `entregado_por_empleado`, `tipo_falla`. Django les pondría `_id`, así que esos campos
   llevan `db_column` explícito. **Si se agregan modelos nuevos, revisar esto.**
3. **El esquema `lab` no lo generan las migraciones.** El DDL se ejecuta tal cual desde
   `lab/sql/0001_lims.sql` con `RunSQL`, y los `CreateModel` van dentro de `state_operations`
   (solo actualizan el estado, no tocan la base). Para cambiar el esquema: **una migración
   nueva** con `RunSQL` y el `ALTER`; no se editan `0001_lims.sql` ni `0001_initial.py`.
4. **Quién trabaja, para los triggers.** Los triggers del LIMS leen la variable de sesión
   `lab.usuario_id`. La fija `lab/middleware.py` en cada petición. En scripts y comandos:
   ```python
   from lab.middleware import usuario_lab
   with usuario_lab(usuario):                     # auditoría con autor
       ...
   with usuario_lab(usuario, motivo_correccion="..."):   # para corregir algo ya aprobado
       ...
   ```
   Sin esa variable los cambios pasan (para migraciones y scripts) pero la auditoría queda sin
   autor y nadie puede aprobar resultados.
5. **Dos juegos de roles que conviven.** Los cinco roles de `lab.usuarios_roles`
   (administrador, recepción, técnico, supervisor, consulta) los leen los triggers de
   PostgreSQL: deciden quién aprueba. Los roles por departamento
   (`nucleo.RolDepartamento`, que son grupos de Django) deciden qué puede hacer cada quien en
   la aplicación. Son cosas distintas.
6. **Columnas calculadas.** `resistencia_kgcm2`, `resistencia_mpa` y `ganancia_pct` son
   `generated always as ... stored` en PostgreSQL. En Django están como `GeneratedField` con la
   fórmula copiada del `.sql`; **la que manda es la del `.sql`**. Si allá cambia una fórmula,
   hay que cambiarla también en el modelo.
7. **`on_delete`** en `nucleo`: se conservan las decisiones del original (`SET_NULL` y
   `CASCADE`). En `lab` se respetó lo que ya decía el SQL (`on delete cascade` donde lo tenía).
8. **Mismas apps en dos repositorios.** Este repositorio y Proyecto2-Geotecnia tienen `nucleo`,
   `rrhh`, `finanzas`, `lectura` y `migracion` con los mismos nombres. Solo uno de los dos debe
   correr `migrate` en la base real (ver PENDIENTES.md, punto 9).
9. **`actualizado_en`** lo pone `ModeloBase.save()` en Python; la base no tiene triggers para eso
   en las tablas centrales (el `triggers.sql` que mencionan algunos comentarios no existe).

## 5. Advertencia sobre `sql/generar.sh`

`generar.sh` **no venía en el repositorio**; se escribió para poder corregir el
`SET transaction_timeout` (solo existe en PostgreSQL 17+ y rompe la carga en 15/16). Crea una
base temporal, le corre las migraciones, saca el esquema con `pg_dump` y la borra.

**Mientras falte la app `gestion`, el `pgAdminBase.sql` que genera es PARCIAL** (60 tablas: todo
menos `gestion_*`). El script lo avisa al terminar y guarda
una copia del anterior como `.anterior`. **No sustituir el archivo bueno con uno parcial.**

Si aparece el `generar.sh` original del equipo, comparar los dos y quedarse con uno solo.

---

## 6. Archivos que hay que adjuntar en el chat nuevo

Sin estos no se puede trabajar en serio (son la referencia del esquema):

1. `base_total_jupaca.sql` — la base completa: central + Gestión GG + LIMS.
2. `cambios_cliente_proyecto.sql` — ubicación del proyecto y tipo_persona + NIT/DUI.
3. `parte3_lims_sobre_central.sql` — el LIMS apuntando a la base central.
4. `modelos_django_cambios.py` — los fragmentos de modelos que propuso el equipo.
5. `PENDIENTES.md` — está en la raíz de la carpeta del repositorio.

Y, si va a tocar código, también la carpeta `Proyecto_Gestion_LIMS_GG` (o al menos
`backend/nucleo/models.py`, `backend/lab/models.py` y `backend/config/settings/base.py`).

## 7. Lo que falta hacer

### Lo que depende de mí (tengo que conseguir la información)

| # | Qué falta | Para qué sirve |
|---|---|---|
| 0 | **Quién corre las migraciones en la base real** | Este repositorio o Proyecto2-Geotecnia, pero no los dos (comparten `django_migrations`). |
| 1 | **Lista de departamentos y sus roles** | Es lo único que falta para terminar los permisos por departamento. La estructura ya está hecha y probada: solo hay que llenar `backend/nucleo/roles_departamentos.json` (tiene un ejemplo comentado adentro) y correr `python manage.py cargar_roles nucleo/roles_departamentos.json`. |
| 2 | **Cuenta de Cloudinary** | Sin `CLOUDINARY_URL` en `backend/.env`, los archivos del laboratorio se guardan en `backend/media/lab/`. Cuando la ponga, empiezan a subir a Cloudinary sin cambiar código. |
| 3 | **Etapa `cancelado` de Gestión GG** | Hay que preguntarle al equipo cómo funciona (ver abajo). |
| 4 | **Confirmar los feriados 2027** | Se cargaron suponiendo las mismas fechas que 2026. |
| 5 | **Qué guarda `nucleo_cliente.ruc`** | Ahora hay `ruc` (obligatorio y único) más `nit` y `dui` nuevos. Si `ruc` ya traía el NIT, quedan dos columnas con lo mismo. |
| 6 | **La llave de la ubicación en `datos_extra`** | Para recuperar la ubicación de los proyectos viejos. La consulta para averiguarlo está en `cambios_cliente_proyecto.sql`. |
| 7 | **Significado de los códigos de espécimen** | CC, CM, PG, BRQ, V. |

### Errores de Gestión GG

- **Correlativo mayor a 999: YA ESTÁ CORREGIDO** en
  `backend/sql/parche_gestion_gg_2026-11-06.sql`. El `CHECK` usaba `lpad(...,3,'0')`, que corta
  a la derecha: con correlativo 1000 rechazaba el código correcto `JP-GG-2026-1000` y aceptaba
  `JP-GG-2026-100`, que choca con el correlativo 100. Probado con 5, 999, 1000 y 12345.
  **Falta:** hacer el mismo cambio en el modelo de Django de `gestion` cuando esa app exista;
  si no, la siguiente migración vuelve a poner el `CHECK` viejo.
- **Feriados 2027: YA ESTÁN** en el mismo parche (14 fechas, todas con `es_supuesto = true`).
- **`SET transaction_timeout`: YA ESTÁ** resuelto dentro de `sql/generar.sh` (ver punto 5).
- **Etapa `cancelado`: PENDIENTE A PROPÓSITO.** `gestion_expediente.etapa` permite
  `'cancelado'`, pero `gestion_etapaconfig` solo tiene las 12 etapas del proceso, y
  `gestion_eventoetapa.etapa` tiene llave foránea a `gestion_etapaconfig`. Resultado: **al
  cancelar un expediente, la base rechaza el registro del evento.** Está reproducido. Las dos
  salidas posibles son: (a) agregar `cancelado` como etapa 13 (hay que definir el grupo
  responsable), o (b) que al cancelar no se registre evento y la etapa quede solo en el
  expediente. **No lo toqués todavía: primero tengo que preguntarle al equipo cómo va eso,
  porque el proceso va etapa por etapa y no sé dónde encaja cancelar.**

### Lo grande que sigue

Reconstruir como app de Django la parte que hoy solo existe en SQL: **`gestion`** (Gestión GG;
sus correcciones hay que hacerlas dos veces mientras no exista). `rrhh`, `finanzas` y `lectura`
**ya no hay que reconstruirlas**: se trajeron de Proyecto2-Geotecnia. El método que funcionó fue:
escribir los modelos a partir del DDL de `base_total_jupaca.sql` (heredando de `ModeloBase` /
`ModeloHijo` de `nucleo`), generar la migración, aplicarla en una base vacía y **comparar el
esquema resultante contra el del SQL** hasta que no haya diferencias. Ojo con `gestion`: tiene
llaves foráneas `DEFERRABLE INITIALLY DEFERRED`, muchos `CHECK` con nombre propio e índices
parciales (`WHERE ...`), así que los nombres de las restricciones tienen que coincidir.

Cuando exista `gestion`, `sql/generar.sh` ya podrá generar el `pgAdminBase.sql` completo.


## Sistema de RRHH (JupacaProyecta-PTC-2026) y base de producción · 6-nov-2026

- **El backend de RRHH (Node) ya está pasado a PostgreSQL** desde el 3-nov (commit "Adaptar el backend
  a PostgreSQL"). Lee y escribe directo en `nucleo_*`, `rrhh_*` y `finanzas_*` y nunca crea tablas.
  Se probó levantándolo contra la base integrada de este repositorio: las 154 columnas que usa existen,
  inicia sesión con contraseñas guardadas por Django y funcionan crear departamento, cliente, empleado,
  proyecto, contrato, horas extra y planilla. Django lee lo que guarda Node y al revés.
- **Decisión:** RRHH se queda como está; no hay peticiones entre backends porque comparten la base.
  Para algo nuevo: (1) columna o tabla y migración en Django; (2) declarar el campo en `src/models` de Node.
- **Ya agregado en RRHH** (sin commit, en su carpeta): `personType` / `NIT` / `DUI` en clientes
  (backend, web y app móvil), con las mismas reglas que `cliente_documento_segun_tipo`.
- **El sistema publicado en Render todavía usa MongoDB.** El código de `main` ya es el de PostgreSQL:
  si Render lo publica sin `DATABASE_URL`, el sistema se cae. Revisar de qué repositorio y rama publica.
- **Base de producción: Supabase (decidido).** Plan Pro para producción (el gratis se pausa tras una
  semana sin uso y no tiene respaldos). **Apagar la Data API** de Supabase: los permisos van en Django sin
  RLS y, con la Data API encendida, la clave pública `anon` podría leer y escribir las tablas de `public`.
  Para Django usar la conexión directa o el *session pooler*.
- **Pasos pendientes del cambio:** crear el proyecto en Supabase → `python manage.py migrate` →
  `python manage.py migrar_mongo --simular` (ensayo) → día del cambio: `migrar_mongo --destino <base>` y
  poner `DATABASE_URL` en Render. MongoDB no se toca, así que se puede volver atrás.
