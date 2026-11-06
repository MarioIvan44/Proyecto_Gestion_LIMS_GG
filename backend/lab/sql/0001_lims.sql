-- ############################################################################
-- LIMS (esquema lab) · SQL que ejecuta la migración lab/migrations/0001_initial.py
-- ############################################################################
-- Es la Parte 3 (parte3_lims_sobre_central.sql) con SOLO estos cambios:
--   * Se quitó SELECT set_config('search_path', '', false): en una migración dejaría a Django
--     sin ruta de búsqueda para el resto de sus consultas. El SQL ya usa nombres con esquema.
--   * Se quitó BEGIN/COMMIT: la migración ya corre dentro de una transacción.
--   * Se quitó lab.contactos_cliente y su índice: ahora es nucleo_contactocliente
--     (migración nucleo.0003_contactocliente), como se decidió el 6-nov-2026.
-- Todo lo demás es igual a la Parte 3, que sigue siendo la referencia del diseño del LIMS.
-- Si el esquema lab cambia, se agrega una migración nueva en lab/migrations/ con el ALTER.
-- ============================================================================

create schema if not exists lab;

-- =====================================================================
--  2. CATÁLOGOS DEL LABORATORIO
-- =====================================================================

-- Áreas: Ensayos a materiales / Geotecnia
create table lab.areas (
  id      smallint generated always as identity primary key,
  nombre  text not null unique
);

-- Concreto, mortero, suelo, arena, grava, acero, lodocreto, bloques...
create table lab.categorias_material (
  id      smallint generated always as identity primary key,
  area_id smallint not null references lab.areas(id),
  nombre  text not null unique,
  activo  boolean not null default true
);

-- Tipo de espécimen: códigos de la hoja de programación (CC, CM, PG, BRQ, V); significado por confirmar
create table lab.tipos_especimen (
  id                    smallint generated always as identity primary key,
  codigo                text not null unique,
  nombre                text not null,
  categoria_id          smallint not null references lab.categorias_material(id),
  forma                 text not null
                        check (forma in ('cilindro', 'cubo', 'nucleo', 'viga')),
  notas                 text,
  activo                boolean not null default true
);

create table lab.normas (
  id      smallint generated always as identity primary key,
  codigo  text not null unique,
  titulo  text
);

-- Métodos de ensayo. tipo_resultado decide dónde se guardan los datos:
--   'compresion' → lab.resultados_compresion (columnas tipadas)
--   'generico'   → lab.mediciones (parámetros configurables)
create table lab.metodos_ensayo (
  id               smallint generated always as identity primary key,
  nombre           text not null unique,
  area_id          smallint not null references lab.areas(id),
  norma_id         smallint references lab.normas(id),
  tipo_resultado   text not null check (tipo_resultado in ('compresion', 'generico')),
  unidad_resultado text,
  activo           boolean not null default true
);

-- Qué tipos de espécimen admite cada método
create table lab.metodo_tipos_especimen (
  metodo_id         smallint not null references lab.metodos_ensayo(id) on delete cascade,
  tipo_especimen_id smallint not null references lab.tipos_especimen(id) on delete cascade,
  primary key (metodo_id, tipo_especimen_id)
);

-- Parámetros configurables por método (los definen los técnicos)
create table lab.parametros_metodo (
  id            smallint generated always as identity primary key,
  metodo_id     smallint not null references lab.metodos_ensayo(id) on delete cascade,
  nombre        text not null,
  unidad        text,
  tipo_dato     text not null default 'numero' check (tipo_dato in ('numero', 'texto', 'booleano')),
  requerido     boolean not null default true,
  repeticiones  smallint not null default 1 check (repeticiones >= 1),
  es_resultado  boolean not null default false,  -- el valor principal que va al informe
  valor_min     numeric,
  valor_max     numeric,
  orden         smallint not null default 0,
  unique (metodo_id, nombre)
);

-- Tipos de falla (columna "Tipo falla" del formato M10-REG01)
create table lab.tipos_falla (
  codigo       smallint primary key,
  descripcion  text not null
);

