# Pendientes y supuestos · 6 de noviembre de 2026 (revisado la tarde del 6-nov)

Lo que quedó sin resolver y lo que se decidió suponiendo algo. Nada de esto se inventó callado:
cada supuesto está marcado en el código con la palabra SUPUESTO o PENDIENTE.

## 1. Preguntar a la empresa o al equipo

| # | Qué falta | Por qué importa | Dónde |
|---|---|---|---|
| 1 | **Etapa `cancelado` en Gestión GG** | `gestion_expediente.etapa` permite `'cancelado'`, pero `gestion_etapaconfig` solo tiene las 12 etapas del proceso. `gestion_eventoetapa.etapa` tiene llave foránea a `gestion_etapaconfig`, así que **al cancelar un expediente no se puede registrar el evento**: la base lo rechaza. Hay que decidir si `cancelado` entra como etapa 13 (con qué grupo responsable) o si al cancelar no se registra evento. Se dejó **sin tocar** a propósito. | `base_total_jupaca.sql`, tablas `gestion_etapaconfig` / `gestion_eventoetapa` |
| 2 | **Lista de departamentos y sus roles** | Es lo que falta para terminar los permisos por departamento. La estructura ya está hecha y probada; solo falta llenar la lista. | `backend/nucleo/roles_departamentos.json` (vacío a propósito) |
| 3 | **Cuenta de Cloudinary** | Sin `CLOUDINARY_URL` los archivos del laboratorio se guardan en el disco (`backend/media/lab/`). En cuanto esté la cuenta, se pone en `backend/.env` y empiezan a subir a Cloudinary sin cambiar código. | `backend/config/settings/base.py` |
| 4 | **Feriados 2027** | Se cargaron con las mismas fechas fijas que 2026 y la Semana Santa calculada (Pascua: domingo 28 de marzo de 2027), todos con `es_supuesto = true`. Hay que confirmarlos. | `backend/sql/parche_gestion_gg_2026-11-06.sql` |
| 5 | **Qué guarda `nucleo_cliente.ruc`** | Ahora hay `ruc` (obligatorio y único), más `nit` y `dui` nuevos. Si `ruc` ya venía guardando el NIT, quedan dos columnas con lo mismo. Viene de los archivos del equipo, que ya lo marcaban como pendiente. | `backend/nucleo/models.py`, clase `Cliente` |
| 6 | **Llave de la ubicación en `datos_extra`** | Para recuperar la ubicación de los proyectos viejos hay que saber con qué nombre quedó guardada en `datos_extra`. La consulta para averiguarlo está en el archivo del equipo. | `cambios_cliente_proyecto.sql`, punto 1 |
| 7 | **Códigos de tipo de espécimen** | CC, CM, PG, BRQ, V: el significado sigue por confirmar (ya venía así en la Parte 3). | `backend/lab/sql/0001_lims.sql` |
| 8 | ~~Contraseñas bcrypt del backend Node~~ **RESUELTO** | La app `migracion` (traída de Proyecto2-Geotecnia) ya guarda los hashes de Node con el prefijo `bcrypt$` (`migracion/motor.py`, método `password`), y el hasher original recorta a 72 bytes y usa costo 10, igual que bcryptjs. | `backend/migracion/motor.py`, `backend/nucleo/hashers.py` |
| 9 | **Quién corre las migraciones en la base real** | Este repositorio y Proyecto2-Geotecnia tienen las mismas apps (`nucleo`, `rrhh`, `finanzas`, `lectura`, `migracion`) con el mismo nombre. Si los dos corren `migrate` contra la misma base, comparten la tabla `django_migrations` y en cuanto uno agregue una migración que el otro no tenga, se desincronizan. Hay que acordar que **solo uno** sea el dueño del esquema (por lo decidido, este) y que el otro deje de migrar o se actualice desde aquí. | — |
| 10 | **Borrado de clientes con contactos** | En la Parte 3, `lab.contactos_cliente` tenía `on delete cascade` en la base. En `nucleo_contactocliente` el borrado en cascada lo hace Django, no la base: desde pgAdmin, borrar un cliente que tenga contactos da error. Además las columnas pasaron de `text` a `varchar` con los largos que ya usa la base central (nombre 255, cargo 150, teléfono 30, correo 254). Confirmar que así está bien. | `backend/nucleo/models.py`, clase `ContactoCliente` |

## 2. Lo que falta del propio repositorio

