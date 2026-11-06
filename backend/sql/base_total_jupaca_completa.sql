-- ############################################################################
-- JUPACA PROYECTA · Base de datos completa (un solo archivo)
-- Generado el 6-nov-2026 a partir de:
--   1. Las migraciones de Django de Proyecto_Gestion_LIMS_GG: nucleo (base central, con ubicación del
--      proyecto, tipo de persona + NIT/DUI del cliente, contactos de cliente y roles por departamento),
--      rrhh, finanzas, lectura, migracion y lab (LIMS: tablas, funciones, triggers y vistas).
--   2. Parte 2 · Gestión GG (gestion_*), tal como viene en base_total_jupaca.sql.
--   3. backend/sql/parche_gestion_gg_2026-11-06.sql: correlativo de oferta mayor a 999 y feriados 2027
--      (marcados es_supuesto = true).
--   4. Parte 4 · RRHH (6-nov-2026): viáticos, préstamo y REF en rrhh_lineaplanilla, tarifas de hora extra
--      por departamento, horas extras por día, comprobantes manuales, préstamos y sus vistas.
--
-- Trae todo: extensiones, tablas, columnas calculadas, restricciones, índices, secuencias, funciones,
-- triggers, vistas y los datos iniciales (etapas, reglas de alerta, feriados, tipos de exploración,
-- grupos de Gestión GG). También el registro de migraciones de Django (django_migrations), para que
-- Django sepa que la base ya está creada.
--
-- Cómo cargarla en pgAdmin 4: crear una base VACÍA, abrir el Query Tool sobre ella, abrir este archivo
-- y ejecutarlo completo (F5). Requiere PostgreSQL 15 o más nuevo. No trae datos de clientes ni empleados.
--
-- OJO: las Partes 2 y 4 todavía son SQL y no migraciones de Django (falta la app gestion y pasar la
-- Parte 4 a la app rrhh). Hasta que lo sean, cualquier cambio a esas tablas hay que hacerlo también aquí.
-- ############################################################################

--
-- PostgreSQL database dump
--


-- Dumped from database version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: lab; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA lab;


--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: estado_ensayo; Type: TYPE; Schema: lab; Owner: -
--

CREATE TYPE lab.estado_ensayo AS ENUM (
    'pendiente',
    'en_proceso',
    'completado',
    'en_revision',
    'aprobado'
);


--
-- Name: estado_especimen; Type: TYPE; Schema: lab; Owner: -
--

CREATE TYPE lab.estado_especimen AS ENUM (
    'recibido',
    'almacenado',
    'ensayado'
);


--
-- Name: rol; Type: TYPE; Schema: lab; Owner: -
--

CREATE TYPE lab.rol AS ENUM (
    'administrador',
    'recepcion',
    'tecnico',
    'supervisor',
    'consulta'
);


--
-- Name: tipo_informe; Type: TYPE; Schema: lab; Owner: -
--

CREATE TYPE lab.tipo_informe AS ENUM (
    'diario',
    'mensual'
);


--
-- Name: area_mm2(numeric, numeric, numeric, numeric); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.area_mm2(d1 numeric, d2 numeric, largo numeric, ancho numeric) RETURNS numeric
    LANGUAGE sql IMMUTABLE
    AS $$
  select round(case
           when d1 is not null then pi() * power((d1 + coalesce(d2, d1)) / 2, 2) / 4  -- πd²/4
           else largo * ancho
         end::numeric, 2)
$$;