-- Procedencia del concreto/mortero (PAVICON, elaborado en obra, etc.)
create table lab.proveedores_material (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null unique,
  es_obra    boolean not null default false,
  activo     boolean not null default true,
  creado_en  timestamptz not null default now()
);


-- =====================================================================
--  3. EQUIPOS Y UBICACIONES FÍSICAS
-- =====================================================================
create table lab.equipos (
  id         uuid primary key default gen_random_uuid(),
  codigo     text not null unique,
  nombre     text not null,                    -- ej. "Prensa FORNEY VFD Automatic"
  marca      text,
  modelo     text,
  serie      text,
  tipo       text,
  activo     boolean not null default true,
  creado_en  timestamptz not null default now()
);

create table lab.calibraciones (
  id                uuid primary key default gen_random_uuid(),
  equipo_id         uuid not null references lab.equipos(id) on delete cascade,
  fecha             date not null,
  vence             date,
  entidad           text,
  certificado_path  text,                      -- ruta del archivo (antes Supabase Storage)
  observaciones     text,
  check (vence is null or vence >= fecha)
);

-- Jerarquía: cuarto/pila → bidón o estante → peldaño
create table lab.ubicaciones (
  id        uuid primary key default gen_random_uuid(),
  padre_id  uuid references lab.ubicaciones(id),
  tipo      text not null check (tipo in ('bidon', 'estante', 'peldano')),
  codigo    text not null,                     -- número o código del bidón, estante o peldaño
  nombre    text,
  activa    boolean not null default true,
  unique nulls not distinct (padre_id, codigo)
);


-- =====================================================================
--  4. RECEPCIÓN: REMISIÓN → MUESTRA (colado) → ESPÉCIMEN
-- =====================================================================
create table lab.remisiones (
  id                       uuid primary key default gen_random_uuid(),
  codigo                   text unique,        -- correlativo interno del laboratorio
  formato                  text not null default 'P8-REG03',
  proyecto_id              uuid not null references public.nucleo_proyecto(id),
  fecha_remision           date not null,
  entregado_por_empleado   uuid references public.nucleo_empleado(id),
  entregado_por_nombre     text,               -- por si quien entrega no es empleado
  recibido_campo_por       text,
  recibido_lab_por         uuid references public.nucleo_empleado(id),
  recibido_en              timestamptz,
  documento_path           text,               -- foto/escaneo de la hoja firmada
  observaciones            text,
  creado_por               uuid references public.nucleo_empleado(id),
  creado_en                timestamptz not null default now(),
  actualizado_en           timestamptz not null default now(),
  unique (id, proyecto_id)                     -- para FK compuesta desde muestras
);

create table lab.muestras (
  id                     uuid primary key default gen_random_uuid(),
  remision_id            uuid not null,
  proyecto_id            uuid not null,
  tipo_especimen_id      smallint not null references lab.tipos_especimen(id),
  elemento_colado        text not null,      -- "Losa de fundación de piscina torre A"
  fecha_elaboracion      date not null,      -- fecha de colado
  hora_elaboracion       time,
  requisito_tipo         text not null default 'fc'
                         check (requisito_tipo in ('fc', 'mr')),  -- f'c o módulo de ruptura
  resistencia_requerida  numeric(8,2) check (resistencia_requerida > 0),
  unidad_requerida       text not null default 'kg/cm2',
  revenimiento_in        numeric(5,2),
  temperatura_c          numeric(5,2),
  proveedor_id           uuid references lab.proveedores_material(id),
  comentario             text,
  creado_en              timestamptz not null default now(),
  actualizado_en         timestamptz not null default now(),
  foreign key (remision_id, proyecto_id) references lab.remisiones(id, proyecto_id),
  unique (id, proyecto_id, tipo_especimen_id)  -- para FK compuesta desde especímenes
);

create type lab.estado_especimen as enum ('recibido', 'almacenado', 'ensayado');

