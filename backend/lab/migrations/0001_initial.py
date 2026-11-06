"""
Crea el esquema `lab` (tablas, tipos, funciones, triggers y vistas del LIMS).

El DDL se ejecuta tal cual desde lab/sql/0001_lims.sql, que es la Parte 3 revisada
(parte3_lims_sobre_central.sql) con los tres cambios anotados en su cabecera. Se hace así, y no
con CreateModel, porque el esquema del LIMS usa cosas que las migraciones de Django no generan:
llaves foráneas compuestas, columnas calculadas (generated always as ... stored), tipos enum
propios, triggers de negocio, funciones y vistas.

Los modelos de lab/models.py son `managed = False`: Django los usa para consultar y escribir,
pero no emite DDL para ellos. Por eso las operaciones CreateModel van dentro de
`state_operations`: así el estado de las migraciones sabe que esas tablas existen y
`makemigrations` no vuelve a proponerlas. Ninguna de ellas toca la base.

Un cambio posterior en el esquema lab se hace con una migración NUEVA (RunSQL con el ALTER, y
state_operations si además cambian los modelos); este archivo y su .sql no se editan.

Las operaciones CreateModel de abajo las generó `makemigrations lab` desde los modelos; este
archivo se vuelve a armar con scripts/envolver_migracion_lab.py.
"""

from pathlib import Path

import django.contrib.postgres.fields
import django.db.models.deletion
import django.db.models.expressions
import django.db.models.functions.comparison
import django.db.models.functions.datetime
import django.db.models.functions.math
import lab.storages
import uuid
from django.db import migrations, models

# El esquema lab se crea con este archivo .sql, que es la referencia del diseño del LIMS.
SQL = (Path(__file__).resolve().parent.parent / "sql" / "0001_lims.sql").read_text(encoding="utf-8")

