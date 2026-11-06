# App `lab` · el LIMS dentro del backend Django

El laboratorio (ensayos a materiales y geotecnia) vive en el esquema `lab` de la misma base
central. Esta app es la que lo maneja desde Django.

## Por qué el esquema no lo generan las migraciones

El esquema del LIMS usa cosas que `makemigrations` no sabe escribir:

- llaves foráneas **compuestas** (`muestras` → `remisiones(id, proyecto_id)`), que garantizan que
  una muestra no se cuele en otro proyecto;
- **columnas calculadas** (`resistencia_kgcm2`, `resistencia_mpa`, `ganancia_pct`);
- **tipos enum** propios (`lab.estado_ensayo`, `lab.rol`...);
- **triggers** con las reglas del laboratorio y la auditoría;
- **funciones** y **vistas**.

Entonces: el DDL se ejecuta tal cual desde `lab/sql/0001_lims.sql` (la Parte 3 revisada) dentro
de `lab/migrations/0001_initial.py`, y los modelos son `managed = False`: Django consulta y
escribe con ellos, pero no genera su DDL.

## Cómo cambiar algo del esquema

1. Escribir una **migración nueva** con `RunSQL` y el `ALTER` correspondiente. No se edita
   `0001_lims.sql` ni `0001_initial.py`: lo ya aplicado no se cambia.
2. Si además cambian los modelos, poner en esa misma migración las operaciones de estado
   (`state_operations`) para que Django se entere, igual que hace la inicial.
3. Para rehacer la inicial desde cero (solo si todavía nadie la aplicó):
   `python manage.py makemigrations lab` y después
   `python scripts/envolver_migracion_lab.py lab/migrations/0001_initial.py`, que vuelve a
   envolver las operaciones en el `RunSQL`.

## Detalles que conviene saber

- **`db_table` con comillas.** `'lab"."ensayos'` es la forma de escribir `lab.ensayos` en
  Django. No es un error de tipeo.
- **Llaves foráneas sin `_id`.** En el LIMS algunas columnas de llave foránea se llaman
  `creado_por`, `movido_por`, `asignado_por`, `tipo_falla`... sin el sufijo `_id` que Django
  pone solo. Esos 12 campos llevan `db_column` explícito.
- **Quién está trabajando.** Los triggers leen la variable de sesión `lab.usuario_id`. La fija
  `lab/middleware.py` en cada petición. Para scripts y comandos:

  ```python
  from lab.middleware import usuario_lab

  with usuario_lab(usuario):
      ...

  # para corregir un ensayo ya aprobado hay que dar un motivo:
  with usuario_lab(usuario, motivo_correccion="se corrigió la carga mal digitada"):
      ...
  ```

  Sin esa variable los cambios pasan (para que funcionen migraciones y scripts), pero la
  auditoría queda sin autor y nadie puede aprobar resultados.
- **Dos juegos de roles.** Los cinco roles de `lab.usuarios_roles` (administrador, recepción,
  técnico, supervisor, consulta) los lee PostgreSQL en los triggers: son los que deciden quién
  aprueba. Los roles por departamento (`nucleo.RolDepartamento`, grupos de Django) deciden qué
  puede hacer cada quien en la aplicación. Son cosas distintas y conviven.
- **Las vistas son de solo lectura.** `VistaProgramacionEnsayos`, `VistaResultadosCompresion` y
  `VistaCurvaResistencia` levantan excepción si se intenta guardar o borrar.
- **Archivos.** Los campos `*_path` son `FileField` con el almacenamiento `lab_archivos`
  (Cloudinary, ver `config/settings/base.py`). La columna en la base sigue siendo `text` y
  guarda la ruta; por eso conservan su nombre original y llevan `max_length` alto.

## Lo que la base sigue cuidando por su cuenta

Aunque no se use RLS (Django se conecta como dueño de las tablas, así que no protegería nada),
estas reglas siguen vivas en los triggers:

- la fecha de ensayo sale del colado más la edad, si no se envía;
- la edad real se calcula al registrar la ejecución;
- el área y la resistencia requerida se copian de la muestra al ensayar;
- un espécimen se rompe una sola vez por método;
- solo un supervisor (o administrador) aprueba resultados;
- un ensayo aprobado no se corrige sin motivo;
- cada cambio de bidón o estante queda en el historial;
- todo queda en `lab.auditoria`, con el motivo y el usuario.