create table lab.especimenes (
  id                       uuid primary key default gen_random_uuid(),
  muestra_id               uuid not null,
  proyecto_id              uuid not null,      -- redundante a propósito: garantiza unicidad
  tipo_especimen_id        smallint not null,  -- y se valida contra la muestra (FK compuesta)
  numero                   text not null,      -- número asignado en campo: "769"
  edad_programada_dias     smallint not null check (edad_programada_dias > 0),
  fecha_ensayo_programada  date not null,      -- se calcula sola (colado + edad) si no se envía
  peso_g                   numeric(9,2) check (peso_g > 0),
  diametro_1_mm            numeric(7,2) check (diametro_1_mm > 0),
  diametro_2_mm            numeric(7,2) check (diametro_2_mm > 0),
  altura_1_mm              numeric(7,2) check (altura_1_mm > 0),
  altura_2_mm              numeric(7,2) check (altura_2_mm > 0),
  largo_mm                 numeric(7,2) check (largo_mm > 0),      -- cubos y bloques
  ancho_mm                 numeric(7,2) check (ancho_mm > 0),      -- cubos y bloques
  estado                   lab.estado_especimen not null default 'recibido',
  ubicacion_id             uuid references lab.ubicaciones(id),
  observaciones            text,
  creado_en                timestamptz not null default now(),
  actualizado_en           timestamptz not null default now(),
  foreign key (muestra_id, proyecto_id, tipo_especimen_id)
    references lab.muestras(id, proyecto_id, tipo_especimen_id),
  unique (proyecto_id, tipo_especimen_id, numero)
);

-- Historial de dónde ha estado cada espécimen (bidón/estante/peldaño)
create table lab.movimientos_especimen (
  id            bigint generated always as identity primary key,
  especimen_id  uuid not null references lab.especimenes(id) on delete cascade,
  ubicacion_id  uuid references lab.ubicaciones(id),
  movido_en     timestamptz not null default now(),
  movido_por    uuid references public.nucleo_empleado(id),
  nota          text
);


-- =====================================================================
--  5. ENSAYOS Y RESULTADOS
-- =====================================================================
create type lab.estado_ensayo as enum
  ('pendiente', 'en_proceso', 'completado', 'en_revision', 'aprobado');

-- Importaciones de archivos de equipos (CSV FORNEY)
create table lab.importaciones (
  id              uuid primary key default gen_random_uuid(),
  equipo_id       uuid references lab.equipos(id),
  archivo_path    text not null,
  archivo_sha256  text not null unique,        -- evita importar dos veces el mismo archivo
  estado          text not null default 'cargado'
                  check (estado in ('cargado', 'validado', 'con_errores', 'aplicado', 'descartado')),
  filas_total     integer,
  filas_validas   integer,
  importado_por   uuid references public.nucleo_empleado(id),
  importado_en    timestamptz not null default now(),
  notas           text
);

create table lab.importacion_filas (
  id              bigint generated always as identity primary key,
  importacion_id  uuid not null references lab.importaciones(id) on delete cascade,
  numero_fila     integer not null,
  datos           jsonb not null,              -- la fila cruda tal como venía en el CSV
  especimen_id    uuid references lab.especimenes(id),
  estado          text not null default 'pendiente'
                  check (estado in ('pendiente', 'ok', 'error', 'duplicado', 'aplicada')),
  errores         text[],
  unique (importacion_id, numero_fila)
);

-- Un ensayo = una ejecución de un método sobre un espécimen.
create table lab.ensayos (
  id                   uuid primary key default gen_random_uuid(),
  especimen_id         uuid not null references lab.especimenes(id),
  metodo_id            smallint not null references lab.metodos_ensayo(id),
  fecha_programada     date not null,
  ejecutado_en         timestamptz,
  edad_real_dias       smallint,               -- se calcula al registrar ejecutado_en
  tecnico_id           uuid references public.nucleo_empleado(id),
  equipo_id            uuid references lab.equipos(id),
  estado               lab.estado_ensayo not null default 'pendiente',
  origen               text not null default 'manual' check (origen in ('manual', 'importacion')),
  importacion_fila_id  bigint references lab.importacion_filas(id),
  revisado_por         uuid references public.nucleo_empleado(id),
  revisado_en          timestamptz,
  aprobado_por         uuid references public.nucleo_empleado(id),
  aprobado_en          timestamptz,
  observaciones        text,
  creado_en            timestamptz not null default now(),
  actualizado_en       timestamptz not null default now()
);