**Corrección del 6-nov por la tarde:** las apps `rrhh`, `finanzas`, `lectura` y `migracion` **sí
existían**: están en el repositorio Proyecto2-Geotecnia (GitHub `CarlosMariommm/Proyecto2-Geotecnia`,
commit `c9c5212`). Sus migraciones generan exactamente la parte central de `base_total_jupaca.sql`
(32 tablas, sin una diferencia). Se copiaron aquí tal cual (Proyecto2-Geotecnia no se tocó).

También se cambió el `nucleo` que se había reconstruido desde el SQL por **el original** de
Proyecto2-Geotecnia, con los cambios del 6-nov encima (ubicación, tipo de persona con NIT/DUI,
contactos de cliente y roles por departamento). El reconstruido generaba la misma estructura, pero
se comportaba distinto:

- `actualizado_en` nunca cambiaba al editar (dependía de un `triggers.sql` que no existe).
- Los id nuevos eran UUID versión 4; el original usa versión 7, que se ordena por fecha como los
  ObjectId de MongoDB (el backend Node ordena por id).
- El hasher no recortaba las contraseñas a 72 bytes (bcrypt 5 da error con contraseñas largas) y
  usaba otro costo.
- `rrhh`, `finanzas` y `lectura` importan `ModeloBase`, `ModeloHijo`, `MONTO` y `HORAS` del
  original; con el reconstruido no arrancaban.

Las migraciones `nucleo` 0001 a 0004 conservan **los mismos nombres** y generan **el mismo SQL** que
las anteriores (comprobado con `sqlmigrate`), así que una base donde ya se hayan aplicado no se
desincroniza: se probó y solo aplica las 4 migraciones de las apps nuevas.

Lo que sigue faltando:

- La app **`gestion`** (Gestión GG). Sus tablas siguen creándose solo con SQL. Por eso
  `backend/sql/generar.sh` todavía genera un `pgAdminBase.sql` **parcial** (60 tablas: todo menos
  `gestion_*`); el script lo avisa al terminar y guarda copia del anterior como `.anterior`.
- La corrección del correlativo va en un parche `.sql` y además hay que hacerla en el modelo de
  `gestion` cuando esa app exista (si no, la siguiente migración vuelve a poner el CHECK viejo).

## 3. Decisiones que tomé y conviene revisar

1. ~~`on_delete=PROTECT` en `nucleo`~~ Ya no aplica: con el `nucleo` original vuelven sus
   decisiones (`SET_NULL` y `CASCADE`). En `lab` se respetó lo que ya decía el SQL.
2. **Contactos de cliente en `nucleo`**, no en `lab`: la tabla `lab.contactos_cliente` de la
   Parte 3 ahora es `nucleo_contactocliente`, como estaba previsto en el comentario "si se decide
   llevar esta tabla a Django". El campo viejo `nucleo_cliente.contacto` (un texto) **no se
   borró**, para no perder lo que ya esté escrito ahí. Queda ver si se migra y se elimina.
3. **El esquema `lab` se conserva tal cual** y los modelos de Django son `managed = False`. Así
   se mantienen los triggers, las columnas calculadas, las llaves foráneas compuestas y las
   vistas. El DDL vive en `backend/lab/sql/0001_lims.sql`, que es la Parte 3 con tres cambios
   anotados en su cabecera.
4. **Archivos del laboratorio en un almacenamiento aparte** del que usa `lectura`, porque las
   fotos de `lectura` son datos de clientes y no se publican.
5. **`generar.sh` es nuevo** (no venía en ningún repositorio; Proyecto2-Geotecnia tampoco lo
   tiene). Si aparece el original, comparar y quedarse con uno solo.
6. **El middleware del LIMS deshace la petición si la vista falla.** Antes, si una vista guardaba
   algo y después lanzaba un error que no fuera de la base, Django devolvía 500 pero el cambio
   se quedaba guardado. Se agregó `process_exception` en `lab/middleware.py` (probado).

## 4. Lo que quedó probado

Todo esto se corrió de verdad contra PostgreSQL 16, en bases desechables:

- `base_total_jupaca.sql` carga completo, sin errores (87 tablas entre `public` y `lab`).
- El parche de Gestión GG: correlativo 5 → `005`, 999, 1000 y 12345 pasan; los códigos mal
  formados (`JP-GG-2026-100` con correlativo 1000, `JP-GG-2026-5` con correlativo 5) se
  rechazan. 14 feriados de 2026 y 14 de 2027.
- Las migraciones de `nucleo` producen **exactamente** el mismo esquema que el SQL del equipo
  (mismas columnas, en el mismo orden, mismas restricciones con los mismos nombres); la única
  diferencia es cómo PostgreSQL escribe los `CHECK ... IN (...)`, que es solo de forma.