--
-- Name: empleado_actual(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.empleado_actual() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select id from public.nucleo_empleado where usuario_id = lab.usuario_actual() and activo
$$;


--
-- Name: fn_auditar(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.fn_auditar() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


--
-- Name: fn_compresion_defaults(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.fn_compresion_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: fn_ensayo_actualiza_especimen(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.fn_ensayo_actualiza_especimen() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.estado in ('completado', 'en_revision', 'aprobado') then
    update lab.especimenes set estado = 'ensayado'
     where id = new.especimen_id and estado <> 'ensayado';
  end if;
  return null;
end $$;


--
-- Name: fn_ensayo_reglas(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.fn_ensayo_reglas() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: fn_especimen_defaults(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.fn_especimen_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if new.fecha_ensayo_programada is null then
    select m.fecha_elaboracion + new.edad_programada_dias
      into new.fecha_ensayo_programada
      from lab.muestras m where m.id = new.muestra_id;
  end if;
  return new;
end $$;


--
-- Name: fn_proteger_aprobado(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.fn_proteger_aprobado() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: fn_registrar_movimiento(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.fn_registrar_movimiento() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.ubicacion_id is distinct from (case when tg_op = 'UPDATE' then old.ubicacion_id end) then
    insert into lab.movimientos_especimen (especimen_id, ubicacion_id, movido_por)
    values (new.id, new.ubicacion_id, lab.empleado_actual());
  end if;
  return null;
end $$;


--
-- Name: fn_tocar_actualizado(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.fn_tocar_actualizado() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.actualizado_en := now();
  return new;
end $$;


--
-- Name: motivo_correccion(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.motivo_correccion() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  select nullif(current_setting('lab.motivo_correccion', true), '')
$$;


--
-- Name: resistencia_kgcm2(numeric, numeric); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.resistencia_kgcm2(carga_kn numeric, area_mm2 numeric) RETURNS numeric
    LANGUAGE sql IMMUTABLE
    AS $$
  select case when area_mm2 > 0
              then round(carga_kn * 101.97162 / (area_mm2 / 100), 2) end
$$;


--
-- Name: tiene_algun_rol(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.tiene_algun_rol() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1 from lab.usuarios_roles ur
    join public.nucleo_empleado e on e.id = ur.empleado_id
    where e.usuario_id = lab.usuario_actual() and e.activo
  )
$$;


--
-- Name: tiene_rol(lab.rol[]); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.tiene_rol(VARIADIC p_roles lab.rol[]) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1
    from lab.usuarios_roles ur
    join public.nucleo_empleado e on e.id = ur.empleado_id
    where e.usuario_id = lab.usuario_actual()
      and e.activo
      and (ur.rol = any (p_roles) or ur.rol = 'administrador')
  )
$$;


--
-- Name: usuario_actual(); Type: FUNCTION; Schema: lab; Owner: -
--

CREATE FUNCTION lab.usuario_actual() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  select nullif(current_setting('lab.usuario_id', true), '')::uuid
$$;


--
-- Name: rrhh_fn_horaextradia_en_periodo(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rrhh_fn_horaextradia_en_periodo() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    v_inicio date;
    v_fin    date;
BEGIN
    SELECT periodo_inicio, periodo_fin INTO v_inicio, v_fin
      FROM public.rrhh_registrohoraextra WHERE id = NEW.registro_id;
    IF NEW.fecha < v_inicio OR NEW.fecha > v_fin THEN
        RAISE EXCEPTION 'La fecha % está fuera del período % al %.', NEW.fecha, v_inicio, v_fin;
    END IF;
    RETURN NEW;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: adjuntos; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.adjuntos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    entidad text NOT NULL,
    entidad_id uuid NOT NULL,
    storage_path text NOT NULL,
    nombre_original text,
    mime text,
    tamano_bytes bigint,
    subido_por uuid,
    subido_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT adjuntos_entidad_check CHECK ((entidad = ANY (ARRAY['remision'::text, 'muestra'::text, 'especimen'::text, 'ensayo'::text, 'informe'::text, 'equipo'::text])))
);


--
-- Name: areas; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.areas (
    id smallint NOT NULL,
    nombre text NOT NULL
);


--
-- Name: areas_id_seq; Type: SEQUENCE; Schema: lab; Owner: -
--

ALTER TABLE lab.areas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME lab.areas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auditoria; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.auditoria (
    id bigint NOT NULL,
    tabla text NOT NULL,
    registro_id text,
    accion text NOT NULL,
    antes jsonb,
    despues jsonb,
    motivo text,
    usuario_auth_id uuid,
    ocurrido_en timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: auditoria_id_seq; Type: SEQUENCE; Schema: lab; Owner: -
--

ALTER TABLE lab.auditoria ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME lab.auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: calibraciones; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.calibraciones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    equipo_id uuid NOT NULL,
    fecha date NOT NULL,
    vence date,
    entidad text,
    certificado_path text,
    observaciones text,
    CONSTRAINT calibraciones_check CHECK (((vence IS NULL) OR (vence >= fecha)))
);


--
-- Name: categorias_material; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.categorias_material (
    id smallint NOT NULL,
    area_id smallint NOT NULL,
    nombre text NOT NULL,
    activo boolean DEFAULT true NOT NULL
);


--
-- Name: categorias_material_id_seq; Type: SEQUENCE; Schema: lab; Owner: -
--

ALTER TABLE lab.categorias_material ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME lab.categorias_material_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ensayos; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.ensayos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    especimen_id uuid NOT NULL,
    metodo_id smallint NOT NULL,
    fecha_programada date NOT NULL,
    ejecutado_en timestamp with time zone,
    edad_real_dias smallint,
    tecnico_id uuid,
    equipo_id uuid,
    estado lab.estado_ensayo DEFAULT 'pendiente'::lab.estado_ensayo NOT NULL,
    origen text DEFAULT 'manual'::text NOT NULL,
    importacion_fila_id bigint,
    revisado_por uuid,
    revisado_en timestamp with time zone,
    aprobado_por uuid,
    aprobado_en timestamp with time zone,
    observaciones text,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ensayos_origen_check CHECK ((origen = ANY (ARRAY['manual'::text, 'importacion'::text])))
);


--
-- Name: equipos; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.equipos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    codigo text NOT NULL,
    nombre text NOT NULL,
    marca text,
    modelo text,
    serie text,
    tipo text,
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: especimenes; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.especimenes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    muestra_id uuid NOT NULL,
    proyecto_id uuid NOT NULL,
    tipo_especimen_id smallint NOT NULL,
    numero text NOT NULL,
    edad_programada_dias smallint NOT NULL,
    fecha_ensayo_programada date NOT NULL,
    peso_g numeric(9,2),
    diametro_1_mm numeric(7,2),
    diametro_2_mm numeric(7,2),
    altura_1_mm numeric(7,2),
    altura_2_mm numeric(7,2),
    largo_mm numeric(7,2),
    ancho_mm numeric(7,2),
    estado lab.estado_especimen DEFAULT 'recibido'::lab.estado_especimen NOT NULL,
    ubicacion_id uuid,
    observaciones text,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT especimenes_altura_1_mm_check CHECK ((altura_1_mm > (0)::numeric)),
    CONSTRAINT especimenes_altura_2_mm_check CHECK ((altura_2_mm > (0)::numeric)),
    CONSTRAINT especimenes_ancho_mm_check CHECK ((ancho_mm > (0)::numeric)),
    CONSTRAINT especimenes_diametro_1_mm_check CHECK ((diametro_1_mm > (0)::numeric)),
    CONSTRAINT especimenes_diametro_2_mm_check CHECK ((diametro_2_mm > (0)::numeric)),
    CONSTRAINT especimenes_edad_programada_dias_check CHECK ((edad_programada_dias > 0)),
    CONSTRAINT especimenes_largo_mm_check CHECK ((largo_mm > (0)::numeric)),
    CONSTRAINT especimenes_peso_g_check CHECK ((peso_g > (0)::numeric))
);


--
-- Name: importacion_filas; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.importacion_filas (
    id bigint NOT NULL,
    importacion_id uuid NOT NULL,
    numero_fila integer NOT NULL,
    datos jsonb NOT NULL,
    especimen_id uuid,
    estado text DEFAULT 'pendiente'::text NOT NULL,
    errores text[],
    CONSTRAINT importacion_filas_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'ok'::text, 'error'::text, 'duplicado'::text, 'aplicada'::text])))
);


--
-- Name: importacion_filas_id_seq; Type: SEQUENCE; Schema: lab; Owner: -
--

ALTER TABLE lab.importacion_filas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME lab.importacion_filas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: importaciones; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.importaciones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    equipo_id uuid,
    archivo_path text NOT NULL,
    archivo_sha256 text NOT NULL,
    estado text DEFAULT 'cargado'::text NOT NULL,
    filas_total integer,
    filas_validas integer,
    importado_por uuid,
    importado_en timestamp with time zone DEFAULT now() NOT NULL,
    notas text,
    CONSTRAINT importaciones_estado_check CHECK ((estado = ANY (ARRAY['cargado'::text, 'validado'::text, 'con_errores'::text, 'aplicado'::text, 'descartado'::text])))
);


--
-- Name: informe_ensayos; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.informe_ensayos (
    informe_id uuid NOT NULL,
    ensayo_id uuid NOT NULL
);


--
-- Name: informes; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.informes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    codigo text,
    tipo lab.tipo_informe NOT NULL,
    proyecto_id uuid,
    fecha_desde date NOT NULL,
    fecha_hasta date NOT NULL,
    conclusiones text,
    recomendaciones text,
    estado text DEFAULT 'borrador'::text NOT NULL,
    archivo_pdf_path text,
    datos_congelados jsonb,
    elaborado_por uuid,
    aprobado_por uuid,
    emitido_en timestamp with time zone,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT informes_check CHECK ((fecha_hasta >= fecha_desde)),
    CONSTRAINT informes_estado_check CHECK ((estado = ANY (ARRAY['borrador'::text, 'emitido'::text, 'anulado'::text])))
);


--
-- Name: mediciones; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.mediciones (
    id bigint NOT NULL,
    ensayo_id uuid NOT NULL,
    parametro_id smallint NOT NULL,
    repeticion smallint DEFAULT 1 NOT NULL,
    valor_num numeric,
    valor_texto text,
    CONSTRAINT mediciones_check CHECK (((valor_num IS NOT NULL) OR (valor_texto IS NOT NULL))),
    CONSTRAINT mediciones_repeticion_check CHECK ((repeticion >= 1))
);


--
-- Name: mediciones_id_seq; Type: SEQUENCE; Schema: lab; Owner: -
--

ALTER TABLE lab.mediciones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME lab.mediciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: metodo_tipos_especimen; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.metodo_tipos_especimen (
    metodo_id smallint NOT NULL,
    tipo_especimen_id smallint NOT NULL
);


--
-- Name: metodos_ensayo; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.metodos_ensayo (
    id smallint NOT NULL,
    nombre text NOT NULL,
    area_id smallint NOT NULL,
    norma_id smallint,
    tipo_resultado text NOT NULL,
    unidad_resultado text,
    activo boolean DEFAULT true NOT NULL,
    CONSTRAINT metodos_ensayo_tipo_resultado_check CHECK ((tipo_resultado = ANY (ARRAY['compresion'::text, 'generico'::text])))
);


--
-- Name: metodos_ensayo_id_seq; Type: SEQUENCE; Schema: lab; Owner: -
--

ALTER TABLE lab.metodos_ensayo ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME lab.metodos_ensayo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: movimientos_especimen; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.movimientos_especimen (
    id bigint NOT NULL,
    especimen_id uuid NOT NULL,
    ubicacion_id uuid,
    movido_en timestamp with time zone DEFAULT now() NOT NULL,
    movido_por uuid,
    nota text
);


--
-- Name: movimientos_especimen_id_seq; Type: SEQUENCE; Schema: lab; Owner: -
--

ALTER TABLE lab.movimientos_especimen ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME lab.movimientos_especimen_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: muestras; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.muestras (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    remision_id uuid NOT NULL,
    proyecto_id uuid NOT NULL,
    tipo_especimen_id smallint NOT NULL,
    elemento_colado text NOT NULL,
    fecha_elaboracion date NOT NULL,
    hora_elaboracion time without time zone,
    requisito_tipo text DEFAULT 'fc'::text NOT NULL,
    resistencia_requerida numeric(8,2),
    unidad_requerida text DEFAULT 'kg/cm2'::text NOT NULL,
    revenimiento_in numeric(5,2),
    temperatura_c numeric(5,2),
    proveedor_id uuid,
    comentario text,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT muestras_requisito_tipo_check CHECK ((requisito_tipo = ANY (ARRAY['fc'::text, 'mr'::text]))),
    CONSTRAINT muestras_resistencia_requerida_check CHECK ((resistencia_requerida > (0)::numeric))
);


--
-- Name: normas; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.normas (
    id smallint NOT NULL,
    codigo text NOT NULL,
    titulo text
);


--
-- Name: normas_id_seq; Type: SEQUENCE; Schema: lab; Owner: -
--

ALTER TABLE lab.normas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME lab.normas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: parametros_metodo; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.parametros_metodo (
    id smallint NOT NULL,
    metodo_id smallint NOT NULL,
    nombre text NOT NULL,
    unidad text,
    tipo_dato text DEFAULT 'numero'::text NOT NULL,
    requerido boolean DEFAULT true NOT NULL,
    repeticiones smallint DEFAULT 1 NOT NULL,
    es_resultado boolean DEFAULT false NOT NULL,
    valor_min numeric,
    valor_max numeric,
    orden smallint DEFAULT 0 NOT NULL,
    CONSTRAINT parametros_metodo_repeticiones_check CHECK ((repeticiones >= 1)),
    CONSTRAINT parametros_metodo_tipo_dato_check CHECK ((tipo_dato = ANY (ARRAY['numero'::text, 'texto'::text, 'booleano'::text])))
);


--
-- Name: parametros_metodo_id_seq; Type: SEQUENCE; Schema: lab; Owner: -
--

ALTER TABLE lab.parametros_metodo ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME lab.parametros_metodo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: proveedores_material; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.proveedores_material (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    nombre text NOT NULL,
    es_obra boolean DEFAULT false NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: remisiones; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.remisiones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    codigo text,
    formato text DEFAULT 'P8-REG03'::text NOT NULL,
    proyecto_id uuid NOT NULL,
    fecha_remision date NOT NULL,
    entregado_por_empleado uuid,
    entregado_por_nombre text,
    recibido_campo_por text,
    recibido_lab_por uuid,
    recibido_en timestamp with time zone,
    documento_path text,
    observaciones text,
    creado_por uuid,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: resultados_compresion; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.resultados_compresion (
    ensayo_id uuid NOT NULL,
    carga_kn numeric(10,2) NOT NULL,
    tipo_falla smallint,
    resistencia_requerida_kgcm2 numeric(8,2),
    area_mm2 numeric(10,2) NOT NULL,
    resistencia_kgcm2 numeric GENERATED ALWAYS AS (lab.resistencia_kgcm2(carga_kn, area_mm2)) STORED,
    resistencia_mpa numeric GENERATED ALWAYS AS (round(((carga_kn * (1000)::numeric) / NULLIF(area_mm2, (0)::numeric)), 2)) STORED,
    ganancia_pct numeric GENERATED ALWAYS AS (round(((lab.resistencia_kgcm2(carga_kn, area_mm2) / NULLIF(resistencia_requerida_kgcm2, (0)::numeric)) * (100)::numeric), 1)) STORED,
    actualizado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT resultados_compresion_area_mm2_check CHECK ((area_mm2 > (0)::numeric)),
    CONSTRAINT resultados_compresion_carga_kn_check CHECK ((carga_kn > (0)::numeric))
);


--
-- Name: tipos_especimen; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.tipos_especimen (
    id smallint NOT NULL,
    codigo text NOT NULL,
    nombre text NOT NULL,
    categoria_id smallint NOT NULL,
    forma text NOT NULL,
    notas text,
    activo boolean DEFAULT true NOT NULL,
    CONSTRAINT tipos_especimen_forma_check CHECK ((forma = ANY (ARRAY['cilindro'::text, 'cubo'::text, 'nucleo'::text, 'viga'::text])))
);


--
-- Name: tipos_especimen_id_seq; Type: SEQUENCE; Schema: lab; Owner: -
--

ALTER TABLE lab.tipos_especimen ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME lab.tipos_especimen_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tipos_falla; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.tipos_falla (
    codigo smallint NOT NULL,
    descripcion text NOT NULL
);


--
-- Name: ubicaciones; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.ubicaciones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    padre_id uuid,
    tipo text NOT NULL,
    codigo text NOT NULL,
    nombre text,
    activa boolean DEFAULT true NOT NULL,
    CONSTRAINT ubicaciones_tipo_check CHECK ((tipo = ANY (ARRAY['bidon'::text, 'estante'::text, 'peldano'::text])))
);


--
-- Name: usuarios_roles; Type: TABLE; Schema: lab; Owner: -
--

CREATE TABLE lab.usuarios_roles (
    empleado_id uuid NOT NULL,
    rol lab.rol NOT NULL,
    asignado_en timestamp with time zone DEFAULT now() NOT NULL,
    asignado_por uuid
);


--
-- Name: v_curva_resistencia; Type: VIEW; Schema: lab; Owner: -
--

CREATE VIEW lab.v_curva_resistencia WITH (security_invoker='true') AS
 SELECT m.proyecto_id,
    m.id AS muestra_id,
    m.elemento_colado,
    m.fecha_elaboracion AS fecha_colado,
    m.resistencia_requerida,
    en.edad_real_dias AS edad,
    count(*) AS n_especimenes,
    round(avg(r.resistencia_kgcm2), 2) AS resistencia_promedio,
    round(avg(r.ganancia_pct), 1) AS ganancia_promedio
   FROM (((lab.resultados_compresion r
     JOIN lab.ensayos en ON ((en.id = r.ensayo_id)))
     JOIN lab.especimenes e ON ((e.id = en.especimen_id)))
     JOIN lab.muestras m ON ((m.id = e.muestra_id)))
  GROUP BY m.proyecto_id, m.id, m.elemento_colado, m.fecha_elaboracion, m.resistencia_requerida, en.edad_real_dias;


--
-- Name: nucleo_proyecto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_proyecto (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    nombre character varying(255) NOT NULL,
    codigo character varying(50),
    fecha_inicio date,
    fecha_fin date,
    descripcion text,
    costo_base numeric(14,4),
    costo_extra_diurno numeric(14,4),
    costo_extra_nocturno numeric(14,4),
    estado character varying(20),
    ingeniero_supervisor character varying(255),
    cliente_id uuid,
    ubicacion text,
    CONSTRAINT proyecto_costos_no_negativos CHECK (((costo_base >= (0)::numeric) AND (costo_extra_diurno >= (0)::numeric) AND (costo_extra_nocturno >= (0)::numeric))),
    CONSTRAINT proyecto_estado_valido CHECK (((estado)::text = ANY ((ARRAY['no_iniciado'::character varying, 'en_progreso'::character varying, 'completado'::character varying])::text[]))),
    CONSTRAINT proyecto_fechas_en_orden CHECK ((fecha_fin >= fecha_inicio))
);


--
-- Name: v_programacion_ensayos; Type: VIEW; Schema: lab; Owner: -
--

CREATE VIEW lab.v_programacion_ensayos WITH (security_invoker='true') AS
 SELECT e.id AS especimen_id,
    e.fecha_ensayo_programada,
    p.nombre AS proyecto,
    e.numero,
    m.fecha_elaboracion AS fecha_colado,
    e.edad_programada_dias AS edad,
    te.codigo AS tipo,
    m.resistencia_requerida,
    m.requisito_tipo,
    u.codigo AS ubicacion,
    e.estado
   FROM ((((lab.especimenes e
     JOIN lab.muestras m ON ((m.id = e.muestra_id)))
     JOIN public.nucleo_proyecto p ON ((p.id = e.proyecto_id)))
     JOIN lab.tipos_especimen te ON ((te.id = e.tipo_especimen_id)))
     LEFT JOIN lab.ubicaciones u ON ((u.id = e.ubicacion_id)))
  WHERE (e.estado = ANY (ARRAY['recibido'::lab.estado_especimen, 'almacenado'::lab.estado_especimen]));


--
-- Name: nucleo_cliente; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_cliente (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    ruc character varying(50) NOT NULL,
    razon_social character varying(255) NOT NULL,
    contacto character varying(255) NOT NULL,
    telefono character varying(30),
    email character varying(254),
    direccion text,
    notas text,
    dui character varying(20),
    nit character varying(20),
    tipo_persona character varying(10),
    CONSTRAINT cliente_documento_segun_tipo CHECK (((tipo_persona IS NULL) OR ((nit IS NOT NULL) AND ((tipo_persona)::text = 'juridica'::text)) OR ((dui IS NOT NULL) AND ((tipo_persona)::text = 'natural'::text)))),
    CONSTRAINT cliente_tipo_persona_valido CHECK (((tipo_persona)::text = ANY ((ARRAY['natural'::character varying, 'juridica'::character varying])::text[])))
);


--
-- Name: v_resultados_compresion; Type: VIEW; Schema: lab; Owner: -
--

CREATE VIEW lab.v_resultados_compresion WITH (security_invoker='true') AS
 SELECT en.id AS ensayo_id,
    c.razon_social AS cliente,
    p.nombre AS proyecto,
    m.elemento_colado,
    te.codigo AS tipo,
    e.numero AS especimen,
    m.fecha_elaboracion AS fecha_colado,
    (en.ejecutado_en)::date AS fecha_ensayo,
    en.edad_real_dias AS edad,
    e.peso_g,
    round(((e.diametro_1_mm + COALESCE(e.diametro_2_mm, e.diametro_1_mm)) / (2)::numeric), 2) AS diametro_prom_mm,
    round(((e.altura_1_mm + COALESCE(e.altura_2_mm, e.altura_1_mm)) / (2)::numeric), 2) AS altura_prom_mm,
    r.area_mm2,
    r.carga_kn,
    r.resistencia_kgcm2,
    r.resistencia_mpa,
    r.resistencia_requerida_kgcm2,
    r.ganancia_pct,
    r.tipo_falla,
    en.estado
   FROM ((((((lab.ensayos en
     JOIN lab.resultados_compresion r ON ((r.ensayo_id = en.id)))
     JOIN lab.especimenes e ON ((e.id = en.especimen_id)))
     JOIN lab.muestras m ON ((m.id = e.muestra_id)))
     JOIN lab.tipos_especimen te ON ((te.id = e.tipo_especimen_id)))
     JOIN public.nucleo_proyecto p ON ((p.id = e.proyecto_id)))
     LEFT JOIN public.nucleo_cliente c ON ((c.id = p.cliente_id)));


--
-- Name: auth_group; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_group (
    id integer NOT NULL,
    name character varying(150) NOT NULL
);


--
-- Name: auth_group_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.auth_group ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_group_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_group_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_group_permissions (
    id bigint NOT NULL,
    group_id integer NOT NULL,
    permission_id integer NOT NULL
);


--
-- Name: auth_group_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.auth_group_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_group_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_permission; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_permission (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    content_type_id integer NOT NULL,
    codename character varying(100) NOT NULL
);


--
-- Name: auth_permission_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.auth_permission ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_permission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_admin_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.django_admin_log (
    id integer NOT NULL,
    action_time timestamp with time zone NOT NULL,
    object_id text,
    object_repr character varying(200) NOT NULL,
    action_flag smallint NOT NULL,
    change_message text NOT NULL,
    content_type_id integer,
    user_id uuid NOT NULL,
    CONSTRAINT django_admin_log_action_flag_check CHECK ((action_flag >= 0))
);


--
-- Name: django_admin_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.django_admin_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_admin_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_content_type; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.django_content_type (
    id integer NOT NULL,
    app_label character varying(100) NOT NULL,
    model character varying(100) NOT NULL
);


--
-- Name: django_content_type_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.django_content_type ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_content_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.django_migrations (
    id bigint NOT NULL,
    app character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    applied timestamp with time zone NOT NULL
);


--
-- Name: django_migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.django_migrations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_migrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_session; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.django_session (
    session_key character varying(40) NOT NULL,
    session_data text NOT NULL,
    expire_date timestamp with time zone NOT NULL
);


--
-- Name: finanzas_cuentaporcobrar; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.finanzas_cuentaporcobrar (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    numero_factura character varying(50) NOT NULL,
    fecha_emision date NOT NULL,
    fecha_vencimiento date NOT NULL,
    subtotal numeric(14,4),
    impuesto numeric(14,4),
    total numeric(14,4),
    pagado numeric(14,4) NOT NULL,
    saldo numeric(14,4) NOT NULL,
    estado character varying(20) NOT NULL,
    notas text,
    proforma_id uuid,
    CONSTRAINT cuenta_estado_valido CHECK (((estado)::text = ANY ((ARRAY['pendiente'::character varying, 'vencida'::character varying, 'pagada'::character varying])::text[]))),
    CONSTRAINT cuenta_montos_no_negativos CHECK (((subtotal >= (0)::numeric) AND (impuesto >= (0)::numeric) AND (total >= (0)::numeric) AND (pagado >= (0)::numeric)))
);


--
-- Name: finanzas_cuentaporcobraritem; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.finanzas_cuentaporcobraritem (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(40),
    posicion integer DEFAULT 0 NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    cantidad numeric(14,4),
    costo_unitario numeric(14,4),
    subtotal numeric(14,4),
    cuenta_id uuid NOT NULL,
    servicio_id uuid,
    CONSTRAINT cuenta_item_cantidad_positiva CHECK ((cantidad > (0)::numeric)),
    CONSTRAINT cuenta_item_montos_no_negativos CHECK (((costo_unitario >= (0)::numeric) AND (subtotal >= (0)::numeric))),
    CONSTRAINT finanzas_cuentaporcobraritem_posicion_check CHECK ((posicion >= 0))
);


--
-- Name: finanzas_pago; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.finanzas_pago (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(40),
    posicion integer DEFAULT 0 NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    fecha date,
    comprobante_url character varying(1000),
    cloudinary_id character varying(255),
    monto numeric(14,4),
    metodo character varying(50),
    notas text,
    cuenta_id uuid NOT NULL,
    CONSTRAINT finanzas_pago_posicion_check CHECK ((posicion >= 0)),
    CONSTRAINT pago_monto_positivo CHECK ((monto > (0)::numeric))
);


--
-- Name: finanzas_proforma; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.finanzas_proforma (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    fecha_emision date,
    cargos_horas_extra numeric(14,4),
    cargos_adicionales numeric(14,4),
    costo_base_proyecto numeric(14,4) DEFAULT 0 NOT NULL,
    total numeric(14,4),
    estado character varying(20),
    aprobada_en timestamp with time zone,
    notas text,
    enviada_en timestamp with time zone,
    enviada_a character varying(254),
    cliente_id uuid,
    proyecto_id uuid,
    CONSTRAINT proforma_estado_valido CHECK (((estado)::text = ANY ((ARRAY['aprobada'::character varying, 'pendiente'::character varying, 'rechazada'::character varying])::text[]))),
    CONSTRAINT proforma_montos_no_negativos CHECK (((cargos_horas_extra >= (0)::numeric) AND (cargos_adicionales >= (0)::numeric) AND (costo_base_proyecto >= (0)::numeric) AND (total >= (0)::numeric)))
);


--
-- Name: finanzas_proformaitem; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.finanzas_proformaitem (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(40),
    posicion integer DEFAULT 0 NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    cantidad numeric(14,4),
    costo_unitario numeric(14,4),
    subtotal numeric(14,4),
    proforma_id uuid NOT NULL,
    servicio_id uuid,
    CONSTRAINT finanzas_proformaitem_posicion_check CHECK ((posicion >= 0)),
    CONSTRAINT proforma_item_cantidad_positiva CHECK ((cantidad > (0)::numeric)),
    CONSTRAINT proforma_item_montos_no_negativos CHECK (((costo_unitario >= (0)::numeric) AND (subtotal >= (0)::numeric)))
);


--
-- Name: gestion_alerta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_alerta (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    severidad character varying(12) NOT NULL,
    mensaje text NOT NULL,
    generada_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    estado character varying(15) DEFAULT 'abierta'::character varying NOT NULL,
    pospuesta_hasta timestamp with time zone,
    atendida_en timestamp with time zone,
    nota_atencion text,
    correo_enviado_en timestamp with time zone,
    regla_id uuid NOT NULL,
    expediente_id uuid,
    oferta_id uuid,
    solicitud_id uuid,
    atendida_por_id uuid,
    CONSTRAINT alerta_atendida_con_nota CHECK ((((estado)::text <> 'atendida'::text) OR ((atendida_en IS NOT NULL) AND (atendida_por_id IS NOT NULL) AND (nota_atencion IS NOT NULL)))),
    CONSTRAINT alerta_estado_valido CHECK (((estado)::text = ANY ((ARRAY['abierta'::character varying, 'vista'::character varying, 'pospuesta'::character varying, 'atendida'::character varying, 'resuelta_sola'::character varying])::text[]))),
    CONSTRAINT alerta_pospuesta_con_fecha CHECK ((((estado)::text <> 'pospuesta'::text) OR (pospuesta_hasta IS NOT NULL))),
    CONSTRAINT alerta_severidad_valida CHECK (((severidad)::text = ANY ((ARRAY['aviso'::character varying, 'advertencia'::character varying, 'critica'::character varying])::text[]))),
    CONSTRAINT alerta_un_objeto CHECK ((num_nonnulls(expediente_id, oferta_id, solicitud_id) = 1))
);


--
-- Name: gestion_cambio; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_cambio (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    cambiado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    campo character varying(20) NOT NULL,
    valor_anterior text,
    valor_nuevo text,
    motivo text NOT NULL,
    expediente_id uuid NOT NULL,
    usuario_id uuid NOT NULL,
    CONSTRAINT cambio_campo_valido CHECK (((campo)::text = ANY ((ARRAY['prioridad'::character varying, 'fecha_limite'::character varying, 'fecha_informe_meta'::character varying, 'fecha_limite_lab'::character varying, 'etapa'::character varying, 'otro'::character varying])::text[]))),
    CONSTRAINT cambio_motivo_obligatorio CHECK ((length(btrim(motivo)) > 0))
);


--
-- Name: gestion_cuadrilla; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_cuadrilla (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    nombre character varying(100) NOT NULL,
    tipo character varying(12) NOT NULL,
    activa boolean DEFAULT true NOT NULL,
    jefe_id uuid,
    CONSTRAINT cuadrilla_tipo_valido CHECK (((tipo)::text = ANY ((ARRAY['spt'::character varying, 'rotativa'::character varying, 'geofisica'::character varying, 'general'::character varying])::text[])))
);


--
-- Name: gestion_cuadrilla_miembros; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_cuadrilla_miembros (
    id bigint NOT NULL,
    cuadrilla_id uuid NOT NULL,
    empleado_id uuid NOT NULL
);


--
-- Name: gestion_cuadrilla_miembros_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.gestion_cuadrilla_miembros ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.gestion_cuadrilla_miembros_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: gestion_ensayo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_ensayo (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    cantidad numeric(14,4) NOT NULL,
    cantidad_hecha numeric(14,4) DEFAULT 0 NOT NULL,
    ejecucion character varying(10) DEFAULT 'interna'::character varying NOT NULL,
    estado character varying(20) DEFAULT 'pendiente'::character varying NOT NULL,
    fecha_objetivo date,
    terminado_en timestamp with time zone,
    expediente_id uuid NOT NULL,
    servicio_id uuid NOT NULL,
    punto_id uuid,
    envio_id uuid,
    CONSTRAINT ensayo_cantidades_validas CHECK (((cantidad > (0)::numeric) AND (cantidad_hecha >= (0)::numeric) AND (cantidad_hecha <= cantidad))),
    CONSTRAINT ensayo_ejecucion_valida CHECK (((ejecucion)::text = ANY ((ARRAY['interna'::character varying, 'externa'::character varying])::text[]))),
    CONSTRAINT ensayo_envio_solo_externo CHECK ((((ejecucion)::text = 'externa'::text) OR (envio_id IS NULL))),
    CONSTRAINT ensayo_estado_valido CHECK (((estado)::text = ANY ((ARRAY['pendiente'::character varying, 'en_proceso'::character varying, 'enviado'::character varying, 'resultado_recibido'::character varying, 'terminado'::character varying])::text[]))),
    CONSTRAINT ensayo_terminado_con_fecha CHECK ((((estado)::text <> 'terminado'::text) OR (terminado_en IS NOT NULL)))
);


--
-- Name: gestion_entregable; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_entregable (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    posicion integer DEFAULT 0 NOT NULL,
    tipo character varying(20) DEFAULT 'informe_final'::character varying NOT NULL,
    plazo_dias smallint NOT NULL,
    plazo_tipo character varying(12) DEFAULT 'habiles'::character varying NOT NULL,
    evento_inicio character varying(20) DEFAULT 'anticipo'::character varying NOT NULL,
    fecha_inicio_conteo date,
    fecha_limite date,
    fecha_meta date,
    entregado_en timestamp with time zone,
    codigo_informe character varying(50),
    informe_url character varying(1000),
    lote_id uuid NOT NULL,
    CONSTRAINT entregable_entregado_con_codigo CHECK (((entregado_en IS NULL) OR (codigo_informe IS NOT NULL))),
    CONSTRAINT entregable_evento_valido CHECK (((evento_inicio)::text = ANY ((ARRAY['anticipo'::character varying, 'orden_inicio'::character varying, 'inicio_campo'::character varying, 'fin_campo'::character varying, 'entrega_anterior'::character varying])::text[]))),
    CONSTRAINT entregable_fechas_en_orden CHECK (((fecha_limite >= fecha_inicio_conteo) AND (fecha_meta <= fecha_limite))),
    CONSTRAINT entregable_plazo_positivo CHECK ((plazo_dias > 0)),
    CONSTRAINT entregable_plazo_tipo_valido CHECK (((plazo_tipo)::text = ANY ((ARRAY['habiles'::character varying, 'calendario'::character varying])::text[]))),
    CONSTRAINT entregable_posicion_check CHECK ((posicion >= 0)),
    CONSTRAINT entregable_tipo_valido CHECK (((tipo)::text = ANY ((ARRAY['preliminar'::character varying, 'laboratorio'::character varying, 'informe_final'::character varying, 'diseno'::character varying, 'otro'::character varying])::text[])))
);


--
-- Name: gestion_envioexterno; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_envioexterno (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    enviado_en timestamp with time zone NOT NULL,
    compromiso_en date,
    resultado_en timestamp with time zone,
    solicitud_url character varying(1000),
    nota text,
    laboratorio_id uuid NOT NULL,
    expediente_id uuid NOT NULL,
    CONSTRAINT envioexterno_fechas_en_orden CHECK ((resultado_en >= enviado_en))
);


--
-- Name: gestion_etapaconfig; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_etapaconfig (
    etapa character varying(30) NOT NULL,
    posicion smallint NOT NULL,
    nombre character varying(100) NOT NULL,
    grupo_responsable character varying(150) NOT NULL,
    tiempo_objetivo smallint,
    tipo_dias character varying(12),
    es_supuesto boolean DEFAULT true NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    CONSTRAINT etapaconfig_etapa_valida CHECK (((etapa)::text = ANY ((ARRAY['solicitud'::character varying, 'oferta_enviada'::character varying, 'aceptada'::character varying, 'anticipo_confirmado'::character varying, 'programada'::character varying, 'campo_en_ejecucion'::character varying, 'campo_completo'::character varying, 'muestras_completas'::character varying, 'laboratorio'::character varying, 'gabinete'::character varying, 'saldo_pagado'::character varying, 'entregado'::character varying])::text[]))),
    CONSTRAINT etapaconfig_tiempo_positivo CHECK ((tiempo_objetivo > 0)),
    CONSTRAINT etapaconfig_tipo_dias_valido CHECK (((tipo_dias)::text = ANY ((ARRAY['habiles'::character varying, 'calendario'::character varying])::text[])))
);


--
-- Name: gestion_eventoetapa; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_eventoetapa (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    etapa character varying(30) NOT NULL,
    iniciada_en timestamp with time zone NOT NULL,
    cerrada_en timestamp with time zone,
    nota text,
    expediente_id uuid NOT NULL,
    registrado_por_id uuid,
    CONSTRAINT eventoetapa_fechas_en_orden CHECK ((cerrada_en >= iniciada_en))
);


--
-- Name: gestion_expediente; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_expediente (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    etapa character varying(30) DEFAULT 'aceptada'::character varying NOT NULL,
    prioridad character varying(10) DEFAULT 'normal'::character varying NOT NULL,
    aceptada_en timestamp with time zone NOT NULL,
    anticipo_confirmado_en timestamp with time zone,
    fecha_limite_cliente date,
    fecha_informe_meta date,
    fecha_limite_lab date,
    saldo_pagado_en timestamp with time zone,
    carpeta_url character varying(1000),
    cerrado_en timestamp with time zone,
    lote_id uuid NOT NULL,
    oferta_id uuid NOT NULL,
    proyecto_id uuid,
    responsable_id uuid,
    anticipo_cxc_id uuid,
    saldo_cxc_id uuid,
    sin_anticipo_autorizado_por_id uuid,
    entrega_sin_saldo_por_id uuid,
    CONSTRAINT expediente_anticipo_antes_de_programar CHECK ((((etapa)::text = ANY ((ARRAY['aceptada'::character varying, 'cancelado'::character varying])::text[])) OR (anticipo_confirmado_en IS NOT NULL) OR (sin_anticipo_autorizado_por_id IS NOT NULL))),
    CONSTRAINT expediente_etapa_valida CHECK (((etapa)::text = ANY ((ARRAY['aceptada'::character varying, 'anticipo_confirmado'::character varying, 'programada'::character varying, 'campo_en_ejecucion'::character varying, 'campo_completo'::character varying, 'muestras_completas'::character varying, 'laboratorio'::character varying, 'gabinete'::character varying, 'saldo_pagado'::character varying, 'entregado'::character varying, 'cancelado'::character varying])::text[]))),
    CONSTRAINT expediente_fechas_en_orden CHECK (((fecha_limite_lab <= fecha_informe_meta) AND (fecha_informe_meta <= fecha_limite_cliente))),
    CONSTRAINT expediente_prioridad_valida CHECK (((prioridad)::text = ANY ((ARRAY['normal'::character varying, 'alta'::character varying, 'urgente'::character varying])::text[]))),
    CONSTRAINT expediente_saldo_antes_de_entregar CHECK ((((etapa)::text <> 'entregado'::text) OR (saldo_pagado_en IS NOT NULL) OR (entrega_sin_saldo_por_id IS NOT NULL)))
);


--
-- Name: gestion_feriado; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_feriado (
    fecha date NOT NULL,
    nombre character varying(150) NOT NULL,
    es_supuesto boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL
);


--
-- Name: gestion_fotocampo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_fotocampo (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    tomada_en timestamp with time zone,
    avance_id uuid NOT NULL,
    programacion_id uuid,
    recepcion_id uuid,
    punto_id uuid,
    CONSTRAINT fotocampo_con_destino CHECK (((programacion_id IS NOT NULL) OR (recepcion_id IS NOT NULL)))
);


--
-- Name: gestion_laboratorioexterno; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_laboratorioexterno (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    nombre character varying(255) NOT NULL,
    contacto character varying(255),
    telefono character varying(30),
    email character varying(254),
    ensayos text,
    activo boolean DEFAULT true NOT NULL
);


--
-- Name: gestion_oferta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_oferta (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    prefijo character varying(2) DEFAULT 'GG'::character varying NOT NULL,
    anio smallint NOT NULL,
    correlativo integer NOT NULL,
    codigo character varying(20) NOT NULL,
    formato character varying(10) DEFAULT 'largo'::character varying NOT NULL,
    estado character varying(20) DEFAULT 'borrador'::character varying NOT NULL,
    nombre_proyecto character varying(255) NOT NULL,
    direccion text,
    en_atencion_a character varying(255),
    vigencia_dias smallint DEFAULT 15 NOT NULL,
    anticipo_pct numeric(5,2) DEFAULT 50 NOT NULL,
    pago_contra_entrega boolean DEFAULT false NOT NULL,
    monto_total numeric(14,4),
    enviada_en timestamp with time zone,
    aceptada_en timestamp with time zone,
    medio_aceptacion character varying(20),
    aceptacion_url character varying(1000),
    motivo_rechazo text,
    reactivada_en timestamp with time zone,
    precio_reactivacion character varying(20),
    carpeta_url character varying(1000),
    solicitud_id uuid,
    cliente_id uuid,
    departamento_id uuid,
    proyecto_id uuid,
    proforma_id uuid,
    CONSTRAINT oferta_aceptada_con_fecha CHECK ((((estado)::text <> ALL ((ARRAY['aceptada'::character varying, 'aceptada_parcial'::character varying])::text[])) OR (aceptada_en IS NOT NULL))),
    CONSTRAINT oferta_anticipo_0_a_100 CHECK (((anticipo_pct >= (0)::numeric) AND (anticipo_pct <= (100)::numeric))),
    CONSTRAINT oferta_codigo_formato CHECK (((codigo)::text = ((((('JP-'::text || (prefijo)::text) || '-'::text) || (anio)::text) || '-'::text) || lpad((correlativo)::text, GREATEST(3, length((correlativo)::text)), '0'::text)))),
    CONSTRAINT oferta_estado_valido CHECK (((estado)::text = ANY ((ARRAY['borrador'::character varying, 'enviada'::character varying, 'aceptada'::character varying, 'aceptada_parcial'::character varying, 'rechazada'::character varying, 'vencida'::character varying])::text[]))),
    CONSTRAINT oferta_formato_valido CHECK (((formato)::text = ANY ((ARRAY['largo'::character varying, 'carta'::character varying])::text[]))),
    CONSTRAINT oferta_medio_aceptacion_valido CHECK (((medio_aceptacion)::text = ANY ((ARRAY['correo'::character varying, 'recuadro_firmado'::character varying, 'whatsapp'::character varying, 'otro'::character varying])::text[]))),
    CONSTRAINT oferta_precio_reactivacion_valido CHECK (((precio_reactivacion)::text = ANY ((ARRAY['mantiene'::character varying, 'nueva_edicion'::character varying])::text[]))),
    CONSTRAINT oferta_prefijo_valido CHECK (((prefijo)::text = ANY ((ARRAY['GG'::character varying, 'DC'::character varying, 'CC'::character varying])::text[]))),
    CONSTRAINT oferta_valores_no_negativos CHECK (((monto_total >= (0)::numeric) AND (vigencia_dias > 0) AND (correlativo > 0)))
);


--
-- Name: gestion_ofertaedicion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_ofertaedicion (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    edicion numeric(3,1) NOT NULL,
    fecha_emision date NOT NULL,
    motivo text,
    monto numeric(14,4),
    pdf_url character varying(1000),
    editable_url character varying(1000),
    enviada_en timestamp with time zone,
    canal_envio character varying(20),
    oferta_id uuid NOT NULL,
    CONSTRAINT ofertaedicion_canal_valido CHECK (((canal_envio)::text = ANY ((ARRAY['correo'::character varying, 'whatsapp'::character varying, 'enlace'::character varying, 'en_persona'::character varying])::text[]))),
    CONSTRAINT ofertaedicion_valores_validos CHECK (((edicion >= (1)::numeric) AND (monto >= (0)::numeric)))
);


--
-- Name: gestion_ofertaitem; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_ofertaitem (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    posicion integer DEFAULT 0 NOT NULL,
    descripcion character varying(255) NOT NULL,
    unidad character varying(30) NOT NULL,
    cantidad numeric(14,4) NOT NULL,
    costo_unitario numeric(14,4),
    subtotal numeric(14,4),
    profundidad_m numeric(6,2),
    costo_metro_adicional numeric(14,4),
    ejecucion_prevista character varying(10) DEFAULT 'interna'::character varying NOT NULL,
    lote_id uuid NOT NULL,
    servicio_id uuid,
    CONSTRAINT ofertaitem_cantidad_positiva CHECK ((cantidad > (0)::numeric)),
    CONSTRAINT ofertaitem_ejecucion_valida CHECK (((ejecucion_prevista)::text = ANY ((ARRAY['interna'::character varying, 'externa'::character varying])::text[]))),
    CONSTRAINT ofertaitem_montos_no_negativos CHECK (((costo_unitario >= (0)::numeric) AND (subtotal >= (0)::numeric) AND (costo_metro_adicional >= (0)::numeric))),
    CONSTRAINT ofertaitem_posicion_check CHECK ((posicion >= 0)),
    CONSTRAINT ofertaitem_profundidad_positiva CHECK ((profundidad_m > (0)::numeric))
);


--
-- Name: gestion_ofertalote; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_ofertalote (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    posicion integer DEFAULT 0 NOT NULL,
    nombre character varying(150) DEFAULT 'Único'::character varying NOT NULL,
    codigo_cliente character varying(50),
    oferta_id uuid NOT NULL,
    CONSTRAINT ofertalote_posicion_check CHECK ((posicion >= 0))
);


--
-- Name: gestion_programacion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_programacion (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    fecha date NOT NULL,
    actividad character varying(255) NOT NULL,
    estado character varying(15) DEFAULT 'programada'::character varying NOT NULL,
    motivo text,
    mensaje_cuadrilla text,
    hora_salida time without time zone,
    hora_llegada time without time zone,
    expediente_id uuid,
    cuadrilla_id uuid NOT NULL,
    reprograma_a_id uuid,
    registrado_por_id uuid,
    CONSTRAINT programacion_estado_valido CHECK (((estado)::text = ANY ((ARRAY['programada'::character varying, 'en_ejecucion'::character varying, 'ejecutada'::character varying, 'incompleta'::character varying, 'reprogramada'::character varying, 'cancelada'::character varying])::text[]))),
    CONSTRAINT programacion_reprogramada_con_destino CHECK ((((estado)::text <> 'reprogramada'::text) OR (reprograma_a_id IS NOT NULL)))
);


--
-- Name: gestion_punto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_punto (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    codigo character varying(20) NOT NULL,
    tipo character varying(15) NOT NULL,
    profundidad_ofertada_m numeric(6,2),
    profundidad_ejecutada_m numeric(6,2),
    estado character varying(12) DEFAULT 'pendiente'::character varying NOT NULL,
    ejecutado_en timestamp with time zone,
    muestras_esperadas smallint,
    permiso_cliente_en timestamp with time zone,
    permiso_hasta_m numeric(6,2),
    observacion text,
    expediente_id uuid NOT NULL,
    ofertaitem_id uuid,
    programacion_id uuid,
    punto_origen_id uuid,
    CONSTRAINT punto_ejecutado_con_fecha CHECK ((((estado)::text <> ALL ((ARRAY['ejecutado'::character varying, 'rechazo'::character varying])::text[])) OR (ejecutado_en IS NOT NULL))),
    CONSTRAINT punto_estado_valido CHECK (((estado)::text = ANY ((ARRAY['pendiente'::character varying, 'ejecutado'::character varying, 'rechazo'::character varying, 'cancelado'::character varying])::text[]))),
    CONSTRAINT punto_metraje_adicional_con_permiso CHECK (((profundidad_ejecutada_m IS NULL) OR (profundidad_ofertada_m IS NULL) OR (profundidad_ejecutada_m <= profundidad_ofertada_m) OR (permiso_cliente_en IS NOT NULL))),
    CONSTRAINT punto_valores_no_negativos CHECK (((profundidad_ofertada_m > (0)::numeric) AND (profundidad_ejecutada_m >= (0)::numeric) AND (muestras_esperadas >= 0)))
);


--
-- Name: gestion_recepcion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_recepcion (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    entregada_en timestamp with time zone NOT NULL,
    muestreo_por character varying(10) DEFAULT 'propio'::character varying NOT NULL,
    empresa_muestreo character varying(255),
    estado character varying(20) DEFAULT 'por_verificar'::character varying NOT NULL,
    sacos smallint,
    observaciones text,
    verificada_en timestamp with time zone,
    expediente_id uuid NOT NULL,
    cuadrilla_id uuid,
    registrado_por_id uuid NOT NULL,
    verificada_por_id uuid,
    CONSTRAINT recepcion_estado_valido CHECK (((estado)::text = ANY ((ARRAY['por_verificar'::character varying, 'verificada'::character varying, 'con_diferencias'::character varying])::text[]))),
    CONSTRAINT recepcion_externo_con_empresa CHECK ((((muestreo_por)::text = 'propio'::text) OR (empresa_muestreo IS NOT NULL))),
    CONSTRAINT recepcion_muestreo_valido CHECK (((muestreo_por)::text = ANY ((ARRAY['propio'::character varying, 'externo'::character varying])::text[]))),
    CONSTRAINT recepcion_sacos_no_negativos CHECK ((sacos >= 0)),
    CONSTRAINT recepcion_verificada_con_firma CHECK ((((estado)::text = 'por_verificar'::text) OR ((verificada_en IS NOT NULL) AND (verificada_por_id IS NOT NULL))))
);


--
-- Name: gestion_recepcionpunto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_recepcionpunto (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    muestras_entregadas smallint NOT NULL,
    muestras_verificadas smallint,
    recepcion_id uuid NOT NULL,
    punto_id uuid NOT NULL,
    CONSTRAINT recepcionpunto_muestras_no_negativas CHECK (((muestras_entregadas >= 0) AND (muestras_verificadas >= 0)))
);


--
-- Name: gestion_reglaalerta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_reglaalerta (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    codigo character varying(5) NOT NULL,
    nombre character varying(150) NOT NULL,
    condicion text NOT NULL,
    umbral smallint,
    umbral_tipo character varying(12),
    severidad character varying(12) NOT NULL,
    grupos_destino jsonb DEFAULT '[]'::jsonb NOT NULL,
    medio character varying(20) DEFAULT 'sistema'::character varying NOT NULL,
    activa boolean DEFAULT true NOT NULL,
    es_supuesto boolean DEFAULT true NOT NULL,
    etapa character varying(30),
    CONSTRAINT reglaalerta_medio_valido CHECK (((medio)::text = ANY ((ARRAY['sistema'::character varying, 'sistema_correo'::character varying])::text[]))),
    CONSTRAINT reglaalerta_severidad_valida CHECK (((severidad)::text = ANY ((ARRAY['aviso'::character varying, 'advertencia'::character varying, 'critica'::character varying])::text[]))),
    CONSTRAINT reglaalerta_umbral_no_negativo CHECK ((umbral >= 0)),
    CONSTRAINT reglaalerta_umbral_tipo_valido CHECK (((umbral_tipo)::text = ANY ((ARRAY['habiles'::character varying, 'calendario'::character varying, 'dias'::character varying, 'horas'::character varying])::text[])))
);


--
-- Name: gestion_servicioconfig; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_servicioconfig (
    servicio_id uuid NOT NULL,
    norma character varying(100),
    muestras_por_metro numeric(5,2),
    rendimiento_diario numeric(10,2),
    unidad_rendimiento character varying(20),
    horas_minimas smallint,
    dias_extra smallint DEFAULT 0 NOT NULL,
    requiere_laboratorio boolean DEFAULT true NOT NULL,
    es_insumo boolean DEFAULT false NOT NULL,
    ejecucion_habitual character varying(10) DEFAULT 'interna'::character varying NOT NULL,
    tipo_exploracion character varying(15),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    CONSTRAINT servicioconfig_ejecucion_valida CHECK (((ejecucion_habitual)::text = ANY ((ARRAY['interna'::character varying, 'externa'::character varying])::text[]))),
    CONSTRAINT servicioconfig_unidad_valida CHECK (((unidad_rendimiento)::text = ANY ((ARRAY['m_lineales'::character varying, 'ensayos'::character varying, 'muestras'::character varying])::text[]))),
    CONSTRAINT servicioconfig_valores_no_negativos CHECK (((muestras_por_metro >= (0)::numeric) AND (rendimiento_diario >= (0)::numeric) AND (horas_minimas >= 0) AND (dias_extra >= 0)))
);


--
-- Name: gestion_solicitud; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_solicitud (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    canal character varying(20) NOT NULL,
    recibida_en timestamp with time zone NOT NULL,
    contacto_nombre character varying(255) NOT NULL,
    contacto_telefono character varying(30),
    contacto_email character varying(254),
    descripcion text NOT NULL,
    estado character varying(20) DEFAULT 'nueva'::character varying NOT NULL,
    cliente_id uuid,
    responsable_id uuid,
    CONSTRAINT solicitud_canal_valido CHECK (((canal)::text = ANY ((ARRAY['llamada'::character varying, 'correo'::character varying, 'whatsapp'::character varying, 'visita'::character varying])::text[]))),
    CONSTRAINT solicitud_estado_valido CHECK (((estado)::text = ANY ((ARRAY['nueva'::character varying, 'en_elaboracion'::character varying, 'ofertada'::character varying, 'descartada'::character varying])::text[])))
);


--
-- Name: gestion_tipoexploracion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gestion_tipoexploracion (
    codigo character varying(15) NOT NULL,
    posicion smallint NOT NULL,
    nombre character varying(150) NOT NULL,
    unidad_campo character varying(15) NOT NULL,
    muestras_por_metro numeric(5,2),
    procesamiento character varying(15) NOT NULL,
    cuadrilla_tipo character varying(12) NOT NULL,
    suele_ser_insumo boolean DEFAULT false NOT NULL,
    ensayos_tipicos text,
    notas text,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    CONSTRAINT tipoexploracion_cuadrilla_valida CHECK (((cuadrilla_tipo)::text = ANY ((ARRAY['spt'::character varying, 'rotativa'::character varying, 'geofisica'::character varying, 'general'::character varying])::text[]))),
    CONSTRAINT tipoexploracion_muestras_no_negativas CHECK ((muestras_por_metro >= (0)::numeric)),
    CONSTRAINT tipoexploracion_procesamiento_valido CHECK (((procesamiento)::text = ANY ((ARRAY['laboratorio'::character varying, 'campo'::character varying, 'geofisica'::character varying])::text[]))),
    CONSTRAINT tipoexploracion_unidad_valida CHECK (((unidad_campo)::text = ANY ((ARRAY['sondeo'::character varying, 'prueba'::character varying, 'linea'::character varying, 'pozo'::character varying, 'bloque'::character varying])::text[])))
);


--
-- Name: lectura_campoleido; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lectura_campoleido (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    fila smallint NOT NULL,
    campo character varying(50) NOT NULL,
    texto_leido text,
    confianza numeric(4,3),
    caja jsonb,
    valor_propuesto text,
    origen_propuesta character varying(20) NOT NULL,
    detalle_propuesta jsonb DEFAULT '{}'::jsonb NOT NULL,
    requiere_revision boolean DEFAULT true NOT NULL,
    motivos_revision jsonb DEFAULT '[]'::jsonb NOT NULL,
    valor_final text,
    estado character varying(20) DEFAULT 'pendiente'::character varying NOT NULL,
    motivo text,
    revisado_en timestamp with time zone,
    revisado_por_id uuid,
    hoja_id uuid NOT NULL,
    CONSTRAINT campo_confianza_0_a_1 CHECK (((confianza >= (0)::numeric) AND (confianza <= (1)::numeric))),
    CONSTRAINT campo_estado_valido CHECK (((estado)::text = ANY ((ARRAY['pendiente'::character varying, 'confirmado'::character varying, 'corregido'::character varying, 'ilegible'::character varying])::text[]))),
    CONSTRAINT campo_origen_valido CHECK (((origen_propuesta)::text = ANY ((ARRAY['lectura'::character varying, 'formato'::character varying, 'sinonimo'::character varying, 'parecido'::character varying, 'confusion'::character varying, 'validacion'::character varying, 'vacio'::character varying, 'sin_propuesta'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT campo_revisado_con_fecha CHECK ((((estado)::text = 'pendiente'::text) OR (revisado_en IS NOT NULL))),
    CONSTRAINT lectura_campoleido_fila_check CHECK ((fila >= 0))
);


--
-- Name: lectura_confusioncaracter; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lectura_confusioncaracter (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    tipo_campo character varying(10) NOT NULL,
    leido character varying(1) NOT NULL,
    "real" character varying(1) NOT NULL,
    veces integer DEFAULT 0 NOT NULL,
    escritor_id uuid,
    CONSTRAINT confusion_tipo_valido CHECK (((tipo_campo)::text = ANY ((ARRAY['numero'::character varying, 'texto'::character varying])::text[]))),
    CONSTRAINT lectura_confusioncaracter_veces_check CHECK ((veces >= 0))
);


--
-- Name: lectura_hojaescaneada; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lectura_hojaescaneada (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    tipo character varying(30) NOT NULL,
    estado character varying(20) DEFAULT 'pendiente'::character varying NOT NULL,
    conjunto character varying(20) DEFAULT 'entrenamiento'::character varying NOT NULL,
    folio character varying(50),
    imagen character varying(255) NOT NULL,
    imagen_sha256 character varying(64) NOT NULL,
    imagen_tipo character varying(50) NOT NULL,
    proveedor character varying(50) DEFAULT ''::character varying NOT NULL,
    version_plantilla character varying(30) DEFAULT ''::character varying NOT NULL,
    respuesta_proveedor jsonb,
    error text,
    revisada_en timestamp with time zone,
    aprendida_en timestamp with time zone,
    llenada_por_id uuid,
    proyecto_id uuid,
    revisada_por_id uuid,
    subida_por_id uuid,
    CONSTRAINT hoja_conjunto_valido CHECK (((conjunto)::text = ANY ((ARRAY['entrenamiento'::character varying, 'prueba'::character varying])::text[]))),
    CONSTRAINT hoja_estado_valido CHECK (((estado)::text = ANY ((ARRAY['pendiente'::character varying, 'en_revision'::character varying, 'revisada'::character varying, 'error'::character varying])::text[]))),
    CONSTRAINT hoja_revisada_con_fecha CHECK (((NOT ((estado)::text = 'revisada'::text)) OR (revisada_en IS NOT NULL))),
    CONSTRAINT hoja_sha256_valido CHECK (((imagen_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT hoja_tipo_valido CHECK (((tipo)::text = ANY ((ARRAY['spt'::character varying, 'clasificacion'::character varying, 'atterberg'::character varying])::text[])))
);


--
-- Name: lectura_sinonimo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lectura_sinonimo (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    vocabulario character varying(50) NOT NULL,
    clave character varying(200) NOT NULL,
    valor character varying(200) NOT NULL,
    confirmaciones integer DEFAULT 0 NOT NULL,
    rechazos integer DEFAULT 0 NOT NULL,
    origen character varying(20) DEFAULT 'aprendido'::character varying NOT NULL,
    CONSTRAINT lectura_sinonimo_confirmaciones_check CHECK ((confirmaciones >= 0)),
    CONSTRAINT lectura_sinonimo_rechazos_check CHECK ((rechazos >= 0)),
    CONSTRAINT sinonimo_origen_valido CHECK (((origen)::text = ANY ((ARRAY['aprendido'::character varying, 'cargado'::character varying])::text[])))
);


--
-- Name: nucleo_avanceproyecto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_avanceproyecto (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(40),
    posicion integer DEFAULT 0 NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    imagen_url character varying(1000),
    cloudinary_id character varying(255),
    subido_por_id uuid,
    proyecto_id uuid NOT NULL,
    CONSTRAINT nucleo_avanceproyecto_posicion_check CHECK ((posicion >= 0))
);


--
-- Name: nucleo_contactocliente; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_contactocliente (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    nombre character varying(255) NOT NULL,
    cargo character varying(150),
    telefono character varying(30),
    correo character varying(254),
    recibe_informes boolean DEFAULT false NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    cliente_id uuid NOT NULL
);


--
-- Name: nucleo_departamento; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_departamento (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    nombre character varying(150) NOT NULL,
    descripcion text,
    activo boolean,
    tarifa_hora_extra numeric(14,4),
    CONSTRAINT departamento_tarifa_no_negativa CHECK ((tarifa_hora_extra >= (0)::numeric))
);


--
-- Name: nucleo_empleado; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_empleado (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    nombres character varying(150) NOT NULL,
    apellidos character varying(150) NOT NULL,
    telefono character varying(30),
    email character varying(254),
    dui character varying(20),
    codigo character varying(30),
    tipo character varying(100),
    cargo character varying(150),
    cuenta_bancaria character varying(50),
    tipo_cuenta character varying(20),
    afp character varying(50),
    pensionado boolean DEFAULT false NOT NULL,
    exento_isss boolean DEFAULT false NOT NULL,
    proceso_judicial boolean DEFAULT false NOT NULL,
    horas_jornada numeric(8,4),
    fecha_contratacion date,
    salario_mensual numeric(14,4),
    activo boolean DEFAULT true NOT NULL,
    tiene_acceso boolean DEFAULT false NOT NULL,
    es_admin boolean DEFAULT false NOT NULL,
    departamento_id uuid,
    usuario_id uuid,
    CONSTRAINT empleado_horas_jornada_validas CHECK (((horas_jornada >= (0)::numeric) AND (horas_jornada <= (24)::numeric))),
    CONSTRAINT empleado_salario_no_negativo CHECK ((salario_mensual >= (0)::numeric)),
    CONSTRAINT empleado_tipo_cuenta_valido CHECK (((tipo_cuenta)::text = ANY ((ARRAY['Ahorro'::character varying, 'Corriente'::character varying])::text[])))
);


--
-- Name: nucleo_proyectotecnico; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_proyectotecnico (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(40),
    posicion integer DEFAULT 0 NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    empleado_id uuid,
    proyecto_id uuid NOT NULL,
    CONSTRAINT nucleo_proyectotecnico_posicion_check CHECK ((posicion >= 0))
);


--
-- Name: nucleo_reportesemanal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_reportesemanal (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    semana_termina date,
    notas text,
    estado character varying(50),
    enviado_en timestamp with time zone,
    proyecto_id uuid,
    reportado_por_id uuid
);


--
-- Name: nucleo_roldepartamento; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_roldepartamento (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    codigo character varying(50) NOT NULL,
    nombre character varying(150) NOT NULL,
    descripcion text,
    es_jefatura boolean DEFAULT false NOT NULL,
    es_supuesto boolean DEFAULT true NOT NULL,
    departamento_id uuid NOT NULL,
    grupo_id integer NOT NULL
);


--
-- Name: nucleo_servicio; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_servicio (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    nombre character varying(255) NOT NULL,
    descripcion text,
    costo_unitario numeric(14,4),
    tipo character varying(50),
    CONSTRAINT servicio_costo_no_negativo CHECK ((costo_unitario >= (0)::numeric)),
    CONSTRAINT servicio_tipo_valido CHECK (((tipo)::text = ANY ((ARRAY['Visita de campo'::character varying, 'Ensayo de laboratorio'::character varying, 'Servicio profesional'::character varying])::text[])))
);


--
-- Name: nucleo_usuario; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_usuario (
    password character varying(128) NOT NULL,
    last_login timestamp with time zone,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    email character varying(254) NOT NULL,
    nombres character varying(150) DEFAULT ''::character varying NOT NULL,
    apellidos character varying(150) DEFAULT ''::character varying NOT NULL,
    tipo character varying(20) NOT NULL,
    verificado boolean,
    intentos_login smallint,
    bloqueado_hasta timestamp with time zone,
    is_active boolean DEFAULT true NOT NULL,
    is_staff boolean DEFAULT false NOT NULL,
    is_superuser boolean DEFAULT false NOT NULL,
    CONSTRAINT nucleo_usuario_intentos_login_check CHECK ((intentos_login >= 0)),
    CONSTRAINT usuario_tipo_valido CHECK (((tipo)::text = ANY ((ARRAY['administrador'::character varying, 'empleado'::character varying])::text[])))
);


--
-- Name: nucleo_usuario_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_usuario_groups (
    id bigint NOT NULL,
    usuario_id uuid NOT NULL,
    group_id integer NOT NULL
);


--
-- Name: nucleo_usuario_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.nucleo_usuario_groups ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.nucleo_usuario_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: nucleo_usuario_user_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nucleo_usuario_user_permissions (
    id bigint NOT NULL,
    usuario_id uuid NOT NULL,
    permission_id integer NOT NULL
);


--
-- Name: nucleo_usuario_user_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.nucleo_usuario_user_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.nucleo_usuario_user_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: rrhh_boleta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_boleta (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    periodo character varying(100),
    salario numeric(14,4),
    generada_en timestamp with time zone,
    enviada_por character varying(50),
    enviada_en timestamp with time zone,
    estado_entrega character varying(50),
    linea_planilla_id uuid
);


--
-- Name: rrhh_comprobante; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_comprobante (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    tipo character varying(15) NOT NULL,
    empleado_id uuid NOT NULL,
    periodo_desde date NOT NULL,
    periodo_hasta date NOT NULL,
    alojamiento_desde date,
    alojamiento_hasta date,
    mes_pagado date,
    dias_pagados numeric(8,4) NOT NULL,
    monto numeric(14,4) NOT NULL,
    salario_devengado numeric(14,4) DEFAULT 0 NOT NULL,
    descuento_isss numeric(14,4) DEFAULT 0 NOT NULL,
    descuento_afp numeric(14,4) DEFAULT 0 NOT NULL,
    descuento_renta numeric(14,4) DEFAULT 0 NOT NULL,
    anticipos numeric(14,4) DEFAULT 0 NOT NULL,
    otros_descuentos numeric(14,4) DEFAULT 0 NOT NULL,
    liquido numeric(14,4) GENERATED ALWAYS AS (((((((monto + salario_devengado) - descuento_isss) - descuento_afp) - descuento_renta) - anticipos) - otros_descuentos)) STORED,
    fecha_emision date DEFAULT CURRENT_DATE NOT NULL,
    referencia text,
    pagado_efectivo boolean DEFAULT false NOT NULL,
    linea_planilla_id uuid,
    emitido_por_id uuid,
    CONSTRAINT comprobante_alojamiento_con_fechas CHECK ((((tipo)::text <> 'alojamiento'::text) OR ((alojamiento_desde IS NOT NULL) AND (alojamiento_hasta IS NOT NULL) AND (alojamiento_hasta >= alojamiento_desde)))),
    CONSTRAINT comprobante_campos_por_tipo CHECK (((((tipo)::text = 'anticipo'::text) OR ((salario_devengado = (0)::numeric) AND (anticipos = (0)::numeric) AND (otros_descuentos = (0)::numeric))) AND (((tipo)::text <> 'alojamiento'::text) OR ((descuento_isss = (0)::numeric) AND (descuento_afp = (0)::numeric) AND (descuento_renta = (0)::numeric))) AND (((tipo)::text = 'alojamiento'::text) OR (pagado_efectivo = false)))),
    CONSTRAINT comprobante_dias_validos CHECK (((dias_pagados >= (0)::numeric) AND (dias_pagados <= (31)::numeric))),
    CONSTRAINT comprobante_mes_pagado_dia_1 CHECK ((EXTRACT(day FROM mes_pagado) = (1)::numeric)),
    CONSTRAINT comprobante_monto_positivo CHECK ((monto > (0)::numeric)),
    CONSTRAINT comprobante_periodo_en_orden CHECK ((periodo_hasta >= periodo_desde)),
    CONSTRAINT comprobante_tipo_valido CHECK (((tipo)::text = ANY ((ARRAY['alimentacion'::character varying, 'transporte'::character varying, 'alojamiento'::character varying, 'anticipo'::character varying])::text[]))),
    CONSTRAINT comprobante_valores_no_negativos CHECK (((salario_devengado >= (0)::numeric) AND (descuento_isss >= (0)::numeric) AND (descuento_afp >= (0)::numeric) AND (descuento_renta >= (0)::numeric) AND (anticipos >= (0)::numeric) AND (otros_descuentos >= (0)::numeric)))
);


--
-- Name: rrhh_contrato; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_contrato (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    tipo character varying(100),
    fecha_inicio date,
    fecha_fin date,
    salario numeric(14,4),
    hora_entrada time without time zone,
    hora_salida time without time zone,
    horas_jornada numeric(8,4),
    clausulas text,
    activo boolean,
    empleado_id uuid,
    CONSTRAINT contrato_fechas_en_orden CHECK ((fecha_fin >= fecha_inicio)),
    CONSTRAINT contrato_horas_validas CHECK (((horas_jornada >= (0)::numeric) AND (horas_jornada <= (24)::numeric))),
    CONSTRAINT contrato_salario_no_negativo CHECK ((salario >= (0)::numeric))
);


--
-- Name: rrhh_horaextra; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_horaextra (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    periodo_inicio date,
    periodo_fin date,
    autorizado_por character varying(255),
    horas_regulares numeric(8,4),
    horas_extra numeric(8,4) DEFAULT 0 NOT NULL,
    costo_hora numeric(14,4) DEFAULT 0 NOT NULL,
    total numeric(14,4) DEFAULT 0 NOT NULL,
    tipo character varying(20),
    empleado_id uuid,
    proyecto_id uuid,
    CONSTRAINT hora_extra_periodo_en_orden CHECK ((periodo_fin >= periodo_inicio)),
    CONSTRAINT hora_extra_tipo_valido CHECK (((tipo)::text = ANY ((ARRAY['diaria'::character varying, 'semanal'::character varying, 'feriado'::character varying])::text[]))),
    CONSTRAINT hora_extra_valores_no_negativos CHECK (((horas_regulares >= (0)::numeric) AND (horas_extra >= (0)::numeric) AND (costo_hora >= (0)::numeric) AND (total >= (0)::numeric)))
);


--
-- Name: rrhh_horaextradia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_horaextradia (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    registro_id uuid NOT NULL,
    fecha date NOT NULL,
    es_asueto boolean DEFAULT false NOT NULL,
    hora_entrada time without time zone NOT NULL,
    hora_salida time without time zone NOT NULL,
    tipo_dia character varying(10) GENERATED ALWAYS AS (
CASE
    WHEN (es_asueto OR (EXTRACT(isodow FROM fecha) = (7)::numeric)) THEN 'descanso'::text
    ELSE 'normal'::text
END) STORED,
    horas_diurnas numeric(8,4) DEFAULT 0 NOT NULL,
    horas_nocturnas numeric(8,4) DEFAULT 0 NOT NULL,
    proyecto_id uuid,
    proyecto_nombre character varying(255),
    inicia_en timestamp without time zone GENERATED ALWAYS AS ((fecha + hora_entrada)) STORED,
    termina_en timestamp without time zone GENERATED ALWAYS AS (((fecha + hora_salida) +
CASE
    WHEN (hora_salida <= hora_entrada) THEN '1 day'::interval
    ELSE '00:00:00'::interval
END)) STORED,
    CONSTRAINT horaextradia_horario_valido CHECK ((hora_entrada <> hora_salida)),
    CONSTRAINT horaextradia_horas_no_negativas CHECK (((horas_diurnas >= (0)::numeric) AND (horas_nocturnas >= (0)::numeric)))
);


--
-- Name: rrhh_lineaplanilla; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_lineaplanilla (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    salario_base numeric(14,4),
    dias_laborados numeric(8,4),
    horas_turno numeric(8,4) DEFAULT 8 NOT NULL,
    base_diaria character varying(10) DEFAULT 'mes_30'::character varying NOT NULL,
    horas_extra_diurnas numeric(8,4) DEFAULT 0 NOT NULL,
    horas_extra_nocturnas numeric(8,4) DEFAULT 0 NOT NULL,
    horas_descanso_diurnas numeric(8,4) DEFAULT 0 NOT NULL,
    horas_descanso_nocturnas numeric(8,4) DEFAULT 0 NOT NULL,
    horas_extra numeric(8,4) DEFAULT 0 NOT NULL,
    pago_extra_diurno numeric(14,4) DEFAULT 0 NOT NULL,
    pago_extra_nocturno numeric(14,4) DEFAULT 0 NOT NULL,
    pago_extra_ordinario numeric(14,4) DEFAULT 0 NOT NULL,
    pago_descanso_diurno numeric(14,4) DEFAULT 0 NOT NULL,
    pago_descanso_nocturno numeric(14,4) DEFAULT 0 NOT NULL,
    pago_extra_descanso numeric(14,4) DEFAULT 0 NOT NULL,
    pago_extra numeric(14,4) DEFAULT 0 NOT NULL,
    ajuste_pendiente numeric(14,4) DEFAULT 0 NOT NULL,
    bonificaciones numeric(14,4) DEFAULT 0 NOT NULL,
    bonificaciones_extra numeric(14,4) DEFAULT 0 NOT NULL,
    salario_devengado numeric(14,4) DEFAULT 0 NOT NULL,
    total_devengado numeric(14,4) DEFAULT 0 NOT NULL,
    descuento_isss numeric(14,4) DEFAULT 0 NOT NULL,
    descuento_afp numeric(14,4) DEFAULT 0 NOT NULL,
    neto_antes_renta numeric(14,4) DEFAULT 0 NOT NULL,
    descuento_renta numeric(14,4) DEFAULT 0 NOT NULL,
    descuentos numeric(14,4) DEFAULT 0 NOT NULL,
    anticipo numeric(14,4) DEFAULT 0 NOT NULL,
    otros_descuentos numeric(14,4) DEFAULT 0 NOT NULL,
    liquido numeric(14,4),
    empleado_id uuid,
    planilla_id uuid NOT NULL,
    viatico_transporte numeric(14,4) DEFAULT 0 NOT NULL,
    viatico_alojamiento numeric(14,4) DEFAULT 0 NOT NULL,
    viatico_alimentacion numeric(14,4) DEFAULT 0 NOT NULL,
    viatico_extra numeric(14,4) DEFAULT 0 NOT NULL,
    total_viaticos numeric(14,4) GENERATED ALWAYS AS (((viatico_transporte + viatico_alojamiento) + viatico_alimentacion)) STORED,
    prestamo numeric(14,4) DEFAULT 0 NOT NULL,
    prestamo_id uuid,
    viaticos_ref text,
    alojamiento_desde date,
    alojamiento_hasta date,
    CONSTRAINT linea_planilla_alojamiento_en_orden CHECK ((alojamiento_hasta >= alojamiento_desde)),
    CONSTRAINT linea_planilla_base_diaria_valida CHECK (((base_diaria)::text = ANY ((ARRAY['mes_30'::character varying, 'anio_365'::character varying])::text[]))),
    CONSTRAINT linea_planilla_prestamo_con_monto CHECK (((prestamo_id IS NULL) OR (prestamo > (0)::numeric))),
    CONSTRAINT linea_planilla_viaticos_no_negativos CHECK (((viatico_transporte >= (0)::numeric) AND (viatico_alojamiento >= (0)::numeric) AND (viatico_alimentacion >= (0)::numeric) AND (viatico_extra >= (0)::numeric) AND (prestamo >= (0)::numeric)))
);


--
-- Name: COLUMN rrhh_lineaplanilla.otros_descuentos; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.rrhh_lineaplanilla.otros_descuentos IS 'Otros descuentos SIN el préstamo (el préstamo va en la columna prestamo).';


--
-- Name: rrhh_planilla; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_planilla (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mongo_id character varying(24),
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    periodo_inicio date,
    periodo_fin date,
    total numeric(14,4) DEFAULT 0 NOT NULL,
    estado character varying(20),
    generada_en timestamp with time zone,
    incluye_descuentos boolean DEFAULT false NOT NULL,
    incluye_bonos boolean DEFAULT false NOT NULL,
    departamento_id uuid,
    generada_por_id uuid,
    CONSTRAINT planilla_estado_valido CHECK (((estado)::text = ANY ((ARRAY['borrador'::character varying, 'aprobada'::character varying, 'pagada'::character varying])::text[]))),
    CONSTRAINT planilla_periodo_en_orden CHECK ((periodo_fin >= periodo_inicio))
);


--
-- Name: rrhh_prestamo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_prestamo (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    empleado_id uuid NOT NULL,
    monto numeric(14,4) NOT NULL,
    cuotas_regulares smallint NOT NULL,
    valor_cuota numeric(14,4) NOT NULL,
    valor_ultima_cuota numeric(14,4),
    numero_cuotas smallint GENERATED ALWAYS AS ((cuotas_regulares +
CASE
    WHEN (valor_ultima_cuota IS NULL) THEN 0
    ELSE 1
END)) STORED,
    fecha_firma date NOT NULL,
    ciudad_firma character varying(100) DEFAULT 'San Salvador'::character varying NOT NULL,
    estado character varying(10) DEFAULT 'activo'::character varying NOT NULL,
    observaciones text,
    registrado_por_id uuid,
    CONSTRAINT prestamo_cuotas_cuadran CHECK (((((cuotas_regulares)::numeric * valor_cuota) + COALESCE(valor_ultima_cuota, (0)::numeric)) = monto)),
    CONSTRAINT prestamo_estado_valido CHECK (((estado)::text = ANY ((ARRAY['activo'::character varying, 'pagado'::character varying, 'anulado'::character varying])::text[]))),
    CONSTRAINT prestamo_valores_positivos CHECK (((monto > (0)::numeric) AND (cuotas_regulares > 0) AND (valor_cuota > (0)::numeric) AND (valor_ultima_cuota > (0)::numeric)))
);


--
-- Name: rrhh_registrohoraextra; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_registrohoraextra (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    empleado_id uuid NOT NULL,
    periodo_inicio date NOT NULL,
    periodo_fin date NOT NULL,
    salario_base numeric(14,4) DEFAULT 0 NOT NULL,
    horas_jornada numeric(8,4) NOT NULL,
    dias_base numeric(8,4) DEFAULT 30 NOT NULL,
    tarifa_manual_normal_diurna numeric(14,4),
    tarifa_manual_normal_nocturna numeric(14,4),
    tarifa_manual_descanso_diurna numeric(14,4),
    tarifa_manual_descanso_nocturna numeric(14,4),
    tarifa_normal_diurna numeric(14,4) DEFAULT 0 NOT NULL,
    tarifa_normal_nocturna numeric(14,4) DEFAULT 0 NOT NULL,
    tarifa_descanso_diurna numeric(14,4) DEFAULT 0 NOT NULL,
    tarifa_descanso_nocturna numeric(14,4) DEFAULT 0 NOT NULL,
    horas_normal_diurnas numeric(8,4) DEFAULT 0 NOT NULL,
    horas_normal_nocturnas numeric(8,4) DEFAULT 0 NOT NULL,
    horas_descanso_diurnas numeric(8,4) DEFAULT 0 NOT NULL,
    horas_descanso_nocturnas numeric(8,4) DEFAULT 0 NOT NULL,
    total numeric(14,4) DEFAULT 0 NOT NULL,
    linea_planilla_id uuid,
    registrado_por_id uuid,
    CONSTRAINT registro_he_dias_validos CHECK (((dias_base >= (1)::numeric) AND (dias_base <= (31)::numeric))),
    CONSTRAINT registro_he_jornada_valida CHECK (((horas_jornada > (0)::numeric) AND (horas_jornada <= (24)::numeric))),
    CONSTRAINT registro_he_periodo_16_al_15 CHECK (((EXTRACT(day FROM periodo_fin) = (15)::numeric) AND (periodo_inicio = (((periodo_fin - '1 mon'::interval) + '1 day'::interval))::date))),
    CONSTRAINT registro_he_tarifas_manuales_positivas CHECK (((tarifa_manual_normal_diurna > (0)::numeric) AND (tarifa_manual_normal_nocturna > (0)::numeric) AND (tarifa_manual_descanso_diurna > (0)::numeric) AND (tarifa_manual_descanso_nocturna > (0)::numeric))),
    CONSTRAINT registro_he_valores_no_negativos CHECK (((salario_base >= (0)::numeric) AND (tarifa_normal_diurna >= (0)::numeric) AND (tarifa_normal_nocturna >= (0)::numeric) AND (tarifa_descanso_diurna >= (0)::numeric) AND (tarifa_descanso_nocturna >= (0)::numeric) AND (horas_normal_diurnas >= (0)::numeric) AND (horas_normal_nocturnas >= (0)::numeric) AND (horas_descanso_diurnas >= (0)::numeric) AND (horas_descanso_nocturnas >= (0)::numeric) AND (total >= (0)::numeric)))
);


--
-- Name: rrhh_tarifahoraextra; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_tarifahoraextra (
    departamento_id uuid NOT NULL,
    datos_extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    creado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    actualizado_en timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    normal_diurna numeric(14,4),
    normal_nocturna numeric(14,4),
    descanso_diurna numeric(14,4),
    descanso_nocturna numeric(14,4),
    actualizado_por_id uuid,
    CONSTRAINT tarifa_he_positivas CHECK (((normal_diurna > (0)::numeric) AND (normal_nocturna > (0)::numeric) AND (descanso_diurna > (0)::numeric) AND (descanso_nocturna > (0)::numeric)))
);


--
-- Name: rrhh_v_horaextra_proyecto; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.rrhh_v_horaextra_proyecto WITH (security_invoker='true') AS
 SELECT r.periodo_fin,
    r.empleado_id,
    d.proyecto_id,
    COALESCE(NULLIF(TRIM(BOTH FROM d.proyecto_nombre), ''::text), (p.nombre)::text) AS proyecto,
    p.codigo AS proyecto_codigo,
    c.razon_social AS cliente,
    COALESCE(sum(d.horas_diurnas) FILTER (WHERE ((d.tipo_dia)::text = 'normal'::text)), (0)::numeric) AS horas_normal_diurnas,
    COALESCE(sum(d.horas_nocturnas) FILTER (WHERE ((d.tipo_dia)::text = 'normal'::text)), (0)::numeric) AS horas_normal_nocturnas,
    COALESCE(sum(d.horas_diurnas) FILTER (WHERE ((d.tipo_dia)::text = 'descanso'::text)), (0)::numeric) AS horas_descanso_diurnas,
    COALESCE(sum(d.horas_nocturnas) FILTER (WHERE ((d.tipo_dia)::text = 'descanso'::text)), (0)::numeric) AS horas_descanso_nocturnas,
    round(sum(((d.horas_diurnas *
        CASE d.tipo_dia
            WHEN 'normal'::text THEN r.tarifa_normal_diurna
            ELSE r.tarifa_descanso_diurna
        END) + (d.horas_nocturnas *
        CASE d.tipo_dia
            WHEN 'normal'::text THEN r.tarifa_normal_nocturna
            ELSE r.tarifa_descanso_nocturna
        END))), 2) AS total
   FROM (((public.rrhh_horaextradia d
     JOIN public.rrhh_registrohoraextra r ON ((r.id = d.registro_id)))
     LEFT JOIN public.nucleo_proyecto p ON ((p.id = d.proyecto_id)))
     LEFT JOIN public.nucleo_cliente c ON ((c.id = p.cliente_id)))
  GROUP BY r.periodo_fin, r.empleado_id, d.proyecto_id, COALESCE(NULLIF(TRIM(BOTH FROM d.proyecto_nombre), ''::text), (p.nombre)::text), p.codigo, c.razon_social;


--
-- Name: rrhh_v_saldo_prestamo; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.rrhh_v_saldo_prestamo AS
SELECT
    NULL::uuid AS prestamo_id,
    NULL::uuid AS empleado_id,
    NULL::numeric(14,4) AS monto,
    NULL::smallint AS numero_cuotas,
    NULL::character varying(10) AS estado,
    NULL::bigint AS cuotas_descontadas,
    NULL::numeric AS pagado,
    NULL::numeric AS saldo;


--
-- Data for Name: adjuntos; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: areas; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: auditoria; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: calibraciones; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: categorias_material; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: ensayos; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: equipos; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: especimenes; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: importacion_filas; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: importaciones; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: informe_ensayos; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: informes; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: mediciones; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: metodo_tipos_especimen; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: metodos_ensayo; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: movimientos_especimen; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: muestras; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: normas; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: parametros_metodo; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: proveedores_material; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: remisiones; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: resultados_compresion; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: tipos_especimen; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: tipos_falla; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: ubicaciones; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: usuarios_roles; Type: TABLE DATA; Schema: lab; Owner: -
--



--
-- Data for Name: auth_group; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.auth_group (id, name) VALUES (1, 'gestion_ofertas');
INSERT INTO public.auth_group (id, name) VALUES (2, 'gestion_programacion');
INSERT INTO public.auth_group (id, name) VALUES (3, 'gestion_laboratorio');
INSERT INTO public.auth_group (id, name) VALUES (4, 'gestion_gabinete');
INSERT INTO public.auth_group (id, name) VALUES (5, 'gestion_jefatura');
INSERT INTO public.auth_group (id, name) VALUES (6, 'gestion_administracion');


--
-- Data for Name: auth_group_permissions; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: auth_permission; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (1, 'Can add log entry', 1, 'add_logentry');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (2, 'Can change log entry', 1, 'change_logentry');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (3, 'Can delete log entry', 1, 'delete_logentry');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (4, 'Can view log entry', 1, 'view_logentry');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (5, 'Can add permission', 3, 'add_permission');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (6, 'Can change permission', 3, 'change_permission');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (7, 'Can delete permission', 3, 'delete_permission');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (8, 'Can view permission', 3, 'view_permission');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (9, 'Can add group', 2, 'add_group');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (10, 'Can change group', 2, 'change_group');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (11, 'Can delete group', 2, 'delete_group');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (12, 'Can view group', 2, 'view_group');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (13, 'Can add content type', 4, 'add_contenttype');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (14, 'Can change content type', 4, 'change_contenttype');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (15, 'Can delete content type', 4, 'delete_contenttype');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (16, 'Can view content type', 4, 'view_contenttype');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (17, 'Can add session', 5, 'add_session');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (18, 'Can change session', 5, 'change_session');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (19, 'Can delete session', 5, 'delete_session');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (20, 'Can view session', 5, 'view_session');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (21, 'Can add usuario', 16, 'add_usuario');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (22, 'Can change usuario', 16, 'change_usuario');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (23, 'Can delete usuario', 16, 'delete_usuario');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (24, 'Can view usuario', 16, 'view_usuario');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (25, 'Can add cliente', 7, 'add_cliente');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (26, 'Can change cliente', 7, 'change_cliente');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (27, 'Can delete cliente', 7, 'delete_cliente');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (28, 'Can view cliente', 7, 'view_cliente');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (29, 'Can add departamento', 9, 'add_departamento');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (30, 'Can change departamento', 9, 'change_departamento');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (31, 'Can delete departamento', 9, 'delete_departamento');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (32, 'Can view departamento', 9, 'view_departamento');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (33, 'Can add empleado', 10, 'add_empleado');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (34, 'Can change empleado', 10, 'change_empleado');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (35, 'Can delete empleado', 10, 'delete_empleado');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (36, 'Can view empleado', 10, 'view_empleado');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (37, 'Can add proyecto', 11, 'add_proyecto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (38, 'Can change proyecto', 11, 'change_proyecto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (39, 'Can delete proyecto', 11, 'delete_proyecto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (40, 'Can view proyecto', 11, 'view_proyecto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (41, 'Can add avance de proyecto', 6, 'add_avanceproyecto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (42, 'Can change avance de proyecto', 6, 'change_avanceproyecto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (43, 'Can delete avance de proyecto', 6, 'delete_avanceproyecto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (44, 'Can view avance de proyecto', 6, 'view_avanceproyecto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (45, 'Can add técnico asignado', 12, 'add_proyectotecnico');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (46, 'Can change técnico asignado', 12, 'change_proyectotecnico');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (47, 'Can delete técnico asignado', 12, 'delete_proyectotecnico');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (48, 'Can view técnico asignado', 12, 'view_proyectotecnico');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (49, 'Can add reporte semanal', 13, 'add_reportesemanal');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (50, 'Can change reporte semanal', 13, 'change_reportesemanal');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (51, 'Can delete reporte semanal', 13, 'delete_reportesemanal');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (52, 'Can view reporte semanal', 13, 'view_reportesemanal');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (53, 'Can add servicio', 15, 'add_servicio');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (54, 'Can change servicio', 15, 'change_servicio');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (55, 'Can delete servicio', 15, 'delete_servicio');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (56, 'Can view servicio', 15, 'view_servicio');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (57, 'Can add contacto de cliente', 8, 'add_contactocliente');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (58, 'Can change contacto de cliente', 8, 'change_contactocliente');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (59, 'Can delete contacto de cliente', 8, 'delete_contactocliente');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (60, 'Can view contacto de cliente', 8, 'view_contactocliente');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (61, 'Can add rol de departamento', 14, 'add_roldepartamento');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (62, 'Can change rol de departamento', 14, 'change_roldepartamento');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (63, 'Can delete rol de departamento', 14, 'delete_roldepartamento');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (64, 'Can view rol de departamento', 14, 'view_roldepartamento');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (65, 'Can add línea de planilla', 20, 'add_lineaplanilla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (66, 'Can change línea de planilla', 20, 'change_lineaplanilla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (67, 'Can delete línea de planilla', 20, 'delete_lineaplanilla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (68, 'Can view línea de planilla', 20, 'view_lineaplanilla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (69, 'Can add boleta de pago', 17, 'add_boleta');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (70, 'Can change boleta de pago', 17, 'change_boleta');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (71, 'Can delete boleta de pago', 17, 'delete_boleta');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (72, 'Can view boleta de pago', 17, 'view_boleta');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (73, 'Can add planilla', 21, 'add_planilla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (74, 'Can change planilla', 21, 'change_planilla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (75, 'Can delete planilla', 21, 'delete_planilla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (76, 'Can view planilla', 21, 'view_planilla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (77, 'Can add contrato', 18, 'add_contrato');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (78, 'Can change contrato', 18, 'change_contrato');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (79, 'Can delete contrato', 18, 'delete_contrato');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (80, 'Can view contrato', 18, 'view_contrato');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (81, 'Can add registro de horas extra', 19, 'add_horaextra');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (82, 'Can change registro de horas extra', 19, 'change_horaextra');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (83, 'Can delete registro de horas extra', 19, 'delete_horaextra');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (84, 'Can view registro de horas extra', 19, 'view_horaextra');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (85, 'Can add cuenta por cobrar', 22, 'add_cuentaporcobrar');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (86, 'Can change cuenta por cobrar', 22, 'change_cuentaporcobrar');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (87, 'Can delete cuenta por cobrar', 22, 'delete_cuentaporcobrar');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (88, 'Can view cuenta por cobrar', 22, 'view_cuentaporcobrar');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (89, 'Can add pago', 24, 'add_pago');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (90, 'Can change pago', 24, 'change_pago');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (91, 'Can delete pago', 24, 'delete_pago');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (92, 'Can view pago', 24, 'view_pago');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (93, 'Can add proforma', 25, 'add_proforma');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (94, 'Can change proforma', 25, 'change_proforma');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (95, 'Can delete proforma', 25, 'delete_proforma');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (96, 'Can view proforma', 25, 'view_proforma');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (97, 'Can add ítem de proforma', 26, 'add_proformaitem');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (98, 'Can change ítem de proforma', 26, 'change_proformaitem');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (99, 'Can delete ítem de proforma', 26, 'delete_proformaitem');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (100, 'Can view ítem de proforma', 26, 'view_proformaitem');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (101, 'Can add ítem de cuenta por cobrar', 23, 'add_cuentaporcobraritem');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (102, 'Can change ítem de cuenta por cobrar', 23, 'change_cuentaporcobraritem');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (103, 'Can delete ítem de cuenta por cobrar', 23, 'delete_cuentaporcobraritem');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (104, 'Can view ítem de cuenta por cobrar', 23, 'view_cuentaporcobraritem');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (105, 'Can add hoja escaneada', 29, 'add_hojaescaneada');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (106, 'Can change hoja escaneada', 29, 'change_hojaescaneada');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (107, 'Can delete hoja escaneada', 29, 'delete_hojaescaneada');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (108, 'Can view hoja escaneada', 29, 'view_hojaescaneada');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (109, 'Can add campo leído', 27, 'add_campoleido');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (110, 'Can change campo leído', 27, 'change_campoleido');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (111, 'Can delete campo leído', 27, 'delete_campoleido');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (112, 'Can view campo leído', 27, 'view_campoleido');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (113, 'Can add sinónimo', 30, 'add_sinonimo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (114, 'Can change sinónimo', 30, 'change_sinonimo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (115, 'Can delete sinónimo', 30, 'delete_sinonimo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (116, 'Can view sinónimo', 30, 'view_sinonimo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (117, 'Can add confusión de caracteres', 28, 'add_confusioncaracter');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (118, 'Can change confusión de caracteres', 28, 'change_confusioncaracter');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (119, 'Can delete confusión de caracteres', 28, 'delete_confusioncaracter');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (120, 'Can view confusión de caracteres', 28, 'view_confusioncaracter');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (121, 'Can add adjunto', 31, 'add_adjunto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (122, 'Can change adjunto', 31, 'change_adjunto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (123, 'Can delete adjunto', 31, 'delete_adjunto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (124, 'Can view adjunto', 31, 'view_adjunto');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (125, 'Can add área', 32, 'add_area');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (126, 'Can change área', 32, 'change_area');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (127, 'Can delete área', 32, 'delete_area');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (128, 'Can view área', 32, 'view_area');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (129, 'Can add auditoría', 33, 'add_auditoria');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (130, 'Can change auditoría', 33, 'change_auditoria');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (131, 'Can delete auditoría', 33, 'delete_auditoria');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (132, 'Can view auditoría', 33, 'view_auditoria');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (133, 'Can add calibración', 34, 'add_calibracion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (134, 'Can change calibración', 34, 'change_calibracion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (135, 'Can delete calibración', 34, 'delete_calibracion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (136, 'Can view calibración', 34, 'view_calibracion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (137, 'Can add categoría de material', 35, 'add_categoriamaterial');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (138, 'Can change categoría de material', 35, 'change_categoriamaterial');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (139, 'Can delete categoría de material', 35, 'delete_categoriamaterial');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (140, 'Can view categoría de material', 35, 'view_categoriamaterial');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (141, 'Can add ensayo', 36, 'add_ensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (142, 'Can change ensayo', 36, 'change_ensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (143, 'Can delete ensayo', 36, 'delete_ensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (144, 'Can view ensayo', 36, 'view_ensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (145, 'Can add equipo', 37, 'add_equipo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (146, 'Can change equipo', 37, 'change_equipo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (147, 'Can delete equipo', 37, 'delete_equipo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (148, 'Can view equipo', 37, 'view_equipo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (149, 'Can add espécimen', 38, 'add_especimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (150, 'Can change espécimen', 38, 'change_especimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (151, 'Can delete espécimen', 38, 'delete_especimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (152, 'Can view espécimen', 38, 'view_especimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (153, 'Can add importación', 39, 'add_importacion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (154, 'Can change importación', 39, 'change_importacion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (155, 'Can delete importación', 39, 'delete_importacion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (156, 'Can view importación', 39, 'view_importacion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (157, 'Can add fila de importación', 40, 'add_importacionfila');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (158, 'Can change fila de importación', 40, 'change_importacionfila');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (159, 'Can delete fila de importación', 40, 'delete_importacionfila');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (160, 'Can view fila de importación', 40, 'view_importacionfila');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (161, 'Can add informe', 41, 'add_informe');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (162, 'Can change informe', 41, 'change_informe');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (163, 'Can delete informe', 41, 'delete_informe');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (164, 'Can view informe', 41, 'view_informe');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (165, 'Can add informe ensayo', 42, 'add_informeensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (166, 'Can change informe ensayo', 42, 'change_informeensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (167, 'Can delete informe ensayo', 42, 'delete_informeensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (168, 'Can view informe ensayo', 42, 'view_informeensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (169, 'Can add medición', 43, 'add_medicion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (170, 'Can change medición', 43, 'change_medicion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (171, 'Can delete medición', 43, 'delete_medicion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (172, 'Can view medición', 43, 'view_medicion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (173, 'Can add método de ensayo', 44, 'add_metodoensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (174, 'Can change método de ensayo', 44, 'change_metodoensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (175, 'Can delete método de ensayo', 44, 'delete_metodoensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (176, 'Can view método de ensayo', 44, 'view_metodoensayo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (177, 'Can add metodo tipo especimen', 45, 'add_metodotipoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (178, 'Can change metodo tipo especimen', 45, 'change_metodotipoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (179, 'Can delete metodo tipo especimen', 45, 'delete_metodotipoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (180, 'Can view metodo tipo especimen', 45, 'view_metodotipoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (181, 'Can add movimiento de espécimen', 46, 'add_movimientoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (182, 'Can change movimiento de espécimen', 46, 'change_movimientoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (183, 'Can delete movimiento de espécimen', 46, 'delete_movimientoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (184, 'Can view movimiento de espécimen', 46, 'view_movimientoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (185, 'Can add muestra', 47, 'add_muestra');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (186, 'Can change muestra', 47, 'change_muestra');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (187, 'Can delete muestra', 47, 'delete_muestra');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (188, 'Can view muestra', 47, 'view_muestra');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (189, 'Can add norma', 48, 'add_norma');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (190, 'Can change norma', 48, 'change_norma');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (191, 'Can delete norma', 48, 'delete_norma');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (192, 'Can view norma', 48, 'view_norma');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (193, 'Can add parámetro de método', 49, 'add_parametrometodo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (194, 'Can change parámetro de método', 49, 'change_parametrometodo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (195, 'Can delete parámetro de método', 49, 'delete_parametrometodo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (196, 'Can view parámetro de método', 49, 'view_parametrometodo');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (197, 'Can add proveedor de material', 50, 'add_proveedormaterial');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (198, 'Can change proveedor de material', 50, 'change_proveedormaterial');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (199, 'Can delete proveedor de material', 50, 'delete_proveedormaterial');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (200, 'Can view proveedor de material', 50, 'view_proveedormaterial');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (201, 'Can add remisión', 51, 'add_remision');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (202, 'Can change remisión', 51, 'change_remision');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (203, 'Can delete remisión', 51, 'delete_remision');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (204, 'Can view remisión', 51, 'view_remision');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (205, 'Can add tipo de espécimen', 53, 'add_tipoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (206, 'Can change tipo de espécimen', 53, 'change_tipoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (207, 'Can delete tipo de espécimen', 53, 'delete_tipoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (208, 'Can view tipo de espécimen', 53, 'view_tipoespecimen');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (209, 'Can add tipo de falla', 54, 'add_tipofalla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (210, 'Can change tipo de falla', 54, 'change_tipofalla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (211, 'Can delete tipo de falla', 54, 'delete_tipofalla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (212, 'Can view tipo de falla', 54, 'view_tipofalla');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (213, 'Can add ubicación', 55, 'add_ubicacion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (214, 'Can change ubicación', 55, 'change_ubicacion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (215, 'Can delete ubicación', 55, 'delete_ubicacion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (216, 'Can view ubicación', 55, 'view_ubicacion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (217, 'Can add rol de usuario del laboratorio', 56, 'add_usuariorol');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (218, 'Can change rol de usuario del laboratorio', 56, 'change_usuariorol');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (219, 'Can delete rol de usuario del laboratorio', 56, 'delete_usuariorol');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (220, 'Can view rol de usuario del laboratorio', 56, 'view_usuariorol');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (221, 'Can add curva de resistencia', 57, 'add_vistacurvaresistencia');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (222, 'Can change curva de resistencia', 57, 'change_vistacurvaresistencia');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (223, 'Can delete curva de resistencia', 57, 'delete_vistacurvaresistencia');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (224, 'Can view curva de resistencia', 57, 'view_vistacurvaresistencia');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (225, 'Can add programación de ensayos', 58, 'add_vistaprogramacionensayos');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (226, 'Can change programación de ensayos', 58, 'change_vistaprogramacionensayos');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (227, 'Can delete programación de ensayos', 58, 'delete_vistaprogramacionensayos');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (228, 'Can view programación de ensayos', 58, 'view_vistaprogramacionensayos');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (229, 'Can add resultado de compresión (vista)', 59, 'add_vistaresultadoscompresion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (230, 'Can change resultado de compresión (vista)', 59, 'change_vistaresultadoscompresion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (231, 'Can delete resultado de compresión (vista)', 59, 'delete_vistaresultadoscompresion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (232, 'Can view resultado de compresión (vista)', 59, 'view_vistaresultadoscompresion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (233, 'Can add resultado de compresión', 52, 'add_resultadocompresion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (234, 'Can change resultado de compresión', 52, 'change_resultadocompresion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (235, 'Can delete resultado de compresión', 52, 'delete_resultadocompresion');
INSERT INTO public.auth_permission (id, name, content_type_id, codename) VALUES (236, 'Can view resultado de compresión', 52, 'view_resultadocompresion');


--
-- Data for Name: django_admin_log; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: django_content_type; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.django_content_type (id, app_label, model) VALUES (1, 'admin', 'logentry');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (2, 'auth', 'group');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (3, 'auth', 'permission');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (4, 'contenttypes', 'contenttype');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (5, 'sessions', 'session');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (6, 'nucleo', 'avanceproyecto');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (7, 'nucleo', 'cliente');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (8, 'nucleo', 'contactocliente');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (9, 'nucleo', 'departamento');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (10, 'nucleo', 'empleado');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (11, 'nucleo', 'proyecto');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (12, 'nucleo', 'proyectotecnico');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (13, 'nucleo', 'reportesemanal');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (14, 'nucleo', 'roldepartamento');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (15, 'nucleo', 'servicio');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (16, 'nucleo', 'usuario');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (17, 'rrhh', 'boleta');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (18, 'rrhh', 'contrato');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (19, 'rrhh', 'horaextra');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (20, 'rrhh', 'lineaplanilla');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (21, 'rrhh', 'planilla');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (22, 'finanzas', 'cuentaporcobrar');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (23, 'finanzas', 'cuentaporcobraritem');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (24, 'finanzas', 'pago');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (25, 'finanzas', 'proforma');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (26, 'finanzas', 'proformaitem');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (27, 'lectura', 'campoleido');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (28, 'lectura', 'confusioncaracter');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (29, 'lectura', 'hojaescaneada');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (30, 'lectura', 'sinonimo');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (31, 'lab', 'adjunto');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (32, 'lab', 'area');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (33, 'lab', 'auditoria');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (34, 'lab', 'calibracion');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (35, 'lab', 'categoriamaterial');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (36, 'lab', 'ensayo');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (37, 'lab', 'equipo');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (38, 'lab', 'especimen');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (39, 'lab', 'importacion');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (40, 'lab', 'importacionfila');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (41, 'lab', 'informe');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (42, 'lab', 'informeensayo');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (43, 'lab', 'medicion');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (44, 'lab', 'metodoensayo');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (45, 'lab', 'metodotipoespecimen');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (46, 'lab', 'movimientoespecimen');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (47, 'lab', 'muestra');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (48, 'lab', 'norma');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (49, 'lab', 'parametrometodo');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (50, 'lab', 'proveedormaterial');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (51, 'lab', 'remision');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (52, 'lab', 'resultadocompresion');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (53, 'lab', 'tipoespecimen');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (54, 'lab', 'tipofalla');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (55, 'lab', 'ubicacion');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (56, 'lab', 'usuariorol');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (57, 'lab', 'vistacurvaresistencia');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (58, 'lab', 'vistaprogramacionensayos');
INSERT INTO public.django_content_type (id, app_label, model) VALUES (59, 'lab', 'vistaresultadoscompresion');


--
-- Data for Name: django_migrations; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.django_migrations (id, app, name, applied) VALUES (1, 'contenttypes', '0001_initial', '2026-11-06 14:34:56.019646-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (2, 'contenttypes', '0002_remove_content_type_name', '2026-11-06 14:34:56.025391-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (3, 'auth', '0001_initial', '2026-11-06 14:34:56.046295-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (4, 'auth', '0002_alter_permission_name_max_length', '2026-11-06 14:34:56.049761-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (5, 'auth', '0003_alter_user_email_max_length', '2026-11-06 14:34:56.053555-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (6, 'auth', '0004_alter_user_username_opts', '2026-11-06 14:34:56.058178-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (7, 'auth', '0005_alter_user_last_login_null', '2026-11-06 14:34:56.062696-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (8, 'auth', '0006_require_contenttypes_0002', '2026-11-06 14:34:56.064003-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (9, 'auth', '0007_alter_validators_add_error_messages', '2026-11-06 14:34:56.069249-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (10, 'auth', '0008_alter_user_username_max_length', '2026-11-06 14:34:56.072865-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (11, 'auth', '0009_alter_user_last_name_max_length', '2026-11-06 14:34:56.076554-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (12, 'auth', '0010_alter_group_name_max_length', '2026-11-06 14:34:56.081863-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (13, 'auth', '0011_update_proxy_permissions', '2026-11-06 14:34:56.085199-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (14, 'auth', '0012_alter_user_first_name_max_length', '2026-11-06 14:34:56.088672-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (15, 'nucleo', '0001_initial', '2026-11-06 14:34:56.28789-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (16, 'admin', '0001_initial', '2026-11-06 14:34:56.304592-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (17, 'admin', '0002_logentry_remove_auto_add', '2026-11-06 14:34:56.311262-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (18, 'admin', '0003_logentry_add_action_flag_choices', '2026-11-06 14:34:56.317972-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (19, 'finanzas', '0001_initial', '2026-11-06 14:34:56.348057-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (20, 'finanzas', '0002_initial', '2026-11-06 14:34:56.475297-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (21, 'nucleo', '0002_ubicacion_tipo_persona_documento', '2026-11-06 14:34:56.50397-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (22, 'nucleo', '0003_contactocliente', '2026-11-06 14:34:56.524114-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (23, 'lab', '0001_initial', '2026-11-06 14:34:56.613348-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (24, 'lectura', '0001_initial', '2026-11-06 14:34:56.849722-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (25, 'nucleo', '0004_roldepartamento', '2026-11-06 14:34:56.882249-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (26, 'rrhh', '0001_initial', '2026-11-06 14:34:57.207261-06');
INSERT INTO public.django_migrations (id, app, name, applied) VALUES (27, 'sessions', '0001_initial', '2026-11-06 14:34:57.214703-06');


--
-- Data for Name: django_session; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: finanzas_cuentaporcobrar; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: finanzas_cuentaporcobraritem; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: finanzas_pago; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: finanzas_proforma; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: finanzas_proformaitem; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_alerta; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_cambio; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_cuadrilla; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_cuadrilla_miembros; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_ensayo; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_entregable; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_envioexterno; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_etapaconfig; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('solicitud', 1, 'Solicitud', 'gestion_ofertas', 2, 'habiles', true, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('oferta_enviada', 2, 'Oferta enviada', 'gestion_ofertas', 7, 'calendario', true, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('aceptada', 3, 'Aceptada', 'gestion_ofertas', 3, 'habiles', true, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('anticipo_confirmado', 4, 'Anticipo confirmado', 'gestion_administracion', 3, 'calendario', false, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('programada', 5, 'Programada', 'gestion_programacion', NULL, NULL, false, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('campo_en_ejecucion', 6, 'Campo en ejecución', 'gestion_programacion', NULL, NULL, false, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('campo_completo', 7, 'Campo completo', 'gestion_programacion', 7, 'calendario', false, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('muestras_completas', 8, 'Muestras completas', 'gestion_laboratorio', 1, 'habiles', true, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('laboratorio', 9, 'Laboratorio', 'gestion_laboratorio', 5, 'habiles', false, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('gabinete', 10, 'Gabinete', 'gestion_gabinete', 5, 'habiles', false, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('saldo_pagado', 11, 'Saldo pagado', 'gestion_administracion', NULL, NULL, true, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');
INSERT INTO public.gestion_etapaconfig (etapa, posicion, nombre, grupo_responsable, tiempo_objetivo, tipo_dias, es_supuesto, datos_extra, creado_en, actualizado_en) VALUES ('entregado', 12, 'Entregado', 'gestion_gabinete', NULL, NULL, false, '{}', '2026-11-06 14:34:58.045159-06', '2026-11-06 14:34:58.045159-06');


--
-- Data for Name: gestion_eventoetapa; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_expediente; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_feriado; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-01-01', 'Año Nuevo', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-04-02', 'Jueves Santo', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-04-03', 'Viernes Santo', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-04-04', 'Sábado Santo', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-05-01', 'Día del Trabajo', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-05-10', 'Día de la Madre', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-06-17', 'Día del Padre', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-08-03', 'Fiestas agostinas', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-08-04', 'Fiestas agostinas', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-08-05', 'Fiestas agostinas', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-08-06', 'Fiestas agostinas', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-09-15', 'Independencia', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-11-02', 'Día de los Difuntos', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2026-12-25', 'Navidad', true, '2026-11-06 14:34:58.045971-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-01-01', 'Año Nuevo', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-03-25', 'Jueves Santo', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-03-26', 'Viernes Santo', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-03-27', 'Sábado Santo', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-05-01', 'Día del Trabajo', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-05-10', 'Día de la Madre', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-06-17', 'Día del Padre', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-08-03', 'Fiestas agostinas', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-08-04', 'Fiestas agostinas', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-08-05', 'Fiestas agostinas', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-08-06', 'Fiestas agostinas', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-09-15', 'Independencia', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-11-02', 'Día de los Difuntos', true, '2026-11-06 14:34:58.085333-06');
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto, creado_en) VALUES ('2027-12-25', 'Navidad', true, '2026-11-06 14:34:58.085333-06');


--
-- Data for Name: gestion_fotocampo; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_laboratorioexterno; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_oferta; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_ofertaedicion; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_ofertaitem; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_ofertalote; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_programacion; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_punto; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_recepcion; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_recepcionpunto; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_reglaalerta; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('6dbf9304-085f-46b1-b54a-41050187e6c7', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A1', 'Solicitud sin oferta', 'Pasan 2 días hábiles desde la solicitud sin enviar oferta.', 2, 'habiles', 'advertencia', '["gestion_ofertas"]', 'sistema_correo', true, true, 'solicitud');
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('e4e24ef1-4bed-4009-922b-7caa9588685d', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A2', 'Oferta sin respuesta', 'Pasan 7 días sin respuesta; se repite 2 días antes de vencer. Al vencer queda como vencida y se puede aceptar después.', 7, 'calendario', 'advertencia', '["gestion_ofertas"]', 'sistema', true, true, 'oferta_enviada');
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('5f84269f-eb5e-447e-8a36-941394250764', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A3', 'Aceptada sin anticipo', 'Pasan 3 días hábiles desde la aceptación sin confirmar el anticipo.', 3, 'habiles', 'advertencia', '["gestion_ofertas", "gestion_jefatura"]', 'sistema_correo', true, true, 'aceptada');
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('ee33cc50-c3cc-479c-8e59-7ea40557498f', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A4', 'Anticipo sin programar', 'Pasan 3 días desde el pago del anticipo y el trabajo no está en el calendario.', 3, 'dias', 'aviso', '["gestion_programacion"]', 'sistema', true, true, 'anticipo_confirmado');
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('2a267045-4da9-43bf-afc5-2ea1d8942136', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A6', 'Campo incompleto', 'Pasa 1 semana desde la programación y el campo no está completo. Se repite hasta reprogramar.', 7, 'dias', 'advertencia', '["gestion_programacion", "gestion_jefatura"]', 'sistema_correo', true, true, 'campo_completo');
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('14555615-3c48-49fc-9ed3-cdff973907fb', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A7', 'Faltan muestras', 'Pasa 1 día hábil después de ejecutar un punto y sus muestras no han llegado.', 1, 'habiles', 'advertencia', '["gestion_laboratorio", "gestion_programacion"]', 'sistema', true, true, 'muestras_completas');
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('f1bc3b5f-dd41-498a-83d1-5ff9f707647d', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A8', 'Entrega sin verificar', 'Pasan 12 horas sin que el laboratorio verifique una entrega de muestras.', 12, 'horas', 'advertencia', '["gestion_laboratorio"]', 'sistema', true, true, 'muestras_completas');
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('f447a1e9-a2d2-4536-8f54-2beb5528062b', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A9', 'Ensayo externo sin resultado', 'Pasó la fecha prometida por el laboratorio externo, o faltan menos días de los que necesita gabinete.', 0, 'habiles', 'critica', '["gestion_gabinete", "gestion_jefatura"]', 'sistema_correo', true, true, 'laboratorio');
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('1c8f93e6-74ca-45ca-881a-ab125942a4a9', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A10', 'Entrega en riesgo', 'Los días que quedan son menos que el trabajo pendiente estimado. Con 1 día de margen o menos queda en Atención.', 1, 'habiles', 'critica', '["gestion_jefatura"]', 'sistema_correo', true, true, NULL);
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('a5722707-4b54-4276-8e62-7c794e8595a3', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A11', 'Cambio de prioridad o de fecha', 'Alguien cambia la prioridad o una fecha (motivo obligatorio). Aplica en cualquier etapa.', NULL, NULL, 'aviso', '["gestion_laboratorio", "gestion_gabinete", "gestion_programacion"]', 'sistema', true, false, NULL);
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('d3566935-ef61-4a59-93be-09eaa49aaa96', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A12', 'Entrega vencida', 'Pasó la fecha límite del cliente sin entregar el informe.', 0, 'calendario', 'critica', '["gestion_jefatura"]', 'sistema_correo', true, false, 'entregado');
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('405b3803-a00c-4d93-b82c-ed1e3ca1835c', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A13', 'Laboratorio atrasado', 'Pasan más de 3 días de la fecha límite interna del laboratorio sin entregar resultados.', 3, 'dias', 'advertencia', '["gestion_laboratorio", "gestion_jefatura"]', 'sistema', true, true, 'laboratorio');
INSERT INTO public.gestion_reglaalerta (id, datos_extra, creado_en, actualizado_en, codigo, nombre, condicion, umbral, umbral_tipo, severidad, grupos_destino, medio, activa, es_supuesto, etapa) VALUES ('f1b1fa22-d55a-4915-9707-9ec65b5ca682', '{}', '2026-11-06 14:34:58.045512-06', '2026-11-06 14:34:58.045512-06', 'A14', 'Informe sin terminar', 'Faltan 3 días para la fecha límite del cliente y el informe no está listo (la meta es tenerlo 1 semana antes).', 3, 'dias', 'critica', '["gestion_gabinete", "gestion_jefatura"]', 'sistema_correo', true, true, 'gabinete');


--
-- Data for Name: gestion_servicioconfig; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_solicitud; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: gestion_tipoexploracion; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.gestion_tipoexploracion (codigo, posicion, nombre, unidad_campo, muestras_por_metro, procesamiento, cuadrilla_tipo, suele_ser_insumo, ensayos_tipicos, notas, datos_extra, creado_en, actualizado_en) VALUES ('spt', 1, 'Sondeo de penetración estándar (SPT)', 'sondeo', 2.00, 'laboratorio', 'spt', false, 'Descripción visual-manual (D2488), clasificación SUCS (D2487), humedad (D2216); a veces límites (D4318) y granulometría (D6913)', 'El más pedido. Una muestra cada 0.50 m. Metro adicional con permiso del cliente.', '{}', '2026-11-06 14:34:58.044333-06', '2026-11-06 14:34:58.044333-06');
INSERT INTO public.gestion_tipoexploracion (codigo, posicion, nombre, unidad_campo, muestras_por_metro, procesamiento, cuadrilla_tipo, suele_ser_insumo, ensayos_tipicos, notas, datos_extra, creado_en, actualizado_en) VALUES ('permeabilidad', 2, 'Prueba de permeabilidad por inyección', 'prueba', NULL, 'campo', 'spt', false, 'Tiempo de descenso del agua en tubo PVC', 'Se hace dentro de un sondeo SPT; el resultado va en el informe completo.', '{}', '2026-11-06 14:34:58.044333-06', '2026-11-06 14:34:58.044333-06');
INSERT INTO public.gestion_tipoexploracion (codigo, posicion, nombre, unidad_campo, muestras_por_metro, procesamiento, cuadrilla_tipo, suele_ser_insumo, ensayos_tipicos, notas, datos_extra, creado_en, actualizado_en) VALUES ('infiltracion', 3, 'Prueba de tasa de infiltración (Guía MINSAL)', 'prueba', NULL, 'campo', 'spt', false, 'Tasa de infiltración en excavación de 1 m', 'Formato que se llena en campo; no pasa por laboratorio.', '{}', '2026-11-06 14:34:58.044333-06', '2026-11-06 14:34:58.044333-06');
INSERT INTO public.gestion_tipoexploracion (codigo, posicion, nombre, unidad_campo, muestras_por_metro, procesamiento, cuadrilla_tipo, suele_ser_insumo, ensayos_tipicos, notas, datos_extra, creado_en, actualizado_en) VALUES ('geofisica', 4, 'Sondeo geofísico (ReMi / MASW)', 'linea', NULL, 'geofisica', 'geofisica', true, 'Perfil de velocidad de onda', 'De los más usados después del SPT. Lo procesa el encargado de geofísica, no el laboratorio. Usa personal de la cuadrilla SPT. Suele ser insumo del informe de diseño.', '{}', '2026-11-06 14:34:58.044333-06', '2026-11-06 14:34:58.044333-06');
INSERT INTO public.gestion_tipoexploracion (codigo, posicion, nombre, unidad_campo, muestras_por_metro, procesamiento, cuadrilla_tipo, suele_ser_insumo, ensayos_tipicos, notas, datos_extra, creado_en, actualizado_en) VALUES ('rotativo', 5, 'Sondeo rotativo', 'sondeo', NULL, 'laboratorio', 'rotativa', false, 'RQD, compresión de roca (interna), clasificación de núcleos', 'De los más usados después del SPT. Hasta 100 m. Unos 3 días de campo para 30 m; el plazo pasa a unos 40 días. La ingeniera revisa la roca antes de ensayar núcleos.', '{}', '2026-11-06 14:34:58.044333-06', '2026-11-06 14:34:58.044333-06');
INSERT INTO public.gestion_tipoexploracion (codigo, posicion, nombre, unidad_campo, muestras_por_metro, procesamiento, cuadrilla_tipo, suele_ser_insumo, ensayos_tipicos, notas, datos_extra, creado_en, actualizado_en) VALUES ('inalterada', 6, 'Toma de muestras inalteradas', 'bloque', NULL, 'laboratorio', 'general', true, 'Corte directo y triaxial (externos, ocasionales)', 'Bloques tomados en un pozo (PCA). Insumo para estabilidad de taludes.', '{}', '2026-11-06 14:34:58.044333-06', '2026-11-06 14:34:58.044333-06');
INSERT INTO public.gestion_tipoexploracion (codigo, posicion, nombre, unidad_campo, muestras_por_metro, procesamiento, cuadrilla_tipo, suele_ser_insumo, ensayos_tipicos, notas, datos_extra, creado_en, actualizado_en) VALUES ('pca', 7, 'Pozo a cielo abierto (PCA) para caracterización', 'pozo', NULL, 'laboratorio', 'general', true, 'Granulometría, densidad en el sitio, Proctor, CBR (24 a 48 h de saturación)', 'Excavación de ~1 m; muestras en sacos por estrato. Insumo para diseño de pavimentos.', '{}', '2026-11-06 14:34:58.044333-06', '2026-11-06 14:34:58.044333-06');


--
-- Data for Name: lectura_campoleido; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: lectura_confusioncaracter; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: lectura_hojaescaneada; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: lectura_sinonimo; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_avanceproyecto; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_cliente; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_contactocliente; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_departamento; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_empleado; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_proyecto; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_proyectotecnico; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_reportesemanal; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_roldepartamento; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_servicio; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_usuario; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_usuario_groups; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: nucleo_usuario_user_permissions; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: rrhh_boleta; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: rrhh_comprobante; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: rrhh_contrato; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: rrhh_horaextra; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: rrhh_horaextradia; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: rrhh_lineaplanilla; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: rrhh_planilla; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: rrhh_prestamo; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: rrhh_registrohoraextra; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: rrhh_tarifahoraextra; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Name: areas_id_seq; Type: SEQUENCE SET; Schema: lab; Owner: -
--

SELECT pg_catalog.setval('lab.areas_id_seq', 1, false);


--
-- Name: auditoria_id_seq; Type: SEQUENCE SET; Schema: lab; Owner: -
--

SELECT pg_catalog.setval('lab.auditoria_id_seq', 1, false);


--
-- Name: categorias_material_id_seq; Type: SEQUENCE SET; Schema: lab; Owner: -
--

SELECT pg_catalog.setval('lab.categorias_material_id_seq', 1, false);


--
-- Name: importacion_filas_id_seq; Type: SEQUENCE SET; Schema: lab; Owner: -
--

SELECT pg_catalog.setval('lab.importacion_filas_id_seq', 1, false);


--
-- Name: mediciones_id_seq; Type: SEQUENCE SET; Schema: lab; Owner: -
--

SELECT pg_catalog.setval('lab.mediciones_id_seq', 1, false);


--
-- Name: metodos_ensayo_id_seq; Type: SEQUENCE SET; Schema: lab; Owner: -
--

SELECT pg_catalog.setval('lab.metodos_ensayo_id_seq', 1, false);


--
-- Name: movimientos_especimen_id_seq; Type: SEQUENCE SET; Schema: lab; Owner: -
--

SELECT pg_catalog.setval('lab.movimientos_especimen_id_seq', 1, false);


--
-- Name: normas_id_seq; Type: SEQUENCE SET; Schema: lab; Owner: -
--

SELECT pg_catalog.setval('lab.normas_id_seq', 1, false);


--
-- Name: parametros_metodo_id_seq; Type: SEQUENCE SET; Schema: lab; Owner: -
--

SELECT pg_catalog.setval('lab.parametros_metodo_id_seq', 1, false);


--
-- Name: tipos_especimen_id_seq; Type: SEQUENCE SET; Schema: lab; Owner: -
--

SELECT pg_catalog.setval('lab.tipos_especimen_id_seq', 1, false);


--
-- Name: auth_group_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.auth_group_id_seq', 6, true);


--
-- Name: auth_group_permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.auth_group_permissions_id_seq', 1, false);


--
-- Name: auth_permission_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.auth_permission_id_seq', 236, true);


--
-- Name: django_admin_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.django_admin_log_id_seq', 1, false);


--
-- Name: django_content_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.django_content_type_id_seq', 59, true);


--
-- Name: django_migrations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.django_migrations_id_seq', 27, true);


--
-- Name: gestion_cuadrilla_miembros_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.gestion_cuadrilla_miembros_id_seq', 1, false);


--
-- Name: nucleo_usuario_groups_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.nucleo_usuario_groups_id_seq', 1, false);


--
-- Name: nucleo_usuario_user_permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.nucleo_usuario_user_permissions_id_seq', 1, false);


--
-- Name: adjuntos adjuntos_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.adjuntos
    ADD CONSTRAINT adjuntos_pkey PRIMARY KEY (id);


--
-- Name: areas areas_nombre_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.areas
    ADD CONSTRAINT areas_nombre_key UNIQUE (nombre);


--
-- Name: areas areas_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.areas
    ADD CONSTRAINT areas_pkey PRIMARY KEY (id);


--
-- Name: auditoria auditoria_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.auditoria
    ADD CONSTRAINT auditoria_pkey PRIMARY KEY (id);


--
-- Name: calibraciones calibraciones_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.calibraciones
    ADD CONSTRAINT calibraciones_pkey PRIMARY KEY (id);


--
-- Name: categorias_material categorias_material_nombre_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.categorias_material
    ADD CONSTRAINT categorias_material_nombre_key UNIQUE (nombre);


--
-- Name: categorias_material categorias_material_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.categorias_material
    ADD CONSTRAINT categorias_material_pkey PRIMARY KEY (id);


--
-- Name: ensayos ensayos_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ensayos
    ADD CONSTRAINT ensayos_pkey PRIMARY KEY (id);


--
-- Name: equipos equipos_codigo_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.equipos
    ADD CONSTRAINT equipos_codigo_key UNIQUE (codigo);


--
-- Name: equipos equipos_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.equipos
    ADD CONSTRAINT equipos_pkey PRIMARY KEY (id);


--
-- Name: especimenes especimenes_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.especimenes
    ADD CONSTRAINT especimenes_pkey PRIMARY KEY (id);


--
-- Name: especimenes especimenes_proyecto_id_tipo_especimen_id_numero_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.especimenes
    ADD CONSTRAINT especimenes_proyecto_id_tipo_especimen_id_numero_key UNIQUE (proyecto_id, tipo_especimen_id, numero);


--
-- Name: importacion_filas importacion_filas_importacion_id_numero_fila_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.importacion_filas
    ADD CONSTRAINT importacion_filas_importacion_id_numero_fila_key UNIQUE (importacion_id, numero_fila);


--
-- Name: importacion_filas importacion_filas_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.importacion_filas
    ADD CONSTRAINT importacion_filas_pkey PRIMARY KEY (id);


--
-- Name: importaciones importaciones_archivo_sha256_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.importaciones
    ADD CONSTRAINT importaciones_archivo_sha256_key UNIQUE (archivo_sha256);


--
-- Name: importaciones importaciones_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.importaciones
    ADD CONSTRAINT importaciones_pkey PRIMARY KEY (id);


--
-- Name: informe_ensayos informe_ensayos_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.informe_ensayos
    ADD CONSTRAINT informe_ensayos_pkey PRIMARY KEY (informe_id, ensayo_id);


--
-- Name: informes informes_codigo_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.informes
    ADD CONSTRAINT informes_codigo_key UNIQUE (codigo);


--
-- Name: informes informes_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.informes
    ADD CONSTRAINT informes_pkey PRIMARY KEY (id);


--
-- Name: mediciones mediciones_ensayo_id_parametro_id_repeticion_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.mediciones
    ADD CONSTRAINT mediciones_ensayo_id_parametro_id_repeticion_key UNIQUE (ensayo_id, parametro_id, repeticion);


--
-- Name: mediciones mediciones_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.mediciones
    ADD CONSTRAINT mediciones_pkey PRIMARY KEY (id);


--
-- Name: metodo_tipos_especimen metodo_tipos_especimen_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.metodo_tipos_especimen
    ADD CONSTRAINT metodo_tipos_especimen_pkey PRIMARY KEY (metodo_id, tipo_especimen_id);


--
-- Name: metodos_ensayo metodos_ensayo_nombre_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.metodos_ensayo
    ADD CONSTRAINT metodos_ensayo_nombre_key UNIQUE (nombre);


--
-- Name: metodos_ensayo metodos_ensayo_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.metodos_ensayo
    ADD CONSTRAINT metodos_ensayo_pkey PRIMARY KEY (id);


--
-- Name: movimientos_especimen movimientos_especimen_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.movimientos_especimen
    ADD CONSTRAINT movimientos_especimen_pkey PRIMARY KEY (id);


--
-- Name: muestras muestras_id_proyecto_id_tipo_especimen_id_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.muestras
    ADD CONSTRAINT muestras_id_proyecto_id_tipo_especimen_id_key UNIQUE (id, proyecto_id, tipo_especimen_id);


--
-- Name: muestras muestras_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.muestras
    ADD CONSTRAINT muestras_pkey PRIMARY KEY (id);


--
-- Name: normas normas_codigo_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.normas
    ADD CONSTRAINT normas_codigo_key UNIQUE (codigo);


--
-- Name: normas normas_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.normas
    ADD CONSTRAINT normas_pkey PRIMARY KEY (id);


--
-- Name: parametros_metodo parametros_metodo_metodo_id_nombre_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.parametros_metodo
    ADD CONSTRAINT parametros_metodo_metodo_id_nombre_key UNIQUE (metodo_id, nombre);


--
-- Name: parametros_metodo parametros_metodo_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.parametros_metodo
    ADD CONSTRAINT parametros_metodo_pkey PRIMARY KEY (id);


--
-- Name: proveedores_material proveedores_material_nombre_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.proveedores_material
    ADD CONSTRAINT proveedores_material_nombre_key UNIQUE (nombre);


--
-- Name: proveedores_material proveedores_material_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.proveedores_material
    ADD CONSTRAINT proveedores_material_pkey PRIMARY KEY (id);


--
-- Name: remisiones remisiones_codigo_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.remisiones
    ADD CONSTRAINT remisiones_codigo_key UNIQUE (codigo);


--
-- Name: remisiones remisiones_id_proyecto_id_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.remisiones
    ADD CONSTRAINT remisiones_id_proyecto_id_key UNIQUE (id, proyecto_id);


--
-- Name: remisiones remisiones_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.remisiones
    ADD CONSTRAINT remisiones_pkey PRIMARY KEY (id);


--
-- Name: resultados_compresion resultados_compresion_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.resultados_compresion
    ADD CONSTRAINT resultados_compresion_pkey PRIMARY KEY (ensayo_id);


--
-- Name: tipos_especimen tipos_especimen_codigo_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.tipos_especimen
    ADD CONSTRAINT tipos_especimen_codigo_key UNIQUE (codigo);


--
-- Name: tipos_especimen tipos_especimen_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.tipos_especimen
    ADD CONSTRAINT tipos_especimen_pkey PRIMARY KEY (id);


--
-- Name: tipos_falla tipos_falla_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.tipos_falla
    ADD CONSTRAINT tipos_falla_pkey PRIMARY KEY (codigo);


--
-- Name: ubicaciones ubicaciones_padre_id_codigo_key; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ubicaciones
    ADD CONSTRAINT ubicaciones_padre_id_codigo_key UNIQUE NULLS NOT DISTINCT (padre_id, codigo);


--
-- Name: ubicaciones ubicaciones_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ubicaciones
    ADD CONSTRAINT ubicaciones_pkey PRIMARY KEY (id);


--
-- Name: usuarios_roles usuarios_roles_pkey; Type: CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.usuarios_roles
    ADD CONSTRAINT usuarios_roles_pkey PRIMARY KEY (empleado_id, rol);


--
-- Name: auth_group auth_group_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group
    ADD CONSTRAINT auth_group_name_key UNIQUE (name);


--
-- Name: auth_group_permissions auth_group_permissions_group_id_permission_id_0cd325b0_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_group_id_permission_id_0cd325b0_uniq UNIQUE (group_id, permission_id);


--
-- Name: auth_group_permissions auth_group_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_pkey PRIMARY KEY (id);


--
-- Name: auth_group auth_group_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group
    ADD CONSTRAINT auth_group_pkey PRIMARY KEY (id);


--
-- Name: auth_permission auth_permission_content_type_id_codename_01ab375a_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_codename_01ab375a_uniq UNIQUE (content_type_id, codename);


--
-- Name: auth_permission auth_permission_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_pkey PRIMARY KEY (id);


--
-- Name: lectura_campoleido campo_leido_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_campoleido
    ADD CONSTRAINT campo_leido_unico UNIQUE (hoja_id, fila, campo);


--
-- Name: gestion_cuadrilla_miembros cuadrilla_miembro_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_cuadrilla_miembros
    ADD CONSTRAINT cuadrilla_miembro_unico UNIQUE (cuadrilla_id, empleado_id);


--
-- Name: gestion_cuadrilla cuadrilla_nombre_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_cuadrilla
    ADD CONSTRAINT cuadrilla_nombre_unico UNIQUE (nombre);


--
-- Name: django_admin_log django_admin_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_pkey PRIMARY KEY (id);


--
-- Name: django_content_type django_content_type_app_label_model_76bd3d3b_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_content_type
    ADD CONSTRAINT django_content_type_app_label_model_76bd3d3b_uniq UNIQUE (app_label, model);


--
-- Name: django_content_type django_content_type_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_content_type
    ADD CONSTRAINT django_content_type_pkey PRIMARY KEY (id);


--
-- Name: django_migrations django_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_migrations
    ADD CONSTRAINT django_migrations_pkey PRIMARY KEY (id);


--
-- Name: django_session django_session_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_session
    ADD CONSTRAINT django_session_pkey PRIMARY KEY (session_key);


--
-- Name: nucleo_empleado empleado_dui_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_empleado
    ADD CONSTRAINT empleado_dui_unico UNIQUE (dui);


--
-- Name: gestion_etapaconfig etapaconfig_posicion_unica; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_etapaconfig
    ADD CONSTRAINT etapaconfig_posicion_unica UNIQUE (posicion);


--
-- Name: gestion_expediente expediente_lote_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_expediente
    ADD CONSTRAINT expediente_lote_unico UNIQUE (lote_id);


--
-- Name: finanzas_cuentaporcobrar finanzas_cuentaporcobrar_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_cuentaporcobrar
    ADD CONSTRAINT finanzas_cuentaporcobrar_mongo_id_key UNIQUE (mongo_id);


--
-- Name: finanzas_cuentaporcobrar finanzas_cuentaporcobrar_numero_factura_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_cuentaporcobrar
    ADD CONSTRAINT finanzas_cuentaporcobrar_numero_factura_key UNIQUE (numero_factura);


--
-- Name: finanzas_cuentaporcobrar finanzas_cuentaporcobrar_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_cuentaporcobrar
    ADD CONSTRAINT finanzas_cuentaporcobrar_pkey PRIMARY KEY (id);


--
-- Name: finanzas_cuentaporcobraritem finanzas_cuentaporcobraritem_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_cuentaporcobraritem
    ADD CONSTRAINT finanzas_cuentaporcobraritem_mongo_id_key UNIQUE (mongo_id);


--
-- Name: finanzas_cuentaporcobraritem finanzas_cuentaporcobraritem_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_cuentaporcobraritem
    ADD CONSTRAINT finanzas_cuentaporcobraritem_pkey PRIMARY KEY (id);


--
-- Name: finanzas_pago finanzas_pago_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_pago
    ADD CONSTRAINT finanzas_pago_mongo_id_key UNIQUE (mongo_id);


--
-- Name: finanzas_pago finanzas_pago_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_pago
    ADD CONSTRAINT finanzas_pago_pkey PRIMARY KEY (id);


--
-- Name: finanzas_proforma finanzas_proforma_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_proforma
    ADD CONSTRAINT finanzas_proforma_mongo_id_key UNIQUE (mongo_id);


--
-- Name: finanzas_proforma finanzas_proforma_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_proforma
    ADD CONSTRAINT finanzas_proforma_pkey PRIMARY KEY (id);


--
-- Name: finanzas_proformaitem finanzas_proformaitem_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_proformaitem
    ADD CONSTRAINT finanzas_proformaitem_mongo_id_key UNIQUE (mongo_id);


--
-- Name: finanzas_proformaitem finanzas_proformaitem_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_proformaitem
    ADD CONSTRAINT finanzas_proformaitem_pkey PRIMARY KEY (id);


--
-- Name: gestion_fotocampo fotocampo_avance_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_fotocampo
    ADD CONSTRAINT fotocampo_avance_unico UNIQUE (avance_id);


--
-- Name: gestion_alerta gestion_alerta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_alerta
    ADD CONSTRAINT gestion_alerta_pkey PRIMARY KEY (id);


--
-- Name: gestion_cambio gestion_cambio_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_cambio
    ADD CONSTRAINT gestion_cambio_pkey PRIMARY KEY (id);


--
-- Name: gestion_cuadrilla_miembros gestion_cuadrilla_miembros_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_cuadrilla_miembros
    ADD CONSTRAINT gestion_cuadrilla_miembros_pkey PRIMARY KEY (id);


--
-- Name: gestion_cuadrilla gestion_cuadrilla_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_cuadrilla
    ADD CONSTRAINT gestion_cuadrilla_pkey PRIMARY KEY (id);


--
-- Name: gestion_ensayo gestion_ensayo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ensayo
    ADD CONSTRAINT gestion_ensayo_pkey PRIMARY KEY (id);


--
-- Name: gestion_entregable gestion_entregable_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_entregable
    ADD CONSTRAINT gestion_entregable_pkey PRIMARY KEY (id);


--
-- Name: gestion_envioexterno gestion_envioexterno_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_envioexterno
    ADD CONSTRAINT gestion_envioexterno_pkey PRIMARY KEY (id);


--
-- Name: gestion_etapaconfig gestion_etapaconfig_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_etapaconfig
    ADD CONSTRAINT gestion_etapaconfig_pkey PRIMARY KEY (etapa);


--
-- Name: gestion_eventoetapa gestion_eventoetapa_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_eventoetapa
    ADD CONSTRAINT gestion_eventoetapa_pkey PRIMARY KEY (id);


--
-- Name: gestion_expediente gestion_expediente_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_expediente
    ADD CONSTRAINT gestion_expediente_pkey PRIMARY KEY (id);


--
-- Name: gestion_feriado gestion_feriado_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_feriado
    ADD CONSTRAINT gestion_feriado_pkey PRIMARY KEY (fecha);


--
-- Name: gestion_fotocampo gestion_fotocampo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_fotocampo
    ADD CONSTRAINT gestion_fotocampo_pkey PRIMARY KEY (id);


--
-- Name: gestion_laboratorioexterno gestion_laboratorioexterno_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_laboratorioexterno
    ADD CONSTRAINT gestion_laboratorioexterno_pkey PRIMARY KEY (id);


--
-- Name: gestion_oferta gestion_oferta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_oferta
    ADD CONSTRAINT gestion_oferta_pkey PRIMARY KEY (id);


--
-- Name: gestion_ofertaedicion gestion_ofertaedicion_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ofertaedicion
    ADD CONSTRAINT gestion_ofertaedicion_pkey PRIMARY KEY (id);


--
-- Name: gestion_ofertaitem gestion_ofertaitem_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ofertaitem
    ADD CONSTRAINT gestion_ofertaitem_pkey PRIMARY KEY (id);


--
-- Name: gestion_ofertalote gestion_ofertalote_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ofertalote
    ADD CONSTRAINT gestion_ofertalote_pkey PRIMARY KEY (id);


--
-- Name: gestion_programacion gestion_programacion_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_programacion
    ADD CONSTRAINT gestion_programacion_pkey PRIMARY KEY (id);


--
-- Name: gestion_punto gestion_punto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_punto
    ADD CONSTRAINT gestion_punto_pkey PRIMARY KEY (id);


--
-- Name: gestion_recepcion gestion_recepcion_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_recepcion
    ADD CONSTRAINT gestion_recepcion_pkey PRIMARY KEY (id);


--
-- Name: gestion_recepcionpunto gestion_recepcionpunto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_recepcionpunto
    ADD CONSTRAINT gestion_recepcionpunto_pkey PRIMARY KEY (id);


--
-- Name: gestion_reglaalerta gestion_reglaalerta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_reglaalerta
    ADD CONSTRAINT gestion_reglaalerta_pkey PRIMARY KEY (id);


--
-- Name: gestion_servicioconfig gestion_servicioconfig_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_servicioconfig
    ADD CONSTRAINT gestion_servicioconfig_pkey PRIMARY KEY (servicio_id);


--
-- Name: gestion_solicitud gestion_solicitud_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_solicitud
    ADD CONSTRAINT gestion_solicitud_pkey PRIMARY KEY (id);


--
-- Name: gestion_tipoexploracion gestion_tipoexploracion_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_tipoexploracion
    ADD CONSTRAINT gestion_tipoexploracion_pkey PRIMARY KEY (codigo);


--
-- Name: rrhh_horaextradia horaextradia_sin_traslape; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horaextradia
    ADD CONSTRAINT horaextradia_sin_traslape EXCLUDE USING gist (registro_id WITH =, tsrange(inicia_en, termina_en) WITH &&);


--
-- Name: gestion_laboratorioexterno laboratorioexterno_nombre_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_laboratorioexterno
    ADD CONSTRAINT laboratorioexterno_nombre_unico UNIQUE (nombre);


--
-- Name: lectura_campoleido lectura_campoleido_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_campoleido
    ADD CONSTRAINT lectura_campoleido_mongo_id_key UNIQUE (mongo_id);


--
-- Name: lectura_campoleido lectura_campoleido_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_campoleido
    ADD CONSTRAINT lectura_campoleido_pkey PRIMARY KEY (id);


--
-- Name: lectura_confusioncaracter lectura_confusioncaracter_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_confusioncaracter
    ADD CONSTRAINT lectura_confusioncaracter_mongo_id_key UNIQUE (mongo_id);


--
-- Name: lectura_confusioncaracter lectura_confusioncaracter_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_confusioncaracter
    ADD CONSTRAINT lectura_confusioncaracter_pkey PRIMARY KEY (id);


--
-- Name: lectura_hojaescaneada lectura_hojaescaneada_imagen_sha256_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_hojaescaneada
    ADD CONSTRAINT lectura_hojaescaneada_imagen_sha256_key UNIQUE (imagen_sha256);


--
-- Name: lectura_hojaescaneada lectura_hojaescaneada_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_hojaescaneada
    ADD CONSTRAINT lectura_hojaescaneada_mongo_id_key UNIQUE (mongo_id);


--
-- Name: lectura_hojaescaneada lectura_hojaescaneada_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_hojaescaneada
    ADD CONSTRAINT lectura_hojaescaneada_pkey PRIMARY KEY (id);


--
-- Name: lectura_sinonimo lectura_sinonimo_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_sinonimo
    ADD CONSTRAINT lectura_sinonimo_mongo_id_key UNIQUE (mongo_id);


--
-- Name: lectura_sinonimo lectura_sinonimo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_sinonimo
    ADD CONSTRAINT lectura_sinonimo_pkey PRIMARY KEY (id);


--
-- Name: rrhh_lineaplanilla linea_planilla_empleado_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_lineaplanilla
    ADD CONSTRAINT linea_planilla_empleado_unico UNIQUE (planilla_id, empleado_id);


--
-- Name: nucleo_avanceproyecto nucleo_avanceproyecto_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_avanceproyecto
    ADD CONSTRAINT nucleo_avanceproyecto_mongo_id_key UNIQUE (mongo_id);


--
-- Name: nucleo_avanceproyecto nucleo_avanceproyecto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_avanceproyecto
    ADD CONSTRAINT nucleo_avanceproyecto_pkey PRIMARY KEY (id);


--
-- Name: nucleo_cliente nucleo_cliente_dui_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_cliente
    ADD CONSTRAINT nucleo_cliente_dui_key UNIQUE (dui);


--
-- Name: nucleo_cliente nucleo_cliente_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_cliente
    ADD CONSTRAINT nucleo_cliente_mongo_id_key UNIQUE (mongo_id);


--
-- Name: nucleo_cliente nucleo_cliente_nit_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_cliente
    ADD CONSTRAINT nucleo_cliente_nit_key UNIQUE (nit);


--
-- Name: nucleo_cliente nucleo_cliente_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_cliente
    ADD CONSTRAINT nucleo_cliente_pkey PRIMARY KEY (id);


--
-- Name: nucleo_cliente nucleo_cliente_ruc_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_cliente
    ADD CONSTRAINT nucleo_cliente_ruc_key UNIQUE (ruc);


--
-- Name: nucleo_contactocliente nucleo_contactocliente_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_contactocliente
    ADD CONSTRAINT nucleo_contactocliente_pkey PRIMARY KEY (id);


--
-- Name: nucleo_departamento nucleo_departamento_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_departamento
    ADD CONSTRAINT nucleo_departamento_mongo_id_key UNIQUE (mongo_id);


--
-- Name: nucleo_departamento nucleo_departamento_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_departamento
    ADD CONSTRAINT nucleo_departamento_pkey PRIMARY KEY (id);


--
-- Name: nucleo_empleado nucleo_empleado_codigo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_empleado
    ADD CONSTRAINT nucleo_empleado_codigo_key UNIQUE (codigo);


--
-- Name: nucleo_empleado nucleo_empleado_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_empleado
    ADD CONSTRAINT nucleo_empleado_mongo_id_key UNIQUE (mongo_id);


--
-- Name: nucleo_empleado nucleo_empleado_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_empleado
    ADD CONSTRAINT nucleo_empleado_pkey PRIMARY KEY (id);


--
-- Name: nucleo_empleado nucleo_empleado_usuario_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_empleado
    ADD CONSTRAINT nucleo_empleado_usuario_id_key UNIQUE (usuario_id);


--
-- Name: nucleo_proyecto nucleo_proyecto_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_proyecto
    ADD CONSTRAINT nucleo_proyecto_mongo_id_key UNIQUE (mongo_id);


--
-- Name: nucleo_proyecto nucleo_proyecto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_proyecto
    ADD CONSTRAINT nucleo_proyecto_pkey PRIMARY KEY (id);


--
-- Name: nucleo_proyectotecnico nucleo_proyectotecnico_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_proyectotecnico
    ADD CONSTRAINT nucleo_proyectotecnico_mongo_id_key UNIQUE (mongo_id);


--
-- Name: nucleo_proyectotecnico nucleo_proyectotecnico_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_proyectotecnico
    ADD CONSTRAINT nucleo_proyectotecnico_pkey PRIMARY KEY (id);


--
-- Name: nucleo_reportesemanal nucleo_reportesemanal_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_reportesemanal
    ADD CONSTRAINT nucleo_reportesemanal_mongo_id_key UNIQUE (mongo_id);


--
-- Name: nucleo_reportesemanal nucleo_reportesemanal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_reportesemanal
    ADD CONSTRAINT nucleo_reportesemanal_pkey PRIMARY KEY (id);


--
-- Name: nucleo_roldepartamento nucleo_roldepartamento_grupo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_roldepartamento
    ADD CONSTRAINT nucleo_roldepartamento_grupo_id_key UNIQUE (grupo_id);


--
-- Name: nucleo_roldepartamento nucleo_roldepartamento_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_roldepartamento
    ADD CONSTRAINT nucleo_roldepartamento_mongo_id_key UNIQUE (mongo_id);


--
-- Name: nucleo_roldepartamento nucleo_roldepartamento_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_roldepartamento
    ADD CONSTRAINT nucleo_roldepartamento_pkey PRIMARY KEY (id);


--
-- Name: nucleo_servicio nucleo_servicio_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_servicio
    ADD CONSTRAINT nucleo_servicio_mongo_id_key UNIQUE (mongo_id);


--
-- Name: nucleo_servicio nucleo_servicio_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_servicio
    ADD CONSTRAINT nucleo_servicio_pkey PRIMARY KEY (id);


--
-- Name: nucleo_usuario nucleo_usuario_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario
    ADD CONSTRAINT nucleo_usuario_email_key UNIQUE (email);


--
-- Name: nucleo_usuario_groups nucleo_usuario_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario_groups
    ADD CONSTRAINT nucleo_usuario_groups_pkey PRIMARY KEY (id);


--
-- Name: nucleo_usuario_groups nucleo_usuario_groups_usuario_id_group_id_15cc93ad_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario_groups
    ADD CONSTRAINT nucleo_usuario_groups_usuario_id_group_id_15cc93ad_uniq UNIQUE (usuario_id, group_id);


--
-- Name: nucleo_usuario nucleo_usuario_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario
    ADD CONSTRAINT nucleo_usuario_mongo_id_key UNIQUE (mongo_id);


--
-- Name: nucleo_usuario nucleo_usuario_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario
    ADD CONSTRAINT nucleo_usuario_pkey PRIMARY KEY (id);


--
-- Name: nucleo_usuario_user_permissions nucleo_usuario_user_perm_usuario_id_permission_id_50a2364d_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario_user_permissions
    ADD CONSTRAINT nucleo_usuario_user_perm_usuario_id_permission_id_50a2364d_uniq UNIQUE (usuario_id, permission_id);


--
-- Name: nucleo_usuario_user_permissions nucleo_usuario_user_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario_user_permissions
    ADD CONSTRAINT nucleo_usuario_user_permissions_pkey PRIMARY KEY (id);


--
-- Name: gestion_oferta oferta_codigo_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_oferta
    ADD CONSTRAINT oferta_codigo_unico UNIQUE (codigo);


--
-- Name: gestion_oferta oferta_correlativo_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_oferta
    ADD CONSTRAINT oferta_correlativo_unico UNIQUE (prefijo, anio, correlativo);


--
-- Name: gestion_ofertaedicion ofertaedicion_unica; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ofertaedicion
    ADD CONSTRAINT ofertaedicion_unica UNIQUE (oferta_id, edicion);


--
-- Name: gestion_ofertalote ofertalote_nombre_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ofertalote
    ADD CONSTRAINT ofertalote_nombre_unico UNIQUE (oferta_id, nombre);


--
-- Name: nucleo_proyectotecnico proyecto_tecnico_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_proyectotecnico
    ADD CONSTRAINT proyecto_tecnico_unico UNIQUE (proyecto_id, empleado_id);


--
-- Name: gestion_punto punto_codigo_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_punto
    ADD CONSTRAINT punto_codigo_unico UNIQUE (expediente_id, codigo);


--
-- Name: gestion_recepcionpunto recepcionpunto_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_recepcionpunto
    ADD CONSTRAINT recepcionpunto_unico UNIQUE (recepcion_id, punto_id);


--
-- Name: rrhh_registrohoraextra registro_he_empleado_periodo_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_registrohoraextra
    ADD CONSTRAINT registro_he_empleado_periodo_unico UNIQUE (empleado_id, periodo_fin);


--
-- Name: rrhh_registrohoraextra registro_he_linea_unica; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_registrohoraextra
    ADD CONSTRAINT registro_he_linea_unica UNIQUE (linea_planilla_id);


--
-- Name: gestion_reglaalerta reglaalerta_codigo_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_reglaalerta
    ADD CONSTRAINT reglaalerta_codigo_unico UNIQUE (codigo);


--
-- Name: nucleo_roldepartamento rol_unico_por_departamento; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_roldepartamento
    ADD CONSTRAINT rol_unico_por_departamento UNIQUE (departamento_id, codigo);


--
-- Name: rrhh_boleta rrhh_boleta_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_boleta
    ADD CONSTRAINT rrhh_boleta_mongo_id_key UNIQUE (mongo_id);


--
-- Name: rrhh_boleta rrhh_boleta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_boleta
    ADD CONSTRAINT rrhh_boleta_pkey PRIMARY KEY (id);


--
-- Name: rrhh_comprobante rrhh_comprobante_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_comprobante
    ADD CONSTRAINT rrhh_comprobante_pkey PRIMARY KEY (id);


--
-- Name: rrhh_contrato rrhh_contrato_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_contrato
    ADD CONSTRAINT rrhh_contrato_mongo_id_key UNIQUE (mongo_id);


--
-- Name: rrhh_contrato rrhh_contrato_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_contrato
    ADD CONSTRAINT rrhh_contrato_pkey PRIMARY KEY (id);


--
-- Name: rrhh_horaextra rrhh_horaextra_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horaextra
    ADD CONSTRAINT rrhh_horaextra_mongo_id_key UNIQUE (mongo_id);


--
-- Name: rrhh_horaextra rrhh_horaextra_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horaextra
    ADD CONSTRAINT rrhh_horaextra_pkey PRIMARY KEY (id);


--
-- Name: rrhh_horaextradia rrhh_horaextradia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horaextradia
    ADD CONSTRAINT rrhh_horaextradia_pkey PRIMARY KEY (id);


--
-- Name: rrhh_lineaplanilla rrhh_lineaplanilla_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_lineaplanilla
    ADD CONSTRAINT rrhh_lineaplanilla_mongo_id_key UNIQUE (mongo_id);


--
-- Name: rrhh_lineaplanilla rrhh_lineaplanilla_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_lineaplanilla
    ADD CONSTRAINT rrhh_lineaplanilla_pkey PRIMARY KEY (id);


--
-- Name: rrhh_planilla rrhh_planilla_mongo_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla
    ADD CONSTRAINT rrhh_planilla_mongo_id_key UNIQUE (mongo_id);


--
-- Name: rrhh_planilla rrhh_planilla_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla
    ADD CONSTRAINT rrhh_planilla_pkey PRIMARY KEY (id);


--
-- Name: rrhh_prestamo rrhh_prestamo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_prestamo
    ADD CONSTRAINT rrhh_prestamo_pkey PRIMARY KEY (id);


--
-- Name: rrhh_registrohoraextra rrhh_registrohoraextra_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_registrohoraextra
    ADD CONSTRAINT rrhh_registrohoraextra_pkey PRIMARY KEY (id);


--
-- Name: rrhh_tarifahoraextra rrhh_tarifahoraextra_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_tarifahoraextra
    ADD CONSTRAINT rrhh_tarifahoraextra_pkey PRIMARY KEY (departamento_id);


--
-- Name: lectura_sinonimo sinonimo_unico; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_sinonimo
    ADD CONSTRAINT sinonimo_unico UNIQUE (vocabulario, clave, valor);


--
-- Name: gestion_tipoexploracion tipoexploracion_posicion_unica; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_tipoexploracion
    ADD CONSTRAINT tipoexploracion_posicion_unica UNIQUE (posicion);


--
-- Name: ix_adjuntos_entidad; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_adjuntos_entidad ON lab.adjuntos USING btree (entidad, entidad_id);


--
-- Name: ix_auditoria_registro; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_auditoria_registro ON lab.auditoria USING btree (tabla, registro_id);


--
-- Name: ix_ensayos_ejecutado; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_ensayos_ejecutado ON lab.ensayos USING btree (ejecutado_en);


--
-- Name: ix_ensayos_estado_fecha; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_ensayos_estado_fecha ON lab.ensayos USING btree (estado, fecha_programada);


--
-- Name: ix_especimenes_muestra; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_especimenes_muestra ON lab.especimenes USING btree (muestra_id);


--
-- Name: ix_especimenes_por_ensayar; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_especimenes_por_ensayar ON lab.especimenes USING btree (fecha_ensayo_programada) WHERE (estado = ANY (ARRAY['recibido'::lab.estado_especimen, 'almacenado'::lab.estado_especimen]));


--
-- Name: ix_especimenes_ubicacion; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_especimenes_ubicacion ON lab.especimenes USING btree (ubicacion_id);


--
-- Name: ix_import_filas_importacion; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_import_filas_importacion ON lab.importacion_filas USING btree (importacion_id);


--
-- Name: ix_mediciones_ensayo; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_mediciones_ensayo ON lab.mediciones USING btree (ensayo_id);


--
-- Name: ix_movimientos_especimen; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_movimientos_especimen ON lab.movimientos_especimen USING btree (especimen_id, movido_en);


--
-- Name: ix_muestras_proyecto; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_muestras_proyecto ON lab.muestras USING btree (proyecto_id, fecha_elaboracion);


--
-- Name: ix_muestras_remision; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_muestras_remision ON lab.muestras USING btree (remision_id);


--
-- Name: ix_remisiones_proyecto; Type: INDEX; Schema: lab; Owner: -
--

CREATE INDEX ix_remisiones_proyecto ON lab.remisiones USING btree (proyecto_id, fecha_remision);


--
-- Name: ux_ensayo_por_especimen; Type: INDEX; Schema: lab; Owner: -
--

CREATE UNIQUE INDEX ux_ensayo_por_especimen ON lab.ensayos USING btree (especimen_id, metodo_id);


--
-- Name: auth_group_name_a6ea08ec_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_group_name_a6ea08ec_like ON public.auth_group USING btree (name varchar_pattern_ops);


--
-- Name: auth_group_permissions_group_id_b120cbf9; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_group_permissions_group_id_b120cbf9 ON public.auth_group_permissions USING btree (group_id);


--
-- Name: auth_group_permissions_permission_id_84c5c92e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_group_permissions_permission_id_84c5c92e ON public.auth_group_permissions USING btree (permission_id);


--
-- Name: auth_permission_content_type_id_2f476e4b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auth_permission_content_type_id_2f476e4b ON public.auth_permission USING btree (content_type_id);


--
-- Name: cliente_email_unico; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cliente_email_unico ON public.nucleo_cliente USING btree (lower((email)::text));


--
-- Name: confusion_escritor_unica; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX confusion_escritor_unica ON public.lectura_confusioncaracter USING btree (tipo_campo, escritor_id, leido, "real") WHERE (escritor_id IS NOT NULL);


--
-- Name: confusion_general_unica; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX confusion_general_unica ON public.lectura_confusioncaracter USING btree (tipo_campo, leido, "real") WHERE (escritor_id IS NULL);


--
-- Name: contrato_un_activo_por_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX contrato_un_activo_por_empleado ON public.rrhh_contrato USING btree (empleado_id) WHERE activo;


--
-- Name: django_admin_log_content_type_id_c4bce8eb; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX django_admin_log_content_type_id_c4bce8eb ON public.django_admin_log USING btree (content_type_id);


--
-- Name: django_admin_log_user_id_c564eba6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX django_admin_log_user_id_c564eba6 ON public.django_admin_log USING btree (user_id);


--
-- Name: django_session_expire_date_a5c62663; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX django_session_expire_date_a5c62663 ON public.django_session USING btree (expire_date);


--
-- Name: django_session_session_key_c0390e0f_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX django_session_session_key_c0390e0f_like ON public.django_session USING btree (session_key varchar_pattern_ops);


--
-- Name: empleado_email_unico; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX empleado_email_unico ON public.nucleo_empleado USING btree (lower((email)::text));


--
-- Name: finanzas_cuentaporcobrar_mongo_id_1b91eeec_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_cuentaporcobrar_mongo_id_1b91eeec_like ON public.finanzas_cuentaporcobrar USING btree (mongo_id varchar_pattern_ops);


--
-- Name: finanzas_cuentaporcobrar_numero_factura_bbac87c5_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_cuentaporcobrar_numero_factura_bbac87c5_like ON public.finanzas_cuentaporcobrar USING btree (numero_factura varchar_pattern_ops);


--
-- Name: finanzas_cuentaporcobrar_proforma_id_ba4e8984; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_cuentaporcobrar_proforma_id_ba4e8984 ON public.finanzas_cuentaporcobrar USING btree (proforma_id);


--
-- Name: finanzas_cuentaporcobraritem_cuenta_id_564c83cf; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_cuentaporcobraritem_cuenta_id_564c83cf ON public.finanzas_cuentaporcobraritem USING btree (cuenta_id);


--
-- Name: finanzas_cuentaporcobraritem_mongo_id_8a141307_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_cuentaporcobraritem_mongo_id_8a141307_like ON public.finanzas_cuentaporcobraritem USING btree (mongo_id varchar_pattern_ops);


--
-- Name: finanzas_cuentaporcobraritem_servicio_id_f37074ad; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_cuentaporcobraritem_servicio_id_f37074ad ON public.finanzas_cuentaporcobraritem USING btree (servicio_id);


--
-- Name: finanzas_pago_cuenta_id_d8221b64; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_pago_cuenta_id_d8221b64 ON public.finanzas_pago USING btree (cuenta_id);


--
-- Name: finanzas_pago_mongo_id_6524174c_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_pago_mongo_id_6524174c_like ON public.finanzas_pago USING btree (mongo_id varchar_pattern_ops);


--
-- Name: finanzas_proforma_cliente_id_9f458133; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_proforma_cliente_id_9f458133 ON public.finanzas_proforma USING btree (cliente_id);


--
-- Name: finanzas_proforma_mongo_id_21fe1482_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_proforma_mongo_id_21fe1482_like ON public.finanzas_proforma USING btree (mongo_id varchar_pattern_ops);


--
-- Name: finanzas_proforma_proyecto_id_c68ae01b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_proforma_proyecto_id_c68ae01b ON public.finanzas_proforma USING btree (proyecto_id);


--
-- Name: finanzas_proformaitem_mongo_id_a277dae4_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_proformaitem_mongo_id_a277dae4_like ON public.finanzas_proformaitem USING btree (mongo_id varchar_pattern_ops);


--
-- Name: finanzas_proformaitem_proforma_id_6924e482; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_proformaitem_proforma_id_6924e482 ON public.finanzas_proformaitem USING btree (proforma_id);


--
-- Name: finanzas_proformaitem_servicio_id_e2e338bd; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX finanzas_proformaitem_servicio_id_e2e338bd ON public.finanzas_proformaitem USING btree (servicio_id);


--
-- Name: gestion_alerta_abierta_unica; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX gestion_alerta_abierta_unica ON public.gestion_alerta USING btree (regla_id, COALESCE(expediente_id, oferta_id, solicitud_id)) WHERE ((estado)::text <> ALL ((ARRAY['atendida'::character varying, 'resuelta_sola'::character varying])::text[]));


--
-- Name: gestion_alerta_abiertas_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_alerta_abiertas_idx ON public.gestion_alerta USING btree (estado, severidad) WHERE ((estado)::text <> ALL ((ARRAY['atendida'::character varying, 'resuelta_sola'::character varying])::text[]));


--
-- Name: gestion_cambio_expediente_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_cambio_expediente_idx ON public.gestion_cambio USING btree (expediente_id, cambiado_en);


--
-- Name: gestion_ensayo_envio_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_ensayo_envio_idx ON public.gestion_ensayo USING btree (envio_id);


--
-- Name: gestion_ensayo_expediente_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_ensayo_expediente_idx ON public.gestion_ensayo USING btree (expediente_id);


--
-- Name: gestion_entregable_lote_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_entregable_lote_idx ON public.gestion_entregable USING btree (lote_id);


--
-- Name: gestion_envioexterno_expediente_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_envioexterno_expediente_idx ON public.gestion_envioexterno USING btree (expediente_id);


--
-- Name: gestion_eventoetapa_abierta_unica; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX gestion_eventoetapa_abierta_unica ON public.gestion_eventoetapa USING btree (expediente_id, etapa) WHERE (cerrada_en IS NULL);


--
-- Name: gestion_eventoetapa_expediente_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_eventoetapa_expediente_idx ON public.gestion_eventoetapa USING btree (expediente_id);


--
-- Name: gestion_expediente_activos_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_expediente_activos_idx ON public.gestion_expediente USING btree (etapa, fecha_limite_cliente) WHERE ((etapa)::text <> ALL ((ARRAY['entregado'::character varying, 'cancelado'::character varying])::text[]));


--
-- Name: gestion_expediente_oferta_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_expediente_oferta_idx ON public.gestion_expediente USING btree (oferta_id);


--
-- Name: gestion_expediente_proyecto_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_expediente_proyecto_idx ON public.gestion_expediente USING btree (proyecto_id);


--
-- Name: gestion_oferta_aceptadas_mes_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_oferta_aceptadas_mes_idx ON public.gestion_oferta USING btree (aceptada_en) WHERE ((estado)::text = ANY ((ARRAY['aceptada'::character varying, 'aceptada_parcial'::character varying])::text[]));


--
-- Name: gestion_oferta_cliente_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_oferta_cliente_idx ON public.gestion_oferta USING btree (cliente_id);


--
-- Name: gestion_oferta_proforma_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_oferta_proforma_idx ON public.gestion_oferta USING btree (proforma_id);


--
-- Name: gestion_oferta_proyecto_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_oferta_proyecto_idx ON public.gestion_oferta USING btree (proyecto_id);


--
-- Name: gestion_oferta_solicitud_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_oferta_solicitud_idx ON public.gestion_oferta USING btree (solicitud_id);


--
-- Name: gestion_ofertaitem_lote_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_ofertaitem_lote_idx ON public.gestion_ofertaitem USING btree (lote_id);


--
-- Name: gestion_ofertaitem_servicio_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_ofertaitem_servicio_idx ON public.gestion_ofertaitem USING btree (servicio_id);


--
-- Name: gestion_programacion_expediente_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_programacion_expediente_idx ON public.gestion_programacion USING btree (expediente_id);


--
-- Name: gestion_programacion_fecha_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_programacion_fecha_idx ON public.gestion_programacion USING btree (fecha, cuadrilla_id);


--
-- Name: gestion_punto_programacion_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_punto_programacion_idx ON public.gestion_punto USING btree (programacion_id);


--
-- Name: gestion_recepcion_expediente_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_recepcion_expediente_idx ON public.gestion_recepcion USING btree (expediente_id);


--
-- Name: gestion_recepcion_por_verificar_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_recepcion_por_verificar_idx ON public.gestion_recepcion USING btree (entregada_en) WHERE ((estado)::text = 'por_verificar'::text);


--
-- Name: gestion_recepcionpunto_punto_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_recepcionpunto_punto_idx ON public.gestion_recepcionpunto USING btree (punto_id);


--
-- Name: gestion_solicitud_cliente_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_solicitud_cliente_idx ON public.gestion_solicitud USING btree (cliente_id);


--
-- Name: gestion_solicitud_estado_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gestion_solicitud_estado_idx ON public.gestion_solicitud USING btree (estado, recibida_en);


--
-- Name: lectura_campoleido_hoja_id_191f0d20; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_campoleido_hoja_id_191f0d20 ON public.lectura_campoleido USING btree (hoja_id);


--
-- Name: lectura_campoleido_mongo_id_b687db3e_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_campoleido_mongo_id_b687db3e_like ON public.lectura_campoleido USING btree (mongo_id varchar_pattern_ops);


--
-- Name: lectura_campoleido_revisado_por_id_bb38d9f7; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_campoleido_revisado_por_id_bb38d9f7 ON public.lectura_campoleido USING btree (revisado_por_id);


--
-- Name: lectura_confusioncaracter_escritor_id_5f2ad505; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_confusioncaracter_escritor_id_5f2ad505 ON public.lectura_confusioncaracter USING btree (escritor_id);


--
-- Name: lectura_confusioncaracter_mongo_id_387adbcb_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_confusioncaracter_mongo_id_387adbcb_like ON public.lectura_confusioncaracter USING btree (mongo_id varchar_pattern_ops);


--
-- Name: lectura_hoj_estado_001f34_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_hoj_estado_001f34_idx ON public.lectura_hojaescaneada USING btree (estado, tipo);


--
-- Name: lectura_hojaescaneada_imagen_sha256_d96a5460_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_hojaescaneada_imagen_sha256_d96a5460_like ON public.lectura_hojaescaneada USING btree (imagen_sha256 varchar_pattern_ops);


--
-- Name: lectura_hojaescaneada_llenada_por_id_263d0a68; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_hojaescaneada_llenada_por_id_263d0a68 ON public.lectura_hojaescaneada USING btree (llenada_por_id);


--
-- Name: lectura_hojaescaneada_mongo_id_ab241602_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_hojaescaneada_mongo_id_ab241602_like ON public.lectura_hojaescaneada USING btree (mongo_id varchar_pattern_ops);


--
-- Name: lectura_hojaescaneada_proyecto_id_f7544561; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_hojaescaneada_proyecto_id_f7544561 ON public.lectura_hojaescaneada USING btree (proyecto_id);


--
-- Name: lectura_hojaescaneada_revisada_por_id_cf2d334a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_hojaescaneada_revisada_por_id_cf2d334a ON public.lectura_hojaescaneada USING btree (revisada_por_id);


--
-- Name: lectura_hojaescaneada_subida_por_id_8cb4ca5c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_hojaescaneada_subida_por_id_8cb4ca5c ON public.lectura_hojaescaneada USING btree (subida_por_id);


--
-- Name: lectura_sinonimo_mongo_id_e548b74f_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lectura_sinonimo_mongo_id_e548b74f_like ON public.lectura_sinonimo USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_avanceproyecto_mongo_id_a80f1af4_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_avanceproyecto_mongo_id_a80f1af4_like ON public.nucleo_avanceproyecto USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_avanceproyecto_proyecto_id_9631e916; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_avanceproyecto_proyecto_id_9631e916 ON public.nucleo_avanceproyecto USING btree (proyecto_id);


--
-- Name: nucleo_avanceproyecto_subido_por_id_41c6e00f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_avanceproyecto_subido_por_id_41c6e00f ON public.nucleo_avanceproyecto USING btree (subido_por_id);


--
-- Name: nucleo_cliente_dui_208c2bbe_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_cliente_dui_208c2bbe_like ON public.nucleo_cliente USING btree (dui varchar_pattern_ops);


--
-- Name: nucleo_cliente_mongo_id_ea89f9c9_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_cliente_mongo_id_ea89f9c9_like ON public.nucleo_cliente USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_cliente_nit_0667169a_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_cliente_nit_0667169a_like ON public.nucleo_cliente USING btree (nit varchar_pattern_ops);


--
-- Name: nucleo_cliente_ruc_e400721a_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_cliente_ruc_e400721a_like ON public.nucleo_cliente USING btree (ruc varchar_pattern_ops);


--
-- Name: nucleo_contactocliente_cliente_id_cf457ab9; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_contactocliente_cliente_id_cf457ab9 ON public.nucleo_contactocliente USING btree (cliente_id);


--
-- Name: nucleo_departamento_mongo_id_f2ef7fa4_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_departamento_mongo_id_f2ef7fa4_like ON public.nucleo_departamento USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_empleado_codigo_18965b42_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_empleado_codigo_18965b42_like ON public.nucleo_empleado USING btree (codigo varchar_pattern_ops);


--
-- Name: nucleo_empleado_departamento_id_5cb20d55; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_empleado_departamento_id_5cb20d55 ON public.nucleo_empleado USING btree (departamento_id);


--
-- Name: nucleo_empleado_mongo_id_c392bc30_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_empleado_mongo_id_c392bc30_like ON public.nucleo_empleado USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_proyecto_cliente_id_6e4181fd; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_proyecto_cliente_id_6e4181fd ON public.nucleo_proyecto USING btree (cliente_id);


--
-- Name: nucleo_proyecto_mongo_id_77952397_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_proyecto_mongo_id_77952397_like ON public.nucleo_proyecto USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_proyectotecnico_empleado_id_c9db7e2f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_proyectotecnico_empleado_id_c9db7e2f ON public.nucleo_proyectotecnico USING btree (empleado_id);


--
-- Name: nucleo_proyectotecnico_mongo_id_436c76fc_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_proyectotecnico_mongo_id_436c76fc_like ON public.nucleo_proyectotecnico USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_proyectotecnico_proyecto_id_fc1939c0; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_proyectotecnico_proyecto_id_fc1939c0 ON public.nucleo_proyectotecnico USING btree (proyecto_id);


--
-- Name: nucleo_reportesemanal_mongo_id_f005d20f_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_reportesemanal_mongo_id_f005d20f_like ON public.nucleo_reportesemanal USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_reportesemanal_proyecto_id_a16390ee; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_reportesemanal_proyecto_id_a16390ee ON public.nucleo_reportesemanal USING btree (proyecto_id);


--
-- Name: nucleo_reportesemanal_reportado_por_id_43a4c7bb; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_reportesemanal_reportado_por_id_43a4c7bb ON public.nucleo_reportesemanal USING btree (reportado_por_id);


--
-- Name: nucleo_roldepartamento_codigo_0ec578ff; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_roldepartamento_codigo_0ec578ff ON public.nucleo_roldepartamento USING btree (codigo);


--
-- Name: nucleo_roldepartamento_codigo_0ec578ff_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_roldepartamento_codigo_0ec578ff_like ON public.nucleo_roldepartamento USING btree (codigo varchar_pattern_ops);


--
-- Name: nucleo_roldepartamento_departamento_id_f7d65418; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_roldepartamento_departamento_id_f7d65418 ON public.nucleo_roldepartamento USING btree (departamento_id);


--
-- Name: nucleo_roldepartamento_mongo_id_1c1f76cf_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_roldepartamento_mongo_id_1c1f76cf_like ON public.nucleo_roldepartamento USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_servicio_mongo_id_74c18fd3_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_servicio_mongo_id_74c18fd3_like ON public.nucleo_servicio USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_usuario_email_d92e9ae0_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_usuario_email_d92e9ae0_like ON public.nucleo_usuario USING btree (email varchar_pattern_ops);


--
-- Name: nucleo_usuario_groups_group_id_d1f4531a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_usuario_groups_group_id_d1f4531a ON public.nucleo_usuario_groups USING btree (group_id);


--
-- Name: nucleo_usuario_groups_usuario_id_bad2d48b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_usuario_groups_usuario_id_bad2d48b ON public.nucleo_usuario_groups USING btree (usuario_id);


--
-- Name: nucleo_usuario_mongo_id_6ff0f1ed_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_usuario_mongo_id_6ff0f1ed_like ON public.nucleo_usuario USING btree (mongo_id varchar_pattern_ops);


--
-- Name: nucleo_usuario_user_permissions_permission_id_c8cd6ed4; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_usuario_user_permissions_permission_id_c8cd6ed4 ON public.nucleo_usuario_user_permissions USING btree (permission_id);


--
-- Name: nucleo_usuario_user_permissions_usuario_id_1de9b0a6; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX nucleo_usuario_user_permissions_usuario_id_1de9b0a6 ON public.nucleo_usuario_user_permissions USING btree (usuario_id);


--
-- Name: rrhh_boleta_linea_planilla_id_38d7d81c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_boleta_linea_planilla_id_38d7d81c ON public.rrhh_boleta USING btree (linea_planilla_id);


--
-- Name: rrhh_boleta_mongo_id_10db816a_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_boleta_mongo_id_10db816a_like ON public.rrhh_boleta USING btree (mongo_id varchar_pattern_ops);


--
-- Name: rrhh_comprobante_anticipos_pendientes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_comprobante_anticipos_pendientes ON public.rrhh_comprobante USING btree (empleado_id, periodo_hasta) WHERE (((tipo)::text = 'anticipo'::text) AND (linea_planilla_id IS NULL));


--
-- Name: rrhh_comprobante_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_comprobante_empleado ON public.rrhh_comprobante USING btree (empleado_id, fecha_emision);


--
-- Name: rrhh_comprobante_linea; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_comprobante_linea ON public.rrhh_comprobante USING btree (linea_planilla_id);


--
-- Name: rrhh_contrato_empleado_id_31061206; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_contrato_empleado_id_31061206 ON public.rrhh_contrato USING btree (empleado_id);


--
-- Name: rrhh_contrato_mongo_id_c06e71d5_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_contrato_mongo_id_c06e71d5_like ON public.rrhh_contrato USING btree (mongo_id varchar_pattern_ops);


--
-- Name: rrhh_horaextra_empleado_id_33aade42; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_horaextra_empleado_id_33aade42 ON public.rrhh_horaextra USING btree (empleado_id);


--
-- Name: rrhh_horaextra_mongo_id_35168fed_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_horaextra_mongo_id_35168fed_like ON public.rrhh_horaextra USING btree (mongo_id varchar_pattern_ops);


--
-- Name: rrhh_horaextra_proyecto_id_b7454619; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_horaextra_proyecto_id_b7454619 ON public.rrhh_horaextra USING btree (proyecto_id);


--
-- Name: rrhh_horaextradia_proyecto; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_horaextradia_proyecto ON public.rrhh_horaextradia USING btree (proyecto_id);


--
-- Name: rrhh_horaextradia_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_horaextradia_registro ON public.rrhh_horaextradia USING btree (registro_id, fecha);


--
-- Name: rrhh_lineaplanilla_empleado_id_fcb519ac; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_lineaplanilla_empleado_id_fcb519ac ON public.rrhh_lineaplanilla USING btree (empleado_id);


--
-- Name: rrhh_lineaplanilla_mongo_id_7703cc3b_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_lineaplanilla_mongo_id_7703cc3b_like ON public.rrhh_lineaplanilla USING btree (mongo_id varchar_pattern_ops);


--
-- Name: rrhh_lineaplanilla_planilla_id_ff042010; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_lineaplanilla_planilla_id_ff042010 ON public.rrhh_lineaplanilla USING btree (planilla_id);


--
-- Name: rrhh_lineaplanilla_prestamo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_lineaplanilla_prestamo ON public.rrhh_lineaplanilla USING btree (prestamo_id);


--
-- Name: rrhh_planilla_departamento_id_10b7df02; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_planilla_departamento_id_10b7df02 ON public.rrhh_planilla USING btree (departamento_id);


--
-- Name: rrhh_planilla_generada_por_id_19fbdf5a; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_planilla_generada_por_id_19fbdf5a ON public.rrhh_planilla USING btree (generada_por_id);


--
-- Name: rrhh_planilla_mongo_id_1edab739_like; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_planilla_mongo_id_1edab739_like ON public.rrhh_planilla USING btree (mongo_id varchar_pattern_ops);


--
-- Name: rrhh_prestamo_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_prestamo_empleado ON public.rrhh_prestamo USING btree (empleado_id, estado);


--
-- Name: rrhh_registrohoraextra_pendientes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_registrohoraextra_pendientes ON public.rrhh_registrohoraextra USING btree (periodo_fin) WHERE (linea_planilla_id IS NULL);


--
-- Name: rrhh_registrohoraextra_periodo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rrhh_registrohoraextra_periodo ON public.rrhh_registrohoraextra USING btree (periodo_fin);


--
-- Name: usuario_email_unico; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX usuario_email_unico ON public.nucleo_usuario USING btree (lower((email)::text));


--
-- Name: rrhh_v_saldo_prestamo _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.rrhh_v_saldo_prestamo WITH (security_invoker='true') AS
 SELECT p.id AS prestamo_id,
    p.empleado_id,
    p.monto,
    p.numero_cuotas,
    p.estado,
    count(l.id) AS cuotas_descontadas,
    COALESCE(sum(l.prestamo), (0)::numeric) AS pagado,
    (p.monto - COALESCE(sum(l.prestamo), (0)::numeric)) AS saldo
   FROM (public.rrhh_prestamo p
     LEFT JOIN public.rrhh_lineaplanilla l ON ((l.prestamo_id = p.id)))
  GROUP BY p.id;


--
-- Name: ensayos trg_auditoria; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_auditoria AFTER INSERT OR DELETE OR UPDATE ON lab.ensayos FOR EACH ROW EXECUTE FUNCTION lab.fn_auditar();


--
-- Name: especimenes trg_auditoria; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_auditoria AFTER INSERT OR DELETE OR UPDATE ON lab.especimenes FOR EACH ROW EXECUTE FUNCTION lab.fn_auditar();


--
-- Name: informes trg_auditoria; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_auditoria AFTER INSERT OR DELETE OR UPDATE ON lab.informes FOR EACH ROW EXECUTE FUNCTION lab.fn_auditar();


--
-- Name: mediciones trg_auditoria; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_auditoria AFTER INSERT OR DELETE OR UPDATE ON lab.mediciones FOR EACH ROW EXECUTE FUNCTION lab.fn_auditar();


--
-- Name: muestras trg_auditoria; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_auditoria AFTER INSERT OR DELETE OR UPDATE ON lab.muestras FOR EACH ROW EXECUTE FUNCTION lab.fn_auditar();


--
-- Name: remisiones trg_auditoria; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_auditoria AFTER INSERT OR DELETE OR UPDATE ON lab.remisiones FOR EACH ROW EXECUTE FUNCTION lab.fn_auditar();


--
-- Name: resultados_compresion trg_auditoria; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_auditoria AFTER INSERT OR DELETE OR UPDATE ON lab.resultados_compresion FOR EACH ROW EXECUTE FUNCTION lab.fn_auditar('ensayo_id');


--
-- Name: usuarios_roles trg_auditoria; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_auditoria AFTER INSERT OR DELETE OR UPDATE ON lab.usuarios_roles FOR EACH ROW EXECUTE FUNCTION lab.fn_auditar('empleado_id');


--
-- Name: resultados_compresion trg_compresion_defaults; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_compresion_defaults BEFORE INSERT OR UPDATE ON lab.resultados_compresion FOR EACH ROW EXECUTE FUNCTION lab.fn_compresion_defaults();


--
-- Name: ensayos trg_ensayo_especimen; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_ensayo_especimen AFTER INSERT OR UPDATE OF estado ON lab.ensayos FOR EACH ROW EXECUTE FUNCTION lab.fn_ensayo_actualiza_especimen();


--
-- Name: ensayos trg_ensayo_reglas; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_ensayo_reglas BEFORE INSERT OR UPDATE ON lab.ensayos FOR EACH ROW EXECUTE FUNCTION lab.fn_ensayo_reglas();


--
-- Name: especimenes trg_especimen_defaults; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_especimen_defaults BEFORE INSERT ON lab.especimenes FOR EACH ROW EXECUTE FUNCTION lab.fn_especimen_defaults();


--
-- Name: especimenes trg_especimen_movimiento; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_especimen_movimiento AFTER INSERT OR UPDATE OF ubicacion_id ON lab.especimenes FOR EACH ROW EXECUTE FUNCTION lab.fn_registrar_movimiento();


--
-- Name: mediciones trg_proteger; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_proteger BEFORE INSERT OR DELETE OR UPDATE ON lab.mediciones FOR EACH ROW EXECUTE FUNCTION lab.fn_proteger_aprobado();


--
-- Name: resultados_compresion trg_proteger; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_proteger BEFORE INSERT OR DELETE OR UPDATE ON lab.resultados_compresion FOR EACH ROW EXECUTE FUNCTION lab.fn_proteger_aprobado();


--
-- Name: ensayos trg_touch; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_touch BEFORE UPDATE ON lab.ensayos FOR EACH ROW EXECUTE FUNCTION lab.fn_tocar_actualizado();


--
-- Name: especimenes trg_touch; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_touch BEFORE UPDATE ON lab.especimenes FOR EACH ROW EXECUTE FUNCTION lab.fn_tocar_actualizado();


--
-- Name: informes trg_touch; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_touch BEFORE UPDATE ON lab.informes FOR EACH ROW EXECUTE FUNCTION lab.fn_tocar_actualizado();


--
-- Name: muestras trg_touch; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_touch BEFORE UPDATE ON lab.muestras FOR EACH ROW EXECUTE FUNCTION lab.fn_tocar_actualizado();


--
-- Name: remisiones trg_touch; Type: TRIGGER; Schema: lab; Owner: -
--

CREATE TRIGGER trg_touch BEFORE UPDATE ON lab.remisiones FOR EACH ROW EXECUTE FUNCTION lab.fn_tocar_actualizado();


--
-- Name: rrhh_horaextradia trg_horaextradia_en_periodo; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_horaextradia_en_periodo BEFORE INSERT OR UPDATE OF fecha, registro_id ON public.rrhh_horaextradia FOR EACH ROW EXECUTE FUNCTION public.rrhh_fn_horaextradia_en_periodo();


--
-- Name: adjuntos adjuntos_subido_por_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.adjuntos
    ADD CONSTRAINT adjuntos_subido_por_fkey FOREIGN KEY (subido_por) REFERENCES public.nucleo_empleado(id);


--
-- Name: calibraciones calibraciones_equipo_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.calibraciones
    ADD CONSTRAINT calibraciones_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES lab.equipos(id) ON DELETE CASCADE;


--
-- Name: categorias_material categorias_material_area_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.categorias_material
    ADD CONSTRAINT categorias_material_area_id_fkey FOREIGN KEY (area_id) REFERENCES lab.areas(id);


--
-- Name: ensayos ensayos_aprobado_por_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ensayos
    ADD CONSTRAINT ensayos_aprobado_por_fkey FOREIGN KEY (aprobado_por) REFERENCES public.nucleo_empleado(id);


--
-- Name: ensayos ensayos_equipo_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ensayos
    ADD CONSTRAINT ensayos_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES lab.equipos(id);


--
-- Name: ensayos ensayos_especimen_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ensayos
    ADD CONSTRAINT ensayos_especimen_id_fkey FOREIGN KEY (especimen_id) REFERENCES lab.especimenes(id);


--
-- Name: ensayos ensayos_importacion_fila_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ensayos
    ADD CONSTRAINT ensayos_importacion_fila_id_fkey FOREIGN KEY (importacion_fila_id) REFERENCES lab.importacion_filas(id);


--
-- Name: ensayos ensayos_metodo_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ensayos
    ADD CONSTRAINT ensayos_metodo_id_fkey FOREIGN KEY (metodo_id) REFERENCES lab.metodos_ensayo(id);


--
-- Name: ensayos ensayos_revisado_por_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ensayos
    ADD CONSTRAINT ensayos_revisado_por_fkey FOREIGN KEY (revisado_por) REFERENCES public.nucleo_empleado(id);


--
-- Name: ensayos ensayos_tecnico_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ensayos
    ADD CONSTRAINT ensayos_tecnico_id_fkey FOREIGN KEY (tecnico_id) REFERENCES public.nucleo_empleado(id);


--
-- Name: especimenes especimenes_muestra_id_proyecto_id_tipo_especimen_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.especimenes
    ADD CONSTRAINT especimenes_muestra_id_proyecto_id_tipo_especimen_id_fkey FOREIGN KEY (muestra_id, proyecto_id, tipo_especimen_id) REFERENCES lab.muestras(id, proyecto_id, tipo_especimen_id);


--
-- Name: especimenes especimenes_ubicacion_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.especimenes
    ADD CONSTRAINT especimenes_ubicacion_id_fkey FOREIGN KEY (ubicacion_id) REFERENCES lab.ubicaciones(id);


--
-- Name: importacion_filas importacion_filas_especimen_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.importacion_filas
    ADD CONSTRAINT importacion_filas_especimen_id_fkey FOREIGN KEY (especimen_id) REFERENCES lab.especimenes(id);


--
-- Name: importacion_filas importacion_filas_importacion_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.importacion_filas
    ADD CONSTRAINT importacion_filas_importacion_id_fkey FOREIGN KEY (importacion_id) REFERENCES lab.importaciones(id) ON DELETE CASCADE;


--
-- Name: importaciones importaciones_equipo_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.importaciones
    ADD CONSTRAINT importaciones_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES lab.equipos(id);


--
-- Name: importaciones importaciones_importado_por_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.importaciones
    ADD CONSTRAINT importaciones_importado_por_fkey FOREIGN KEY (importado_por) REFERENCES public.nucleo_empleado(id);


--
-- Name: informe_ensayos informe_ensayos_ensayo_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.informe_ensayos
    ADD CONSTRAINT informe_ensayos_ensayo_id_fkey FOREIGN KEY (ensayo_id) REFERENCES lab.ensayos(id);


--
-- Name: informe_ensayos informe_ensayos_informe_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.informe_ensayos
    ADD CONSTRAINT informe_ensayos_informe_id_fkey FOREIGN KEY (informe_id) REFERENCES lab.informes(id) ON DELETE CASCADE;


--
-- Name: informes informes_aprobado_por_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.informes
    ADD CONSTRAINT informes_aprobado_por_fkey FOREIGN KEY (aprobado_por) REFERENCES public.nucleo_empleado(id);


--
-- Name: informes informes_elaborado_por_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.informes
    ADD CONSTRAINT informes_elaborado_por_fkey FOREIGN KEY (elaborado_por) REFERENCES public.nucleo_empleado(id);


--
-- Name: informes informes_proyecto_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.informes
    ADD CONSTRAINT informes_proyecto_id_fkey FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id);


--
-- Name: mediciones mediciones_ensayo_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.mediciones
    ADD CONSTRAINT mediciones_ensayo_id_fkey FOREIGN KEY (ensayo_id) REFERENCES lab.ensayos(id) ON DELETE CASCADE;


--
-- Name: mediciones mediciones_parametro_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.mediciones
    ADD CONSTRAINT mediciones_parametro_id_fkey FOREIGN KEY (parametro_id) REFERENCES lab.parametros_metodo(id);


--
-- Name: metodo_tipos_especimen metodo_tipos_especimen_metodo_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.metodo_tipos_especimen
    ADD CONSTRAINT metodo_tipos_especimen_metodo_id_fkey FOREIGN KEY (metodo_id) REFERENCES lab.metodos_ensayo(id) ON DELETE CASCADE;


--
-- Name: metodo_tipos_especimen metodo_tipos_especimen_tipo_especimen_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.metodo_tipos_especimen
    ADD CONSTRAINT metodo_tipos_especimen_tipo_especimen_id_fkey FOREIGN KEY (tipo_especimen_id) REFERENCES lab.tipos_especimen(id) ON DELETE CASCADE;


--
-- Name: metodos_ensayo metodos_ensayo_area_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.metodos_ensayo
    ADD CONSTRAINT metodos_ensayo_area_id_fkey FOREIGN KEY (area_id) REFERENCES lab.areas(id);


--
-- Name: metodos_ensayo metodos_ensayo_norma_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.metodos_ensayo
    ADD CONSTRAINT metodos_ensayo_norma_id_fkey FOREIGN KEY (norma_id) REFERENCES lab.normas(id);


--
-- Name: movimientos_especimen movimientos_especimen_especimen_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.movimientos_especimen
    ADD CONSTRAINT movimientos_especimen_especimen_id_fkey FOREIGN KEY (especimen_id) REFERENCES lab.especimenes(id) ON DELETE CASCADE;


--
-- Name: movimientos_especimen movimientos_especimen_movido_por_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.movimientos_especimen
    ADD CONSTRAINT movimientos_especimen_movido_por_fkey FOREIGN KEY (movido_por) REFERENCES public.nucleo_empleado(id);


--
-- Name: movimientos_especimen movimientos_especimen_ubicacion_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.movimientos_especimen
    ADD CONSTRAINT movimientos_especimen_ubicacion_id_fkey FOREIGN KEY (ubicacion_id) REFERENCES lab.ubicaciones(id);


--
-- Name: muestras muestras_proveedor_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.muestras
    ADD CONSTRAINT muestras_proveedor_id_fkey FOREIGN KEY (proveedor_id) REFERENCES lab.proveedores_material(id);


--
-- Name: muestras muestras_remision_id_proyecto_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.muestras
    ADD CONSTRAINT muestras_remision_id_proyecto_id_fkey FOREIGN KEY (remision_id, proyecto_id) REFERENCES lab.remisiones(id, proyecto_id);


--
-- Name: muestras muestras_tipo_especimen_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.muestras
    ADD CONSTRAINT muestras_tipo_especimen_id_fkey FOREIGN KEY (tipo_especimen_id) REFERENCES lab.tipos_especimen(id);


--
-- Name: parametros_metodo parametros_metodo_metodo_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.parametros_metodo
    ADD CONSTRAINT parametros_metodo_metodo_id_fkey FOREIGN KEY (metodo_id) REFERENCES lab.metodos_ensayo(id) ON DELETE CASCADE;


--
-- Name: remisiones remisiones_creado_por_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.remisiones
    ADD CONSTRAINT remisiones_creado_por_fkey FOREIGN KEY (creado_por) REFERENCES public.nucleo_empleado(id);


--
-- Name: remisiones remisiones_entregado_por_empleado_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.remisiones
    ADD CONSTRAINT remisiones_entregado_por_empleado_fkey FOREIGN KEY (entregado_por_empleado) REFERENCES public.nucleo_empleado(id);


--
-- Name: remisiones remisiones_proyecto_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.remisiones
    ADD CONSTRAINT remisiones_proyecto_id_fkey FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id);


--
-- Name: remisiones remisiones_recibido_lab_por_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.remisiones
    ADD CONSTRAINT remisiones_recibido_lab_por_fkey FOREIGN KEY (recibido_lab_por) REFERENCES public.nucleo_empleado(id);


--
-- Name: resultados_compresion resultados_compresion_ensayo_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.resultados_compresion
    ADD CONSTRAINT resultados_compresion_ensayo_id_fkey FOREIGN KEY (ensayo_id) REFERENCES lab.ensayos(id) ON DELETE CASCADE;


--
-- Name: resultados_compresion resultados_compresion_tipo_falla_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.resultados_compresion
    ADD CONSTRAINT resultados_compresion_tipo_falla_fkey FOREIGN KEY (tipo_falla) REFERENCES lab.tipos_falla(codigo);


--
-- Name: tipos_especimen tipos_especimen_categoria_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.tipos_especimen
    ADD CONSTRAINT tipos_especimen_categoria_id_fkey FOREIGN KEY (categoria_id) REFERENCES lab.categorias_material(id);


--
-- Name: ubicaciones ubicaciones_padre_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.ubicaciones
    ADD CONSTRAINT ubicaciones_padre_id_fkey FOREIGN KEY (padre_id) REFERENCES lab.ubicaciones(id);


--
-- Name: usuarios_roles usuarios_roles_asignado_por_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.usuarios_roles
    ADD CONSTRAINT usuarios_roles_asignado_por_fkey FOREIGN KEY (asignado_por) REFERENCES public.nucleo_empleado(id);


--
-- Name: usuarios_roles usuarios_roles_empleado_id_fkey; Type: FK CONSTRAINT; Schema: lab; Owner: -
--

ALTER TABLE ONLY lab.usuarios_roles
    ADD CONSTRAINT usuarios_roles_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.nucleo_empleado(id) ON DELETE CASCADE;


--
-- Name: gestion_alerta alerta_atendida_por_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_alerta
    ADD CONSTRAINT alerta_atendida_por_fk FOREIGN KEY (atendida_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_alerta alerta_expediente_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_alerta
    ADD CONSTRAINT alerta_expediente_fk FOREIGN KEY (expediente_id) REFERENCES public.gestion_expediente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_alerta alerta_oferta_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_alerta
    ADD CONSTRAINT alerta_oferta_fk FOREIGN KEY (oferta_id) REFERENCES public.gestion_oferta(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_alerta alerta_regla_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_alerta
    ADD CONSTRAINT alerta_regla_fk FOREIGN KEY (regla_id) REFERENCES public.gestion_reglaalerta(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_alerta alerta_solicitud_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_alerta
    ADD CONSTRAINT alerta_solicitud_fk FOREIGN KEY (solicitud_id) REFERENCES public.gestion_solicitud(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_group_permissions auth_group_permissio_permission_id_84c5c92e_fk_auth_perm; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissio_permission_id_84c5c92e_fk_auth_perm FOREIGN KEY (permission_id) REFERENCES public.auth_permission(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_group_permissions auth_group_permissions_group_id_b120cbf9_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_group_id_b120cbf9_fk_auth_group_id FOREIGN KEY (group_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_permission auth_permission_content_type_id_2f476e4b_fk_django_co; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_2f476e4b_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_cambio cambio_expediente_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_cambio
    ADD CONSTRAINT cambio_expediente_fk FOREIGN KEY (expediente_id) REFERENCES public.gestion_expediente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_cambio cambio_usuario_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_cambio
    ADD CONSTRAINT cambio_usuario_fk FOREIGN KEY (usuario_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_comprobante comprobante_empleado_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_comprobante
    ADD CONSTRAINT comprobante_empleado_fk FOREIGN KEY (empleado_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_comprobante comprobante_linea_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_comprobante
    ADD CONSTRAINT comprobante_linea_fk FOREIGN KEY (linea_planilla_id) REFERENCES public.rrhh_lineaplanilla(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_comprobante comprobante_usuario_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_comprobante
    ADD CONSTRAINT comprobante_usuario_fk FOREIGN KEY (emitido_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_cuadrilla cuadrilla_jefe_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_cuadrilla
    ADD CONSTRAINT cuadrilla_jefe_fk FOREIGN KEY (jefe_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_cuadrilla_miembros cuadrilla_miembros_cuadrilla_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_cuadrilla_miembros
    ADD CONSTRAINT cuadrilla_miembros_cuadrilla_fk FOREIGN KEY (cuadrilla_id) REFERENCES public.gestion_cuadrilla(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_cuadrilla_miembros cuadrilla_miembros_empleado_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_cuadrilla_miembros
    ADD CONSTRAINT cuadrilla_miembros_empleado_fk FOREIGN KEY (empleado_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: django_admin_log django_admin_log_content_type_id_c4bce8eb_fk_django_co; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_content_type_id_c4bce8eb_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: django_admin_log django_admin_log_user_id_c564eba6_fk_nucleo_usuario_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_user_id_c564eba6_fk_nucleo_usuario_id FOREIGN KEY (user_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_ensayo ensayo_envio_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ensayo
    ADD CONSTRAINT ensayo_envio_fk FOREIGN KEY (envio_id) REFERENCES public.gestion_envioexterno(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_ensayo ensayo_expediente_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ensayo
    ADD CONSTRAINT ensayo_expediente_fk FOREIGN KEY (expediente_id) REFERENCES public.gestion_expediente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_ensayo ensayo_punto_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ensayo
    ADD CONSTRAINT ensayo_punto_fk FOREIGN KEY (punto_id) REFERENCES public.gestion_punto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_ensayo ensayo_servicio_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ensayo
    ADD CONSTRAINT ensayo_servicio_fk FOREIGN KEY (servicio_id) REFERENCES public.nucleo_servicio(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_entregable entregable_lote_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_entregable
    ADD CONSTRAINT entregable_lote_fk FOREIGN KEY (lote_id) REFERENCES public.gestion_ofertalote(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_envioexterno envioexterno_expediente_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_envioexterno
    ADD CONSTRAINT envioexterno_expediente_fk FOREIGN KEY (expediente_id) REFERENCES public.gestion_expediente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_envioexterno envioexterno_laboratorio_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_envioexterno
    ADD CONSTRAINT envioexterno_laboratorio_fk FOREIGN KEY (laboratorio_id) REFERENCES public.gestion_laboratorioexterno(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_eventoetapa eventoetapa_etapa_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_eventoetapa
    ADD CONSTRAINT eventoetapa_etapa_fk FOREIGN KEY (etapa) REFERENCES public.gestion_etapaconfig(etapa) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_eventoetapa eventoetapa_expediente_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_eventoetapa
    ADD CONSTRAINT eventoetapa_expediente_fk FOREIGN KEY (expediente_id) REFERENCES public.gestion_expediente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_eventoetapa eventoetapa_registrado_por_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_eventoetapa
    ADD CONSTRAINT eventoetapa_registrado_por_fk FOREIGN KEY (registrado_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_expediente expediente_anticipo_cxc_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_expediente
    ADD CONSTRAINT expediente_anticipo_cxc_fk FOREIGN KEY (anticipo_cxc_id) REFERENCES public.finanzas_cuentaporcobrar(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_expediente expediente_lote_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_expediente
    ADD CONSTRAINT expediente_lote_fk FOREIGN KEY (lote_id) REFERENCES public.gestion_ofertalote(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_expediente expediente_oferta_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_expediente
    ADD CONSTRAINT expediente_oferta_fk FOREIGN KEY (oferta_id) REFERENCES public.gestion_oferta(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_expediente expediente_proyecto_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_expediente
    ADD CONSTRAINT expediente_proyecto_fk FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_expediente expediente_responsable_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_expediente
    ADD CONSTRAINT expediente_responsable_fk FOREIGN KEY (responsable_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_expediente expediente_saldo_cxc_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_expediente
    ADD CONSTRAINT expediente_saldo_cxc_fk FOREIGN KEY (saldo_cxc_id) REFERENCES public.finanzas_cuentaporcobrar(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_expediente expediente_sin_anticipo_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_expediente
    ADD CONSTRAINT expediente_sin_anticipo_fk FOREIGN KEY (sin_anticipo_autorizado_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_expediente expediente_sin_saldo_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_expediente
    ADD CONSTRAINT expediente_sin_saldo_fk FOREIGN KEY (entrega_sin_saldo_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: finanzas_cuentaporcobraritem finanzas_cuentaporco_cuenta_id_564c83cf_fk_finanzas_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_cuentaporcobraritem
    ADD CONSTRAINT finanzas_cuentaporco_cuenta_id_564c83cf_fk_finanzas_ FOREIGN KEY (cuenta_id) REFERENCES public.finanzas_cuentaporcobrar(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: finanzas_cuentaporcobrar finanzas_cuentaporco_proforma_id_ba4e8984_fk_finanzas_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_cuentaporcobrar
    ADD CONSTRAINT finanzas_cuentaporco_proforma_id_ba4e8984_fk_finanzas_ FOREIGN KEY (proforma_id) REFERENCES public.finanzas_proforma(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: finanzas_cuentaporcobraritem finanzas_cuentaporco_servicio_id_f37074ad_fk_nucleo_se; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_cuentaporcobraritem
    ADD CONSTRAINT finanzas_cuentaporco_servicio_id_f37074ad_fk_nucleo_se FOREIGN KEY (servicio_id) REFERENCES public.nucleo_servicio(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: finanzas_pago finanzas_pago_cuenta_id_d8221b64_fk_finanzas_cuentaporcobrar_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_pago
    ADD CONSTRAINT finanzas_pago_cuenta_id_d8221b64_fk_finanzas_cuentaporcobrar_id FOREIGN KEY (cuenta_id) REFERENCES public.finanzas_cuentaporcobrar(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: finanzas_proforma finanzas_proforma_cliente_id_9f458133_fk_nucleo_cliente_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_proforma
    ADD CONSTRAINT finanzas_proforma_cliente_id_9f458133_fk_nucleo_cliente_id FOREIGN KEY (cliente_id) REFERENCES public.nucleo_cliente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: finanzas_proforma finanzas_proforma_proyecto_id_c68ae01b_fk_nucleo_proyecto_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_proforma
    ADD CONSTRAINT finanzas_proforma_proyecto_id_c68ae01b_fk_nucleo_proyecto_id FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: finanzas_proformaitem finanzas_proformaite_proforma_id_6924e482_fk_finanzas_; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_proformaitem
    ADD CONSTRAINT finanzas_proformaite_proforma_id_6924e482_fk_finanzas_ FOREIGN KEY (proforma_id) REFERENCES public.finanzas_proforma(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: finanzas_proformaitem finanzas_proformaite_servicio_id_e2e338bd_fk_nucleo_se; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.finanzas_proformaitem
    ADD CONSTRAINT finanzas_proformaite_servicio_id_e2e338bd_fk_nucleo_se FOREIGN KEY (servicio_id) REFERENCES public.nucleo_servicio(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_fotocampo fotocampo_avance_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_fotocampo
    ADD CONSTRAINT fotocampo_avance_fk FOREIGN KEY (avance_id) REFERENCES public.nucleo_avanceproyecto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_fotocampo fotocampo_programacion_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_fotocampo
    ADD CONSTRAINT fotocampo_programacion_fk FOREIGN KEY (programacion_id) REFERENCES public.gestion_programacion(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_fotocampo fotocampo_punto_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_fotocampo
    ADD CONSTRAINT fotocampo_punto_fk FOREIGN KEY (punto_id) REFERENCES public.gestion_punto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_fotocampo fotocampo_recepcion_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_fotocampo
    ADD CONSTRAINT fotocampo_recepcion_fk FOREIGN KEY (recepcion_id) REFERENCES public.gestion_recepcion(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_horaextradia horaextradia_proyecto_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horaextradia
    ADD CONSTRAINT horaextradia_proyecto_fk FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_horaextradia horaextradia_registro_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horaextradia
    ADD CONSTRAINT horaextradia_registro_fk FOREIGN KEY (registro_id) REFERENCES public.rrhh_registrohoraextra(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: lectura_campoleido lectura_campoleido_hoja_id_191f0d20_fk_lectura_hojaescaneada_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_campoleido
    ADD CONSTRAINT lectura_campoleido_hoja_id_191f0d20_fk_lectura_hojaescaneada_id FOREIGN KEY (hoja_id) REFERENCES public.lectura_hojaescaneada(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: lectura_campoleido lectura_campoleido_revisado_por_id_bb38d9f7_fk_nucleo_us; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_campoleido
    ADD CONSTRAINT lectura_campoleido_revisado_por_id_bb38d9f7_fk_nucleo_us FOREIGN KEY (revisado_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: lectura_confusioncaracter lectura_confusioncar_escritor_id_5f2ad505_fk_nucleo_em; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_confusioncaracter
    ADD CONSTRAINT lectura_confusioncar_escritor_id_5f2ad505_fk_nucleo_em FOREIGN KEY (escritor_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: lectura_hojaescaneada lectura_hojaescanead_llenada_por_id_263d0a68_fk_nucleo_em; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_hojaescaneada
    ADD CONSTRAINT lectura_hojaescanead_llenada_por_id_263d0a68_fk_nucleo_em FOREIGN KEY (llenada_por_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: lectura_hojaescaneada lectura_hojaescanead_proyecto_id_f7544561_fk_nucleo_pr; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_hojaescaneada
    ADD CONSTRAINT lectura_hojaescanead_proyecto_id_f7544561_fk_nucleo_pr FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: lectura_hojaescaneada lectura_hojaescanead_revisada_por_id_cf2d334a_fk_nucleo_us; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_hojaescaneada
    ADD CONSTRAINT lectura_hojaescanead_revisada_por_id_cf2d334a_fk_nucleo_us FOREIGN KEY (revisada_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: lectura_hojaescaneada lectura_hojaescanead_subida_por_id_8cb4ca5c_fk_nucleo_us; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lectura_hojaescaneada
    ADD CONSTRAINT lectura_hojaescanead_subida_por_id_8cb4ca5c_fk_nucleo_us FOREIGN KEY (subida_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_lineaplanilla linea_planilla_prestamo_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_lineaplanilla
    ADD CONSTRAINT linea_planilla_prestamo_fk FOREIGN KEY (prestamo_id) REFERENCES public.rrhh_prestamo(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_avanceproyecto nucleo_avanceproyect_proyecto_id_9631e916_fk_nucleo_pr; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_avanceproyecto
    ADD CONSTRAINT nucleo_avanceproyect_proyecto_id_9631e916_fk_nucleo_pr FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_avanceproyecto nucleo_avanceproyect_subido_por_id_41c6e00f_fk_nucleo_us; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_avanceproyecto
    ADD CONSTRAINT nucleo_avanceproyect_subido_por_id_41c6e00f_fk_nucleo_us FOREIGN KEY (subido_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_contactocliente nucleo_contactocliente_cliente_id_cf457ab9_fk_nucleo_cliente_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_contactocliente
    ADD CONSTRAINT nucleo_contactocliente_cliente_id_cf457ab9_fk_nucleo_cliente_id FOREIGN KEY (cliente_id) REFERENCES public.nucleo_cliente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_empleado nucleo_empleado_departamento_id_5cb20d55_fk_nucleo_de; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_empleado
    ADD CONSTRAINT nucleo_empleado_departamento_id_5cb20d55_fk_nucleo_de FOREIGN KEY (departamento_id) REFERENCES public.nucleo_departamento(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_empleado nucleo_empleado_usuario_id_27efc138_fk_nucleo_usuario_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_empleado
    ADD CONSTRAINT nucleo_empleado_usuario_id_27efc138_fk_nucleo_usuario_id FOREIGN KEY (usuario_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_proyecto nucleo_proyecto_cliente_id_6e4181fd_fk_nucleo_cliente_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_proyecto
    ADD CONSTRAINT nucleo_proyecto_cliente_id_6e4181fd_fk_nucleo_cliente_id FOREIGN KEY (cliente_id) REFERENCES public.nucleo_cliente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_proyectotecnico nucleo_proyectotecni_empleado_id_c9db7e2f_fk_nucleo_em; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_proyectotecnico
    ADD CONSTRAINT nucleo_proyectotecni_empleado_id_c9db7e2f_fk_nucleo_em FOREIGN KEY (empleado_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_proyectotecnico nucleo_proyectotecni_proyecto_id_fc1939c0_fk_nucleo_pr; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_proyectotecnico
    ADD CONSTRAINT nucleo_proyectotecni_proyecto_id_fc1939c0_fk_nucleo_pr FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_reportesemanal nucleo_reportesemana_proyecto_id_a16390ee_fk_nucleo_pr; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_reportesemanal
    ADD CONSTRAINT nucleo_reportesemana_proyecto_id_a16390ee_fk_nucleo_pr FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_reportesemanal nucleo_reportesemana_reportado_por_id_43a4c7bb_fk_nucleo_em; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_reportesemanal
    ADD CONSTRAINT nucleo_reportesemana_reportado_por_id_43a4c7bb_fk_nucleo_em FOREIGN KEY (reportado_por_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_roldepartamento nucleo_roldepartamen_departamento_id_f7d65418_fk_nucleo_de; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_roldepartamento
    ADD CONSTRAINT nucleo_roldepartamen_departamento_id_f7d65418_fk_nucleo_de FOREIGN KEY (departamento_id) REFERENCES public.nucleo_departamento(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_roldepartamento nucleo_roldepartamento_grupo_id_91ab3c19_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_roldepartamento
    ADD CONSTRAINT nucleo_roldepartamento_grupo_id_91ab3c19_fk_auth_group_id FOREIGN KEY (grupo_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_usuario_groups nucleo_usuario_groups_group_id_d1f4531a_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario_groups
    ADD CONSTRAINT nucleo_usuario_groups_group_id_d1f4531a_fk_auth_group_id FOREIGN KEY (group_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_usuario_groups nucleo_usuario_groups_usuario_id_bad2d48b_fk_nucleo_usuario_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario_groups
    ADD CONSTRAINT nucleo_usuario_groups_usuario_id_bad2d48b_fk_nucleo_usuario_id FOREIGN KEY (usuario_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_usuario_user_permissions nucleo_usuario_user__permission_id_c8cd6ed4_fk_auth_perm; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario_user_permissions
    ADD CONSTRAINT nucleo_usuario_user__permission_id_c8cd6ed4_fk_auth_perm FOREIGN KEY (permission_id) REFERENCES public.auth_permission(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: nucleo_usuario_user_permissions nucleo_usuario_user__usuario_id_1de9b0a6_fk_nucleo_us; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nucleo_usuario_user_permissions
    ADD CONSTRAINT nucleo_usuario_user__usuario_id_1de9b0a6_fk_nucleo_us FOREIGN KEY (usuario_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_oferta oferta_cliente_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_oferta
    ADD CONSTRAINT oferta_cliente_fk FOREIGN KEY (cliente_id) REFERENCES public.nucleo_cliente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_oferta oferta_departamento_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_oferta
    ADD CONSTRAINT oferta_departamento_fk FOREIGN KEY (departamento_id) REFERENCES public.nucleo_departamento(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_oferta oferta_proforma_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_oferta
    ADD CONSTRAINT oferta_proforma_fk FOREIGN KEY (proforma_id) REFERENCES public.finanzas_proforma(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_oferta oferta_proyecto_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_oferta
    ADD CONSTRAINT oferta_proyecto_fk FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_oferta oferta_solicitud_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_oferta
    ADD CONSTRAINT oferta_solicitud_fk FOREIGN KEY (solicitud_id) REFERENCES public.gestion_solicitud(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_ofertaedicion ofertaedicion_oferta_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ofertaedicion
    ADD CONSTRAINT ofertaedicion_oferta_fk FOREIGN KEY (oferta_id) REFERENCES public.gestion_oferta(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_ofertaitem ofertaitem_lote_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ofertaitem
    ADD CONSTRAINT ofertaitem_lote_fk FOREIGN KEY (lote_id) REFERENCES public.gestion_ofertalote(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_ofertaitem ofertaitem_servicio_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ofertaitem
    ADD CONSTRAINT ofertaitem_servicio_fk FOREIGN KEY (servicio_id) REFERENCES public.nucleo_servicio(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_ofertalote ofertalote_oferta_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_ofertalote
    ADD CONSTRAINT ofertalote_oferta_fk FOREIGN KEY (oferta_id) REFERENCES public.gestion_oferta(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_prestamo prestamo_empleado_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_prestamo
    ADD CONSTRAINT prestamo_empleado_fk FOREIGN KEY (empleado_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_prestamo prestamo_usuario_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_prestamo
    ADD CONSTRAINT prestamo_usuario_fk FOREIGN KEY (registrado_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_programacion programacion_cuadrilla_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_programacion
    ADD CONSTRAINT programacion_cuadrilla_fk FOREIGN KEY (cuadrilla_id) REFERENCES public.gestion_cuadrilla(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_programacion programacion_expediente_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_programacion
    ADD CONSTRAINT programacion_expediente_fk FOREIGN KEY (expediente_id) REFERENCES public.gestion_expediente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_programacion programacion_registrado_por_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_programacion
    ADD CONSTRAINT programacion_registrado_por_fk FOREIGN KEY (registrado_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_programacion programacion_reprograma_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_programacion
    ADD CONSTRAINT programacion_reprograma_fk FOREIGN KEY (reprograma_a_id) REFERENCES public.gestion_programacion(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_punto punto_expediente_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_punto
    ADD CONSTRAINT punto_expediente_fk FOREIGN KEY (expediente_id) REFERENCES public.gestion_expediente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_punto punto_ofertaitem_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_punto
    ADD CONSTRAINT punto_ofertaitem_fk FOREIGN KEY (ofertaitem_id) REFERENCES public.gestion_ofertaitem(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_punto punto_origen_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_punto
    ADD CONSTRAINT punto_origen_fk FOREIGN KEY (punto_origen_id) REFERENCES public.gestion_punto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_punto punto_programacion_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_punto
    ADD CONSTRAINT punto_programacion_fk FOREIGN KEY (programacion_id) REFERENCES public.gestion_programacion(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_punto punto_tipo_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_punto
    ADD CONSTRAINT punto_tipo_fk FOREIGN KEY (tipo) REFERENCES public.gestion_tipoexploracion(codigo) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_recepcion recepcion_cuadrilla_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_recepcion
    ADD CONSTRAINT recepcion_cuadrilla_fk FOREIGN KEY (cuadrilla_id) REFERENCES public.gestion_cuadrilla(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_recepcion recepcion_expediente_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_recepcion
    ADD CONSTRAINT recepcion_expediente_fk FOREIGN KEY (expediente_id) REFERENCES public.gestion_expediente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_recepcion recepcion_registrado_por_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_recepcion
    ADD CONSTRAINT recepcion_registrado_por_fk FOREIGN KEY (registrado_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_recepcion recepcion_verificada_por_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_recepcion
    ADD CONSTRAINT recepcion_verificada_por_fk FOREIGN KEY (verificada_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_recepcionpunto recepcionpunto_punto_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_recepcionpunto
    ADD CONSTRAINT recepcionpunto_punto_fk FOREIGN KEY (punto_id) REFERENCES public.gestion_punto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_recepcionpunto recepcionpunto_recepcion_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_recepcionpunto
    ADD CONSTRAINT recepcionpunto_recepcion_fk FOREIGN KEY (recepcion_id) REFERENCES public.gestion_recepcion(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_registrohoraextra registro_he_empleado_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_registrohoraextra
    ADD CONSTRAINT registro_he_empleado_fk FOREIGN KEY (empleado_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_registrohoraextra registro_he_linea_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_registrohoraextra
    ADD CONSTRAINT registro_he_linea_fk FOREIGN KEY (linea_planilla_id) REFERENCES public.rrhh_lineaplanilla(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_registrohoraextra registro_he_usuario_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_registrohoraextra
    ADD CONSTRAINT registro_he_usuario_fk FOREIGN KEY (registrado_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_reglaalerta reglaalerta_etapa_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_reglaalerta
    ADD CONSTRAINT reglaalerta_etapa_fk FOREIGN KEY (etapa) REFERENCES public.gestion_etapaconfig(etapa) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_boleta rrhh_boleta_linea_planilla_id_38d7d81c_fk_rrhh_lineaplanilla_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_boleta
    ADD CONSTRAINT rrhh_boleta_linea_planilla_id_38d7d81c_fk_rrhh_lineaplanilla_id FOREIGN KEY (linea_planilla_id) REFERENCES public.rrhh_lineaplanilla(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_contrato rrhh_contrato_empleado_id_31061206_fk_nucleo_empleado_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_contrato
    ADD CONSTRAINT rrhh_contrato_empleado_id_31061206_fk_nucleo_empleado_id FOREIGN KEY (empleado_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_horaextra rrhh_horaextra_empleado_id_33aade42_fk_nucleo_empleado_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horaextra
    ADD CONSTRAINT rrhh_horaextra_empleado_id_33aade42_fk_nucleo_empleado_id FOREIGN KEY (empleado_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_horaextra rrhh_horaextra_proyecto_id_b7454619_fk_nucleo_proyecto_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horaextra
    ADD CONSTRAINT rrhh_horaextra_proyecto_id_b7454619_fk_nucleo_proyecto_id FOREIGN KEY (proyecto_id) REFERENCES public.nucleo_proyecto(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_lineaplanilla rrhh_lineaplanilla_empleado_id_fcb519ac_fk_nucleo_empleado_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_lineaplanilla
    ADD CONSTRAINT rrhh_lineaplanilla_empleado_id_fcb519ac_fk_nucleo_empleado_id FOREIGN KEY (empleado_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_lineaplanilla rrhh_lineaplanilla_planilla_id_ff042010_fk_rrhh_planilla_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_lineaplanilla
    ADD CONSTRAINT rrhh_lineaplanilla_planilla_id_ff042010_fk_rrhh_planilla_id FOREIGN KEY (planilla_id) REFERENCES public.rrhh_planilla(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_planilla rrhh_planilla_departamento_id_10b7df02_fk_nucleo_de; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla
    ADD CONSTRAINT rrhh_planilla_departamento_id_10b7df02_fk_nucleo_de FOREIGN KEY (departamento_id) REFERENCES public.nucleo_departamento(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_planilla rrhh_planilla_generada_por_id_19fbdf5a_fk_nucleo_usuario_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla
    ADD CONSTRAINT rrhh_planilla_generada_por_id_19fbdf5a_fk_nucleo_usuario_id FOREIGN KEY (generada_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_servicioconfig servicioconfig_servicio_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_servicioconfig
    ADD CONSTRAINT servicioconfig_servicio_fk FOREIGN KEY (servicio_id) REFERENCES public.nucleo_servicio(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_servicioconfig servicioconfig_tipo_exploracion_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_servicioconfig
    ADD CONSTRAINT servicioconfig_tipo_exploracion_fk FOREIGN KEY (tipo_exploracion) REFERENCES public.gestion_tipoexploracion(codigo) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_solicitud solicitud_cliente_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_solicitud
    ADD CONSTRAINT solicitud_cliente_fk FOREIGN KEY (cliente_id) REFERENCES public.nucleo_cliente(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: gestion_solicitud solicitud_responsable_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gestion_solicitud
    ADD CONSTRAINT solicitud_responsable_fk FOREIGN KEY (responsable_id) REFERENCES public.nucleo_empleado(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_tarifahoraextra tarifa_he_departamento_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_tarifahoraextra
    ADD CONSTRAINT tarifa_he_departamento_fk FOREIGN KEY (departamento_id) REFERENCES public.nucleo_departamento(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: rrhh_tarifahoraextra tarifa_he_usuario_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_tarifahoraextra
    ADD CONSTRAINT tarifa_he_usuario_fk FOREIGN KEY (actualizado_por_id) REFERENCES public.nucleo_usuario(id) DEFERRABLE INITIALLY DEFERRED;


--
-- PostgreSQL database dump complete
--