-- Un espécimen se rompe una sola vez por método
create unique index ux_ensayo_por_especimen
  on lab.ensayos (especimen_id, metodo_id);

-- Fórmulas (inmutables) usadas por las columnas calculadas
create or replace function lab.area_mm2(d1 numeric, d2 numeric, largo numeric, ancho numeric)
returns numeric language sql immutable as $$
  select round(case
           when d1 is not null then pi() * power((d1 + coalesce(d2, d1)) / 2, 2) / 4  -- πd²/4
           else largo * ancho
         end::numeric, 2)
$$;

-- Resistencia = F / A   (kN → kgf: ×101.97162 ; mm² → cm²: ÷100)
create or replace function lab.resistencia_kgcm2(carga_kn numeric, area_mm2 numeric)
returns numeric language sql immutable as $$
  select case when area_mm2 > 0
              then round(carga_kn * 101.97162 / (area_mm2 / 100), 2) end
$$;

-- Datos del formato M10-REG01 "Datos de Ensayo Resistencia a Compresión".
create table lab.resultados_compresion (
  ensayo_id                    uuid primary key references lab.ensayos(id) on delete cascade,
  carga_kn                     numeric(10,2) not null check (carga_kn > 0),
  tipo_falla                   smallint references lab.tipos_falla(codigo),
  resistencia_requerida_kgcm2  numeric(8,2),   -- copia de la muestra al ensayar (queda congelada)
  area_mm2                     numeric(10,2) not null check (area_mm2 > 0),
  resistencia_kgcm2 numeric generated always as
            (lab.resistencia_kgcm2(carga_kn, area_mm2)) stored,
  resistencia_mpa numeric generated always as
            (round(carga_kn * 1000 / nullif(area_mm2, 0), 2)) stored,
  ganancia_pct numeric generated always as
            (round(lab.resistencia_kgcm2(carga_kn, area_mm2) / nullif(resistencia_requerida_kgcm2, 0) * 100, 1)) stored,
  actualizado_en  timestamptz not null default now()
);

-- Mediciones genéricas para cualquier otro método (geotecnia, agregados...)
create table lab.mediciones (
  id           bigint generated always as identity primary key,
  ensayo_id    uuid not null references lab.ensayos(id) on delete cascade,
  parametro_id smallint not null references lab.parametros_metodo(id),
  repeticion   smallint not null default 1 check (repeticion >= 1),
  valor_num    numeric,
  valor_texto  text,
  unique (ensayo_id, parametro_id, repeticion),
  check (valor_num is not null or valor_texto is not null)
);


-- =====================================================================
--  6. INFORMES Y ARCHIVOS
-- =====================================================================
create type lab.tipo_informe as enum ('diario', 'mensual');

create table lab.informes (
  id                uuid primary key default gen_random_uuid(),
  codigo            text unique,
  tipo              lab.tipo_informe not null,
  proyecto_id       uuid references public.nucleo_proyecto(id),   -- null en el informe diario general
  fecha_desde       date not null,
  fecha_hasta       date not null,
  conclusiones      text,
  recomendaciones   text,
  estado            text not null default 'borrador' check (estado in ('borrador', 'emitido', 'anulado')),
  archivo_pdf_path  text,
  datos_congelados  jsonb,                      -- foto de los datos al emitir
  elaborado_por     uuid references public.nucleo_empleado(id),
  aprobado_por      uuid references public.nucleo_empleado(id),
  emitido_en        timestamptz,
  creado_en         timestamptz not null default now(),
  actualizado_en    timestamptz not null default now(),
  check (fecha_hasta >= fecha_desde)
);