# Al revertir la migración se borra el esquema completo del laboratorio, con sus datos.
SQL_REVERSA = "drop schema if exists lab cascade;"


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        # Las tablas lab.* tienen llaves foráneas a nucleo_cliente / nucleo_proyecto /
        # nucleo_empleado, así que la base central va primero.
        ("nucleo", "0003_contactocliente"),
    ]

    operations = [
        migrations.RunSQL(
            sql=SQL,
            reverse_sql=SQL_REVERSA,
            state_operations=[
                migrations.CreateModel(
                    name="Adjunto",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        (
                            "entidad",
                            models.TextField(
                                choices=[
                                    ("remision", "Remisión"),
                                    ("muestra", "Muestra"),
                                    ("especimen", "Espécimen"),
                                    ("ensayo", "Ensayo"),
                                    ("informe", "Informe"),
                                    ("equipo", "Equipo"),
                                ]
                            ),
                        ),
                        ("entidad_id", models.UUIDField()),
                        (
                            "storage_path",
                            models.FileField(
                                max_length=1000,
                                storage=lab.storages.almacenamiento_lab,
                                upload_to="lab/adjuntos/",
                            ),
                        ),
                        ("nombre_original", models.TextField(blank=True, null=True)),
                        ("mime", models.TextField(blank=True, null=True)),
                        ("tamano_bytes", models.BigIntegerField(blank=True, null=True)),
                        (
                            "subido_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "db_table": 'lab"."adjuntos',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Area",
                    fields=[
                        ("id", models.SmallAutoField(primary_key=True, serialize=False)),
                        ("nombre", models.TextField(unique=True)),
                    ],
                    options={
                        "verbose_name": "área",
                        "db_table": 'lab"."areas',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Auditoria",
                    fields=[
                        ("id", models.BigAutoField(primary_key=True, serialize=False)),
                        ("tabla", models.TextField()),
                        ("registro_id", models.TextField(blank=True, null=True)),
                        ("accion", models.TextField()),
                        ("antes", models.JSONField(blank=True, null=True)),
                        ("despues", models.JSONField(blank=True, null=True)),
                        ("motivo", models.TextField(blank=True, null=True)),
                        ("usuario_auth_id", models.UUIDField(blank=True, null=True)),
                        (
                            "ocurrido_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "verbose_name": "auditoría",
                        "verbose_name_plural": "auditoría",
                        "db_table": 'lab"."auditoria',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Calibracion",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        ("fecha", models.DateField()),
                        ("vence", models.DateField(blank=True, null=True)),
                        ("entidad", models.TextField(blank=True, null=True)),
                        (
                            "certificado_path",
                            models.FileField(
                                blank=True,
                                max_length=1000,
                                null=True,
                                storage=lab.storages.almacenamiento_lab,
                                upload_to="lab/calibraciones/",
                            ),
                        ),
                        ("observaciones", models.TextField(blank=True, null=True)),
                    ],
                    options={
                        "verbose_name": "calibración",
                        "verbose_name_plural": "calibraciones",
                        "db_table": 'lab"."calibraciones',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="CategoriaMaterial",
                    fields=[
                        ("id", models.SmallAutoField(primary_key=True, serialize=False)),
                        ("nombre", models.TextField(unique=True)),
                        ("activo", models.BooleanField(default=True)),
                    ],
                    options={
                        "verbose_name": "categoría de material",
                        "verbose_name_plural": "categorías de material",
                        "db_table": 'lab"."categorias_material',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Ensayo",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        (
                            "fecha_programada",
                            models.DateField(
                                blank=True,
                                help_text="Si se deja vacía la toma de la fecha programada del espécimen.",
                            ),
                        ),
                        ("ejecutado_en", models.DateTimeField(blank=True, null=True)),
                        (
                            "edad_real_dias",
                            models.SmallIntegerField(
                                blank=True,
                                help_text="La calcula la base al registrar ejecutado_en.",
                                null=True,
                            ),
                        ),
                        (
                            "estado",
                            models.TextField(
                                choices=[
                                    ("pendiente", "Pendiente"),
                                    ("en_proceso", "En proceso"),
                                    ("completado", "Completado"),
                                    ("en_revision", "En revisión"),
                                    ("aprobado", "Aprobado"),
                                ],
                                default="pendiente",
                            ),
                        ),
                        (
                            "origen",
                            models.TextField(
                                choices=[("manual", "Manual"), ("importacion", "Importación")],
                                default="manual",
                            ),
                        ),
                        ("revisado_en", models.DateTimeField(blank=True, null=True)),
                        ("aprobado_en", models.DateTimeField(blank=True, null=True)),
                        ("observaciones", models.TextField(blank=True, null=True)),
                        (
                            "creado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                        (
                            "actualizado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "db_table": 'lab"."ensayos',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Equipo",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        ("codigo", models.TextField(unique=True)),
                        (
                            "nombre",
                            models.TextField(
                                help_text='Por ejemplo "Prensa FORNEY VFD Automatic".'
                            ),
                        ),
                        ("marca", models.TextField(blank=True, null=True)),
                        ("modelo", models.TextField(blank=True, null=True)),
                        ("serie", models.TextField(blank=True, null=True)),
                        ("tipo", models.TextField(blank=True, null=True)),
                        ("activo", models.BooleanField(default=True)),
                        (
                            "creado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "db_table": 'lab"."equipos',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Especimen",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        (
                            "numero",
                            models.TextField(
                                help_text='Número asignado en campo, por ejemplo "769".'
                            ),
                        ),
                        ("edad_programada_dias", models.SmallIntegerField()),
                        (
                            "fecha_ensayo_programada",
                            models.DateField(
                                blank=True,
                                help_text="Si se deja vacía la calcula la base: colado + edad.",
                            ),
                        ),
                        (
                            "peso_g",
                            models.DecimalField(
                                blank=True, decimal_places=2, max_digits=9, null=True
                            ),
                        ),
                        (
                            "diametro_1_mm",
                            models.DecimalField(
                                blank=True, decimal_places=2, max_digits=7, null=True
                            ),
                        ),
                        (
                            "diametro_2_mm",
                            models.DecimalField(
                                blank=True, decimal_places=2, max_digits=7, null=True
                            ),
                        ),
                        (
                            "altura_1_mm",
                            models.DecimalField(
                                blank=True, decimal_places=2, max_digits=7, null=True
                            ),
                        ),
                        (
                            "altura_2_mm",
                            models.DecimalField(
                                blank=True, decimal_places=2, max_digits=7, null=True
                            ),
                        ),
                        (
                            "largo_mm",
                            models.DecimalField(
                                blank=True,
                                decimal_places=2,
                                help_text="Cubos y bloques.",
                                max_digits=7,
                                null=True,
                            ),
                        ),
                        (
                            "ancho_mm",
                            models.DecimalField(
                                blank=True,
                                decimal_places=2,
                                help_text="Cubos y bloques.",
                                max_digits=7,
                                null=True,
                            ),
                        ),
                        (
                            "estado",
                            models.TextField(
                                choices=[
                                    ("recibido", "Recibido"),
                                    ("almacenado", "Almacenado"),
                                    ("ensayado", "Ensayado"),
                                ],
                                default="recibido",
                            ),
                        ),
                        ("observaciones", models.TextField(blank=True, null=True)),
                        (
                            "creado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                        (
                            "actualizado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "verbose_name": "espécimen",
                        "verbose_name_plural": "especímenes",
                        "db_table": 'lab"."especimenes',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Importacion",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        (
                            "archivo_path",
                            models.FileField(
                                max_length=1000,
                                storage=lab.storages.almacenamiento_lab,
                                upload_to="lab/importaciones/",
                            ),
                        ),
                        (
                            "archivo_sha256",
                            models.TextField(
                                help_text="Evita importar dos veces el mismo archivo.",
                                unique=True,
                            ),
                        ),
                        (
                            "estado",
                            models.TextField(
                                choices=[
                                    ("cargado", "Cargado"),
                                    ("validado", "Validado"),
                                    ("con_errores", "Con errores"),
                                    ("aplicado", "Aplicado"),
                                    ("descartado", "Descartado"),
                                ],
                                default="cargado",
                            ),
                        ),
                        ("filas_total", models.IntegerField(blank=True, null=True)),
                        ("filas_validas", models.IntegerField(blank=True, null=True)),
                        (
                            "importado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                        ("notas", models.TextField(blank=True, null=True)),
                    ],
                    options={
                        "verbose_name": "importación",
                        "verbose_name_plural": "importaciones",
                        "db_table": 'lab"."importaciones',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="ImportacionFila",
                    fields=[
                        ("id", models.BigAutoField(primary_key=True, serialize=False)),
                        ("numero_fila", models.IntegerField()),
                        (
                            "datos",
                            models.JSONField(
                                help_text="La fila cruda tal como venía en el CSV."
                            ),
                        ),
                        (
                            "estado",
                            models.TextField(
                                choices=[
                                    ("pendiente", "Pendiente"),
                                    ("ok", "OK"),
                                    ("error", "Error"),
                                    ("duplicado", "Duplicado"),
                                    ("aplicada", "Aplicada"),
                                ],
                                default="pendiente",
                            ),
                        ),
                        (
                            "errores",
                            django.contrib.postgres.fields.ArrayField(
                                base_field=models.TextField(), blank=True, null=True
                            ),
                        ),
                    ],
                    options={
                        "verbose_name": "fila de importación",
                        "verbose_name_plural": "filas de importación",
                        "db_table": 'lab"."importacion_filas',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Informe",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        ("codigo", models.TextField(blank=True, null=True, unique=True)),
                        (
                            "tipo",
                            models.TextField(
                                choices=[("diario", "Diario"), ("mensual", "Mensual")]
                            ),
                        ),
                        ("fecha_desde", models.DateField()),
                        ("fecha_hasta", models.DateField()),
                        ("conclusiones", models.TextField(blank=True, null=True)),
                        ("recomendaciones", models.TextField(blank=True, null=True)),
                        (
                            "estado",
                            models.TextField(
                                choices=[
                                    ("borrador", "Borrador"),
                                    ("emitido", "Emitido"),
                                    ("anulado", "Anulado"),
                                ],
                                default="borrador",
                            ),
                        ),
                        (
                            "archivo_pdf_path",
                            models.FileField(
                                blank=True,
                                max_length=1000,
                                null=True,
                                storage=lab.storages.almacenamiento_lab,
                                upload_to="lab/informes/",
                            ),
                        ),
                        (
                            "datos_congelados",
                            models.JSONField(
                                blank=True, help_text="Foto de los datos al emitir.", null=True
                            ),
                        ),
                        ("emitido_en", models.DateTimeField(blank=True, null=True)),
                        (
                            "creado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                        (
                            "actualizado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "db_table": 'lab"."informes',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="InformeEnsayo",
                    fields=[
                        (
                            "pk",
                            models.CompositePrimaryKey(
                                "informe_id",
                                "ensayo_id",
                                blank=True,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                    ],
                    options={
                        "db_table": 'lab"."informe_ensayos',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Medicion",
                    fields=[
                        ("id", models.BigAutoField(primary_key=True, serialize=False)),
                        ("repeticion", models.SmallIntegerField(default=1)),
                        ("valor_num", models.DecimalField(blank=True, null=True)),
                        ("valor_texto", models.TextField(blank=True, null=True)),
                    ],
                    options={
                        "verbose_name": "medición",
                        "verbose_name_plural": "mediciones",
                        "db_table": 'lab"."mediciones',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="MetodoEnsayo",
                    fields=[
                        ("id", models.SmallAutoField(primary_key=True, serialize=False)),
                        ("nombre", models.TextField(unique=True)),
                        (
                            "tipo_resultado",
                            models.TextField(
                                choices=[
                                    ("compresion", "Compresión (resultados_compresion)"),
                                    ("generico", "Genérico (mediciones)"),
                                ]
                            ),
                        ),
                        ("unidad_resultado", models.TextField(blank=True, null=True)),
                        ("activo", models.BooleanField(default=True)),
                    ],
                    options={
                        "verbose_name": "método de ensayo",
                        "verbose_name_plural": "métodos de ensayo",
                        "db_table": 'lab"."metodos_ensayo',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="MetodoTipoEspecimen",
                    fields=[
                        (
                            "pk",
                            models.CompositePrimaryKey(
                                "metodo_id",
                                "tipo_especimen_id",
                                blank=True,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                    ],
                    options={
                        "db_table": 'lab"."metodo_tipos_especimen',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="MovimientoEspecimen",
                    fields=[
                        ("id", models.BigAutoField(primary_key=True, serialize=False)),
                        (
                            "movido_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                        ("nota", models.TextField(blank=True, null=True)),
                    ],
                    options={
                        "verbose_name": "movimiento de espécimen",
                        "verbose_name_plural": "movimientos de espécimen",
                        "db_table": 'lab"."movimientos_especimen',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Muestra",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        (
                            "elemento_colado",
                            models.TextField(
                                help_text='Por ejemplo "Losa de fundación de piscina torre A".'
                            ),
                        ),
                        ("fecha_elaboracion", models.DateField(help_text="Fecha de colado.")),
                        ("hora_elaboracion", models.TimeField(blank=True, null=True)),
                        (
                            "requisito_tipo",
                            models.TextField(
                                choices=[
                                    ("fc", "f'c (resistencia a compresión)"),
                                    ("mr", "Módulo de ruptura"),
                                ],
                                default="fc",
                            ),
                        ),
                        (
                            "resistencia_requerida",
                            models.DecimalField(
                                blank=True, decimal_places=2, max_digits=8, null=True
                            ),
                        ),
                        ("unidad_requerida", models.TextField(default="kg/cm2")),
                        (
                            "revenimiento_in",
                            models.DecimalField(
                                blank=True, decimal_places=2, max_digits=5, null=True
                            ),
                        ),
                        (
                            "temperatura_c",
                            models.DecimalField(
                                blank=True, decimal_places=2, max_digits=5, null=True
                            ),
                        ),
                        ("comentario", models.TextField(blank=True, null=True)),
                        (
                            "creado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                        (
                            "actualizado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "db_table": 'lab"."muestras',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Norma",
                    fields=[
                        ("id", models.SmallAutoField(primary_key=True, serialize=False)),
                        ("codigo", models.TextField(unique=True)),
                        ("titulo", models.TextField(blank=True, null=True)),
                    ],
                    options={
                        "db_table": 'lab"."normas',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="ParametroMetodo",
                    fields=[
                        ("id", models.SmallAutoField(primary_key=True, serialize=False)),
                        ("nombre", models.TextField()),
                        ("unidad", models.TextField(blank=True, null=True)),
                        (
                            "tipo_dato",
                            models.TextField(
                                choices=[
                                    ("numero", "Número"),
                                    ("texto", "Texto"),
                                    ("booleano", "Booleano"),
                                ],
                                default="numero",
                            ),
                        ),
                        ("requerido", models.BooleanField(default=True)),
                        ("repeticiones", models.SmallIntegerField(default=1)),
                        (
                            "es_resultado",
                            models.BooleanField(
                                default=False, help_text="El valor principal que va al informe."
                            ),
                        ),
                        ("valor_min", models.DecimalField(blank=True, null=True)),
                        ("valor_max", models.DecimalField(blank=True, null=True)),
                        ("orden", models.SmallIntegerField(default=0)),
                    ],
                    options={
                        "verbose_name": "parámetro de método",
                        "verbose_name_plural": "parámetros de método",
                        "db_table": 'lab"."parametros_metodo',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="ProveedorMaterial",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        ("nombre", models.TextField(unique=True)),
                        ("es_obra", models.BooleanField(default=False)),
                        ("activo", models.BooleanField(default=True)),
                        (
                            "creado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "verbose_name": "proveedor de material",
                        "verbose_name_plural": "proveedores de material",
                        "db_table": 'lab"."proveedores_material',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Remision",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        ("codigo", models.TextField(blank=True, null=True, unique=True)),
                        ("formato", models.TextField(default="P8-REG03")),
                        ("fecha_remision", models.DateField()),
                        (
                            "entregado_por_nombre",
                            models.TextField(
                                blank=True,
                                help_text="Por si quien entrega no es empleado.",
                                null=True,
                            ),
                        ),
                        ("recibido_campo_por", models.TextField(blank=True, null=True)),
                        ("recibido_en", models.DateTimeField(blank=True, null=True)),
                        (
                            "documento_path",
                            models.FileField(
                                blank=True,
                                help_text="Foto o escaneo de la hoja firmada.",
                                max_length=1000,
                                null=True,
                                storage=lab.storages.almacenamiento_lab,
                                upload_to="lab/remisiones/",
                            ),
                        ),
                        ("observaciones", models.TextField(blank=True, null=True)),
                        (
                            "creado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                        (
                            "actualizado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "verbose_name": "remisión",
                        "verbose_name_plural": "remisiones",
                        "db_table": 'lab"."remisiones',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="TipoEspecimen",
                    fields=[
                        ("id", models.SmallAutoField(primary_key=True, serialize=False)),
                        ("codigo", models.TextField(unique=True)),
                        ("nombre", models.TextField()),
                        (
                            "forma",
                            models.TextField(
                                choices=[
                                    ("cilindro", "Cilindro"),
                                    ("cubo", "Cubo"),
                                    ("nucleo", "Núcleo"),
                                    ("viga", "Viga"),
                                ]
                            ),
                        ),
                        ("notas", models.TextField(blank=True, null=True)),
                        ("activo", models.BooleanField(default=True)),
                    ],
                    options={
                        "verbose_name": "tipo de espécimen",
                        "verbose_name_plural": "tipos de espécimen",
                        "db_table": 'lab"."tipos_especimen',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="TipoFalla",
                    fields=[
                        ("codigo", models.SmallIntegerField(primary_key=True, serialize=False)),
                        ("descripcion", models.TextField()),
                    ],
                    options={
                        "verbose_name": "tipo de falla",
                        "verbose_name_plural": "tipos de falla",
                        "db_table": 'lab"."tipos_falla',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="Ubicacion",
                    fields=[
                        (
                            "id",
                            models.UUIDField(
                                default=uuid.uuid4,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        (
                            "tipo",
                            models.TextField(
                                choices=[
                                    ("bidon", "Bidón"),
                                    ("estante", "Estante"),
                                    ("peldano", "Peldaño"),
                                ]
                            ),
                        ),
                        ("codigo", models.TextField()),
                        ("nombre", models.TextField(blank=True, null=True)),
                        ("activa", models.BooleanField(default=True)),
                    ],
                    options={
                        "verbose_name": "ubicación",
                        "verbose_name_plural": "ubicaciones",
                        "db_table": 'lab"."ubicaciones',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="UsuarioRol",
                    fields=[
                        (
                            "pk",
                            models.CompositePrimaryKey(
                                "empleado_id",
                                "rol",
                                blank=True,
                                editable=False,
                                primary_key=True,
                                serialize=False,
                            ),
                        ),
                        (
                            "rol",
                            models.TextField(
                                choices=[
                                    ("administrador", "Administrador"),
                                    ("recepcion", "Recepción"),
                                    ("tecnico", "Técnico"),
                                    ("supervisor", "Supervisor"),
                                    ("consulta", "Consulta"),
                                ]
                            ),
                        ),
                        (
                            "asignado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "verbose_name": "rol de usuario del laboratorio",
                        "verbose_name_plural": "roles de usuario del laboratorio",
                        "db_table": 'lab"."usuarios_roles',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="VistaCurvaResistencia",
                    fields=[
                        ("muestra_id", models.UUIDField(primary_key=True, serialize=False)),
                        ("proyecto_id", models.UUIDField()),
                        ("elemento_colado", models.TextField()),
                        ("fecha_colado", models.DateField()),
                        (
                            "resistencia_requerida",
                            models.DecimalField(decimal_places=2, max_digits=8, null=True),
                        ),
                        ("edad", models.SmallIntegerField(null=True)),
                        ("n_especimenes", models.BigIntegerField()),
                        ("resistencia_promedio", models.DecimalField(null=True)),
                        ("ganancia_promedio", models.DecimalField(null=True)),
                    ],
                    options={
                        "verbose_name": "curva de resistencia",
                        "verbose_name_plural": "curvas de resistencia",
                        "db_table": 'lab"."v_curva_resistencia',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="VistaProgramacionEnsayos",
                    fields=[
                        ("especimen_id", models.UUIDField(primary_key=True, serialize=False)),
                        ("fecha_ensayo_programada", models.DateField()),
                        ("proyecto", models.TextField()),
                        ("numero", models.TextField()),
                        ("fecha_colado", models.DateField()),
                        ("edad", models.SmallIntegerField()),
                        ("tipo", models.TextField()),
                        (
                            "resistencia_requerida",
                            models.DecimalField(decimal_places=2, max_digits=8, null=True),
                        ),
                        ("requisito_tipo", models.TextField()),
                        ("ubicacion", models.TextField(null=True)),
                        ("estado", models.TextField()),
                    ],
                    options={
                        "verbose_name": "programación de ensayos",
                        "verbose_name_plural": "programación de ensayos",
                        "db_table": 'lab"."v_programacion_ensayos',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="VistaResultadosCompresion",
                    fields=[
                        ("ensayo_id", models.UUIDField(primary_key=True, serialize=False)),
                        ("cliente", models.TextField(null=True)),
                        ("proyecto", models.TextField()),
                        ("elemento_colado", models.TextField()),
                        ("tipo", models.TextField()),
                        ("especimen", models.TextField()),
                        ("fecha_colado", models.DateField()),
                        ("fecha_ensayo", models.DateField(null=True)),
                        ("edad", models.SmallIntegerField(null=True)),
                        (
                            "peso_g",
                            models.DecimalField(decimal_places=2, max_digits=9, null=True),
                        ),
                        ("diametro_prom_mm", models.DecimalField(null=True)),
                        ("altura_prom_mm", models.DecimalField(null=True)),
                        ("area_mm2", models.DecimalField(decimal_places=2, max_digits=10)),
                        ("carga_kn", models.DecimalField(decimal_places=2, max_digits=10)),
                        ("resistencia_kgcm2", models.DecimalField(null=True)),
                        ("resistencia_mpa", models.DecimalField(null=True)),
                        (
                            "resistencia_requerida_kgcm2",
                            models.DecimalField(decimal_places=2, max_digits=8, null=True),
                        ),
                        ("ganancia_pct", models.DecimalField(null=True)),
                        ("tipo_falla", models.SmallIntegerField(null=True)),
                        ("estado", models.TextField()),
                    ],
                    options={
                        "verbose_name": "resultado de compresión (vista)",
                        "verbose_name_plural": "resultados de compresión (vista)",
                        "db_table": 'lab"."v_resultados_compresion',
                        "abstract": False,
                        "managed": False,
                    },
                ),
                migrations.CreateModel(
                    name="ResultadoCompresion",
                    fields=[
                        (
                            "ensayo",
                            models.OneToOneField(
                                on_delete=django.db.models.deletion.CASCADE,
                                primary_key=True,
                                related_name="resultado_compresion",
                                serialize=False,
                                to="lab.ensayo",
                            ),
                        ),
                        ("carga_kn", models.DecimalField(decimal_places=2, max_digits=10)),
                        (
                            "resistencia_requerida_kgcm2",
                            models.DecimalField(
                                blank=True,
                                decimal_places=2,
                                help_text="Copia de la muestra al ensayar: queda congelada.",
                                max_digits=8,
                                null=True,
                            ),
                        ),
                        (
                            "area_mm2",
                            models.DecimalField(
                                blank=True,
                                decimal_places=2,
                                help_text="Si llega vacía la calcula la base.",
                                max_digits=10,
                            ),
                        ),
                        (
                            "resistencia_kgcm2",
                            models.GeneratedField(
                                db_persist=True,
                                expression=models.Func(
                                    models.F("carga_kn"),
                                    models.F("area_mm2"),
                                    function="lab.resistencia_kgcm2",
                                    output_field=models.DecimalField(),
                                ),
                                output_field=models.DecimalField(),
                            ),
                        ),
                        (
                            "resistencia_mpa",
                            models.GeneratedField(
                                db_persist=True,
                                expression=django.db.models.functions.math.Round(
                                    django.db.models.expressions.CombinedExpression(
                                        django.db.models.expressions.CombinedExpression(
                                            models.F("carga_kn"), "*", models.Value(1000)
                                        ),
                                        "/",
                                        django.db.models.functions.comparison.NullIf(
                                            models.F("area_mm2"), models.Value(0)
                                        ),
                                    ),
                                    2,
                                ),
                                output_field=models.DecimalField(),
                            ),
                        ),
                        (
                            "ganancia_pct",
                            models.GeneratedField(
                                db_persist=True,
                                expression=django.db.models.functions.math.Round(
                                    django.db.models.expressions.CombinedExpression(
                                        django.db.models.expressions.CombinedExpression(
                                            models.Func(
                                                models.F("carga_kn"),
                                                models.F("area_mm2"),
                                                function="lab.resistencia_kgcm2",
                                                output_field=models.DecimalField(),
                                            ),
                                            "/",
                                            django.db.models.functions.comparison.NullIf(
                                                models.F("resistencia_requerida_kgcm2"),
                                                models.Value(0),
                                            ),
                                        ),
                                        "*",
                                        models.Value(100),
                                    ),
                                    1,
                                ),
                                output_field=models.DecimalField(),
                            ),
                        ),
                        (
                            "actualizado_en",
                            models.DateTimeField(
                                db_default=django.db.models.functions.datetime.Now(),
                                editable=False,
                            ),
                        ),
                    ],
                    options={
                        "verbose_name": "resultado de compresión",
                        "verbose_name_plural": "resultados de compresión",
                        "db_table": 'lab"."resultados_compresion',
                        "abstract": False,
                        "managed": False,
                    },
                ),
            ],
        ),
    ]