- El esquema `lab` que crea la migración es idéntico al de la Parte 3, salvo
  `lab.contactos_cliente`, que es justo la tabla que se movió a `nucleo`.
- 30 comprobaciones con los modelos de Django contra la base: los triggers calculan la fecha de
  ensayo y la edad real, el área y la resistencia requerida; las columnas calculadas devuelven
  los valores correctos (213.54 kg/cm² para 380 kN sobre 18145.84 mm²) y no se pueden escribir;
  solo el supervisor aprueba; corregir algo aprobado exige motivo; la auditoría guarda el motivo
  y el usuario; las vistas traen el cliente de la base central.
- `cargar_roles` carga, actualiza sin duplicar, avisa de permisos que no existen, no borra roles
  que ya no estén en la lista y con `--simular` no guarda nada.
- `generar.sh` corre completo y lo que genera vuelve a cargar en una base vacía sin errores
  (46 tablas, 3 vistas, 20 triggers, 15 funciones), y borra su base temporal.

### Revisión de la tarde del 6-nov (también contra PostgreSQL 16)

- `parte3_lims_sobre_central.sql` es idéntica a la Parte 3 de `base_total_jupaca.sql`, y
  `lab/sql/0001_lims.sql` es esa misma Parte 3 menos los tres cambios anotados en su cabecera.
  Funciones y vistas de `lab` idénticas (solo cambia el fin de línea: el `.sql` del equipo viene
  con fines de línea de Windows).
- `cambios_cliente_proyecto.sql` deja lo mismo que la migración `nucleo.0002`, con los mismos
  nombres de restricciones. Diferencias de forma: el orden de las columnas nuevas y dos índices
  `_like` (para búsquedas con `LIKE` en `nit` y `dui`) que Django crea y el `.sql` a mano no.
- Con todo integrado: `check` sin problemas, `makemigrations --check` sin cambios, base vacía
  migrada = `base_total_jupaca.sql` + `cambios_cliente_proyecto.sql` + las dos tablas nuevas
  (`nucleo_contactocliente`, `nucleo_roldepartamento`) + el esquema `lab`, sin contar `gestion_*`.
  Las 55 pruebas que trae Proyecto2-Geotecnia (`lectura`, `migracion`) pasan.
- `actualizado_en` se actualiza al editar; el middleware deshace lo guardado si la vista falla.


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


## Parte 4 de RRHH (viáticos, horas extras, préstamos) · revisada el 6-nov-2026

- Carga sin errores. Quedó incluida en `backend/sql/base_total_jupaca_completa.sql` (un solo archivo con
  todo; se probó cargándolo en una base vacía y Django lo reconoce como ya migrado).
- **Falta pasarla a la app `rrhh` de Django** (modelos + migración, con `BtreeGistExtension` para el
  EXCLUDE). Mientras sea SQL, Django no conoce esas tablas ni columnas. Los nombres propios de las FK
  (`tarifa_he_departamento_fk`, etc.) no se pueden copiar en Django: quedarán con los nombres que él genere.
- **Choca con el backend de RRHH (Node), que es el que está en uso:**
  - La Parte 4 dice que `allowances` del frontend = viáticos (`total_viaticos`) y `extraAllowances` =
    `viatico_extra`, pero Node hoy guarda `allowances` en `bonificaciones` y `extraAllowances` en
    `bonificaciones_extra`. Hay que decidir qué son (¿bonos o viáticos?) antes de migrar datos.
  - El líquido que calcula Node (`payrollFormulas.js`) es neto − renta − anticipo − otros descuentos:
    **no resta el préstamo**. Si se llena `prestamo`, el líquido sale mal hasta actualizar Node.
  - Node sigue usando `rrhh_horaextra` (pantalla de horas extra). La Parte 4 dice que "RRHH ya no la usa".
  - Menciona `payrollLegacyStore.js` y `BACKEND_STORES_EXTRAS`, que no existen en el repositorio
    JupacaProyecta-PTC-2026: preguntar dónde está ese frontend.
- Detalles: `rrhh_comprobante.fecha_emision DEFAULT CURRENT_DATE` usa la fecha del servidor (en UTC, después
  de las 6 p. m. de El Salvador ya es el día siguiente): que el backend la mande. La vista
  `rrhh_v_saldo_prestamo` cuenta cuotas de planillas en borrador: ¿solo aprobadas o pagadas?
  El comentario "actualizado_en lo mantiene ... triggers.sql" no aplica: ese archivo no existe.