create table lab.informe_ensayos (
  informe_id  uuid not null references lab.informes(id) on delete cascade,
  ensayo_id   uuid not null references lab.ensayos(id),
  primary key (informe_id, ensayo_id)
);

create table lab.adjuntos (
  id               uuid primary key default gen_random_uuid(),
  entidad          text not null check (entidad in ('remision', 'muestra', 'especimen', 'ensayo', 'informe', 'equipo')),
  entidad_id       uuid not null,
  storage_path     text not null,
  nombre_original  text,
  mime             text,
  tamano_bytes     bigint,
  subido_por       uuid references public.nucleo_empleado(id),
  subido_en        timestamptz not null default now()
);


-- =====================================================================
--  7. SEGURIDAD: ROLES Y AUDITORÍA
-- =====================================================================
create type lab.rol as enum ('administrador', 'recepcion', 'tecnico', 'supervisor', 'consulta');

create table lab.usuarios_roles (
  empleado_id   uuid not null references public.nucleo_empleado(id) on delete cascade,
  rol           lab.rol not null,
  asignado_en   timestamptz not null default now(),
  asignado_por  uuid references public.nucleo_empleado(id),
  primary key (empleado_id, rol)
);

create table lab.auditoria (
  id               bigint generated always as identity primary key,
  tabla            text not null,
  registro_id      text,
  accion           text not null,
  antes            jsonb,
  despues          jsonb,
  motivo           text,
  usuario_auth_id  uuid,                       -- ahora: id de public.nucleo_usuario (sin FK a propósito)
  ocurrido_en      timestamptz not null default now()
);


-- =====================================================================
--  8. ÍNDICES
-- =====================================================================
create index ix_remisiones_proyecto      on lab.remisiones (proyecto_id, fecha_remision);
create index ix_muestras_proyecto        on lab.muestras (proyecto_id, fecha_elaboracion);
create index ix_muestras_remision        on lab.muestras (remision_id);
create index ix_especimenes_muestra      on lab.especimenes (muestra_id);
create index ix_especimenes_por_ensayar  on lab.especimenes (fecha_ensayo_programada)
                                          where estado in ('recibido', 'almacenado');
create index ix_especimenes_ubicacion    on lab.especimenes (ubicacion_id);
create index ix_movimientos_especimen    on lab.movimientos_especimen (especimen_id, movido_en);
create index ix_ensayos_estado_fecha     on lab.ensayos (estado, fecha_programada);
create index ix_ensayos_ejecutado        on lab.ensayos (ejecutado_en);
create index ix_mediciones_ensayo        on lab.mediciones (ensayo_id);
create index ix_import_filas_importacion on lab.importacion_filas (importacion_id);
create index ix_adjuntos_entidad         on lab.adjuntos (entidad, entidad_id);
create index ix_auditoria_registro       on lab.auditoria (tabla, registro_id);


-- =====================================================================
--  9. FUNCIONES DE APOYO
-- =====================================================================
create or replace function lab.fn_tocar_actualizado()
returns trigger language plpgsql as $$
begin
  new.actualizado_en := now();
  return new;
end $$;

-- Usuario actual = id de public.nucleo_usuario que el backend fija por transacción:
--   select set_config('lab.usuario_id', '<uuid>', true);
-- Sin esa variable devuelve NULL (migraciones, scripts, pgAdmin).
create or replace function lab.usuario_actual()
returns uuid language sql stable as $$
  select nullif(current_setting('lab.usuario_id', true), '')::uuid
$$;

-- Motivo de corrección de un resultado aprobado:
--   select set_config('lab.motivo_correccion', '...', true)
create or replace function lab.motivo_correccion()
returns text language sql stable as $$
  select nullif(current_setting('lab.motivo_correccion', true), '')
$$;

create or replace function lab.empleado_actual()
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.nucleo_empleado where usuario_id = lab.usuario_actual() and activo
$$;

-- El administrador siempre cumple cualquier rol
create or replace function lab.tiene_rol(variadic p_roles lab.rol[])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from lab.usuarios_roles ur
    join public.nucleo_empleado e on e.id = ur.empleado_id
    where e.usuario_id = lab.usuario_actual()
      and e.activo
      and (ur.rol = any (p_roles) or ur.rol = 'administrador')
  )
$$;

create or replace function lab.tiene_algun_rol()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from lab.usuarios_roles ur
    join public.nucleo_empleado e on e.id = ur.empleado_id
    where e.usuario_id = lab.usuario_actual() and e.activo
  )
$$;

create or replace function lab.fn_auditar()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
begin
  insert into lab.auditoria (tabla, registro_id, accion, antes, despues, motivo, usuario_auth_id)
  values (tg_table_name,
          coalesce(v_new, v_old) ->> coalesce(tg_argv[0], 'id'),
          tg_op, v_old, v_new,
          lab.motivo_correccion(),
          lab.usuario_actual());
  return null;
end $$;


-- =====================================================================
--  10. REGLAS DE NEGOCIO (TRIGGERS)
-- =====================================================================

-- 10.1 Fecha de ensayo programada = fecha de colado + edad
create or replace function lab.fn_especimen_defaults()
returns trigger language plpgsql as $$
begin
  if new.fecha_ensayo_programada is null then
    select m.fecha_elaboracion + new.edad_programada_dias
      into new.fecha_ensayo_programada
      from lab.muestras m where m.id = new.muestra_id;
  end if;
  return new;
end $$;

create trigger trg_especimen_defaults before insert on lab.especimenes
  for each row execute function lab.fn_especimen_defaults();

-- 10.2 Cada cambio de bidón/estante queda en el historial
create or replace function lab.fn_registrar_movimiento()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.ubicacion_id is distinct from (case when tg_op = 'UPDATE' then old.ubicacion_id end) then
    insert into lab.movimientos_especimen (especimen_id, ubicacion_id, movido_por)
    values (new.id, new.ubicacion_id, lab.empleado_actual());
  end if;
  return null;
end $$;

create trigger trg_especimen_movimiento after insert or update of ubicacion_id on lab.especimenes
  for each row execute function lab.fn_registrar_movimiento();

-- 10.3 Ensayos: fecha programada, edad real, aprobación protegida
create or replace function lab.fn_ensayo_reglas()
returns trigger language plpgsql as $$
declare
  v_colado date;
begin
  select m.fecha_elaboracion into v_colado
    from lab.especimenes e join lab.muestras m on m.id = e.muestra_id
   where e.id = new.especimen_id;

  if tg_op = 'INSERT' and new.fecha_programada is null then
    select fecha_ensayo_programada into new.fecha_programada
      from lab.especimenes where id = new.especimen_id;
  end if;

  if new.ejecutado_en is not null then
    new.edad_real_dias := (new.ejecutado_en at time zone 'America/El_Salvador')::date - v_colado;
  end if;

  if tg_op = 'UPDATE' then
    if old.estado = 'aprobado' and lab.motivo_correccion() is null then
      raise exception 'El ensayo % está aprobado. Para corregirlo indique un motivo (lab.motivo_correccion).', old.id;
    end if;

    -- Solo supervisor/administrador aprueba (NULL = proceso interno/migración)
    if new.estado = 'aprobado' and old.estado <> 'aprobado' then
      if lab.usuario_actual() is not null and not lab.tiene_rol('supervisor') then
        raise exception 'Solo un supervisor puede aprobar resultados.';
      end if;
      new.aprobado_en  := coalesce(new.aprobado_en, now());
      new.aprobado_por := coalesce(new.aprobado_por, lab.empleado_actual());
    end if;

    if new.estado = 'en_revision' and old.estado <> 'en_revision' then
      new.revisado_en := coalesce(new.revisado_en, now());
    end if;
  end if;

  return new;
end $$;

create trigger trg_ensayo_reglas before insert or update on lab.ensayos
  for each row execute function lab.fn_ensayo_reglas();

-- 10.4 Al completar un ensayo, el espécimen pasa a "ensayado"
create or replace function lab.fn_ensayo_actualiza_especimen()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.estado in ('completado', 'en_revision', 'aprobado') then
    update lab.especimenes set estado = 'ensayado'
     where id = new.especimen_id and estado <> 'ensayado';
  end if;
  return null;
end $$;

create trigger trg_ensayo_especimen after insert or update of estado on lab.ensayos
  for each row execute function lab.fn_ensayo_actualiza_especimen();

-- 10.5 Copia la resistencia requerida de la muestra y calcula el área
create or replace function lab.fn_compresion_defaults()
returns trigger language plpgsql as $$
begin
  if new.resistencia_requerida_kgcm2 is null then
    select m.resistencia_requerida into new.resistencia_requerida_kgcm2
      from lab.ensayos en
      join lab.especimenes e on e.id = en.especimen_id
      join lab.muestras m on m.id = e.muestra_id
     where en.id = new.ensayo_id and m.unidad_requerida = 'kg/cm2';
  end if;
  if new.area_mm2 is null then
    select lab.area_mm2(e.diametro_1_mm, e.diametro_2_mm, e.largo_mm, e.ancho_mm) into new.area_mm2
      from lab.ensayos en
      join lab.especimenes e on e.id = en.especimen_id
     where en.id = new.ensayo_id;
    if new.area_mm2 is null then
      raise exception 'El espécimen no tiene medidas de ingreso (diámetro, o largo y ancho). Regístrelas antes del ensayo.';
    end if;
  end if;
  new.actualizado_en := now();
  return new;
end $$;

create trigger trg_compresion_defaults before insert or update on lab.resultados_compresion
  for each row execute function lab.fn_compresion_defaults();

-- 10.6 Datos de un ensayo aprobado no se tocan sin motivo
create or replace function lab.fn_proteger_aprobado()
returns trigger language plpgsql as $$
declare
  v_estado lab.estado_ensayo;
begin
  select estado into v_estado from lab.ensayos
   where id = case when tg_op = 'DELETE' then old.ensayo_id else new.ensayo_id end;
  if v_estado = 'aprobado' and lab.motivo_correccion() is null then
    raise exception 'Los datos pertenecen a un ensayo aprobado. Indique un motivo de corrección.';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger trg_proteger before insert or update or delete on lab.resultados_compresion
  for each row execute function lab.fn_proteger_aprobado();
create trigger trg_proteger before insert or update or delete on lab.mediciones
  for each row execute function lab.fn_proteger_aprobado();

-- 10.7 actualizado_en (solo tablas lab; las centrales las cubre triggers.sql)
create trigger trg_touch before update on lab.remisiones  for each row execute function lab.fn_tocar_actualizado();
create trigger trg_touch before update on lab.muestras    for each row execute function lab.fn_tocar_actualizado();
create trigger trg_touch before update on lab.especimenes for each row execute function lab.fn_tocar_actualizado();
create trigger trg_touch before update on lab.ensayos     for each row execute function lab.fn_tocar_actualizado();
create trigger trg_touch before update on lab.informes    for each row execute function lab.fn_tocar_actualizado();

-- 10.8 Auditoría
create trigger trg_auditoria after insert or update or delete on lab.remisiones            for each row execute function lab.fn_auditar();
create trigger trg_auditoria after insert or update or delete on lab.muestras              for each row execute function lab.fn_auditar();
create trigger trg_auditoria after insert or update or delete on lab.especimenes           for each row execute function lab.fn_auditar();
create trigger trg_auditoria after insert or update or delete on lab.ensayos               for each row execute function lab.fn_auditar();
create trigger trg_auditoria after insert or update or delete on lab.resultados_compresion for each row execute function lab.fn_auditar('ensayo_id');
create trigger trg_auditoria after insert or update or delete on lab.mediciones            for each row execute function lab.fn_auditar();
create trigger trg_auditoria after insert or update or delete on lab.informes              for each row execute function lab.fn_auditar();
create trigger trg_auditoria after insert or update or delete on lab.usuarios_roles        for each row execute function lab.fn_auditar('empleado_id');


-- =====================================================================
--  11. VISTAS
-- =====================================================================

-- Lista del día:  where fecha_ensayo_programada = current_date
create view lab.v_programacion_ensayos with (security_invoker = true) as
select e.id                       as especimen_id,
       e.fecha_ensayo_programada,
       p.nombre                   as proyecto,
       e.numero,
       m.fecha_elaboracion        as fecha_colado,
       e.edad_programada_dias     as edad,
       te.codigo                  as tipo,
       m.resistencia_requerida,
       m.requisito_tipo,
       u.codigo                   as ubicacion,
       e.estado
from lab.especimenes e
join lab.muestras m              on m.id = e.muestra_id
join public.nucleo_proyecto p    on p.id = e.proyecto_id
join lab.tipos_especimen te      on te.id = e.tipo_especimen_id
left join lab.ubicaciones u      on u.id = e.ubicacion_id
where e.estado in ('recibido', 'almacenado');

-- Reporte de resultados de compresión
create view lab.v_resultados_compresion with (security_invoker = true) as
select en.id                         as ensayo_id,
       c.razon_social                as cliente,
       p.nombre                      as proyecto,
       m.elemento_colado,
       te.codigo                     as tipo,
       e.numero                      as especimen,
       m.fecha_elaboracion           as fecha_colado,
       en.ejecutado_en::date         as fecha_ensayo,
       en.edad_real_dias             as edad,
       e.peso_g,
       round((e.diametro_1_mm + coalesce(e.diametro_2_mm, e.diametro_1_mm)) / 2, 2) as diametro_prom_mm,
       round((e.altura_1_mm + coalesce(e.altura_2_mm, e.altura_1_mm)) / 2, 2)       as altura_prom_mm,
       r.area_mm2,
       r.carga_kn,
       r.resistencia_kgcm2,
       r.resistencia_mpa,
       r.resistencia_requerida_kgcm2,
       r.ganancia_pct,
       r.tipo_falla,
       en.estado
from lab.ensayos en
join lab.resultados_compresion r  on r.ensayo_id = en.id
join lab.especimenes e            on e.id = en.especimen_id
join lab.muestras m               on m.id = e.muestra_id
join lab.tipos_especimen te       on te.id = e.tipo_especimen_id
join public.nucleo_proyecto p     on p.id = e.proyecto_id
left join public.nucleo_cliente c on c.id = p.cliente_id;   -- cliente_id es opcional en la central

-- Curva resistencia vs edad por colado (gráfica 3-7-28 días)
create view lab.v_curva_resistencia with (security_invoker = true) as
select m.proyecto_id,
       m.id                         as muestra_id,
       m.elemento_colado,
       m.fecha_elaboracion          as fecha_colado,
       m.resistencia_requerida,
       en.edad_real_dias            as edad,
       count(*)                     as n_especimenes,
       round(avg(r.resistencia_kgcm2), 2) as resistencia_promedio,
       round(avg(r.ganancia_pct), 1)      as ganancia_promedio
from lab.resultados_compresion r
join lab.ensayos en     on en.id = r.ensayo_id
join lab.especimenes e  on e.id = en.especimen_id
join lab.muestras m     on m.id = e.muestra_id
group by m.proyecto_id, m.id, m.elemento_colado, m.fecha_elaboracion, m.resistencia_requerida, en.edad_real_dias;


-- =====================================================================
--  12. PERMISOS
--  Sin Row Level Security (decisión del 5-nov-2026): Django se conecta como dueño de las
--  tablas, así que RLS no protegería nada. Los permisos se manejan en Django con el sistema
--  de roles por departamento. Las reglas en triggers (solo el supervisor aprueba, protección
--  de ensayos aprobados, auditoría) siguen activas si el backend fija lab.usuario_id.
-- =====================================================================

-- Fin de la Parte 3
