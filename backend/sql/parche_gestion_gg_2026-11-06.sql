-- ============================================================================
-- JUPACA PROYECTA · Parche a Gestión GG (6-nov-2026)
-- Se corre DESPUÉS de base_total_jupaca.sql (o sobre la base actual). Probado en PostgreSQL 16.
--
-- Incluye:
--   1. Correlativo de oferta mayor a 999 (el CHECK usaba lpad(...,3,'0'), que TRUNCA).
--   2. Feriados 2027.
--
-- NO incluye (falta decidir): la etapa 'cancelado' sin fila en gestion_etapaconfig.
--
-- IMPORTANTE: si las tablas gestion_* las crean las migraciones de Django (app "gestion"),
-- el mismo cambio del punto 1 debe hacerse también en el modelo (Meta.constraints) y en una
-- migración; si no, la siguiente migración vuelve a poner el CHECK viejo.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Correlativo > 999
--    lpad('1000', 3, '0') devuelve '100' (corta a la derecha), así que el CHECK anterior:
--      - rechazaba el código correcto JP-GG-2026-1000, y
--      - aceptaba JP-GG-2026-100 para el correlativo 1000 (chocaba con el 100).
--    Ahora se rellena a 3 dígitos como mínimo y no se corta nunca: 5 -> 005, 999 -> 999,
--    1000 -> 1000, 12345 -> 12345. La columna codigo (varchar(20)) alcanza de sobra.
--    Si ya existieran ofertas con correlativo >= 1000 y código truncado, el ADD CONSTRAINT
--    falla y hay que corregir esos códigos antes.
-- ---------------------------------------------------------------------------
ALTER TABLE public.gestion_oferta DROP CONSTRAINT oferta_codigo_formato;
ALTER TABLE public.gestion_oferta ADD CONSTRAINT oferta_codigo_formato
    CHECK (codigo = 'JP-' || prefijo || '-' || anio::text || '-' ||
                    lpad(correlativo::text, greatest(3, length(correlativo::text)), '0'));

-- ---------------------------------------------------------------------------
-- 2. Feriados 2027 para contar días hábiles
--    SUPUESTO (igual que los de 2026): misma lista de fechas que 2026, por confirmar con la
--    empresa, por eso es_supuesto = true. Las fechas fijas se repiten; Semana Santa se calculó
--    con la Pascua de 2027 (domingo 28 de marzo).
-- ---------------------------------------------------------------------------
INSERT INTO public.gestion_feriado (fecha, nombre, es_supuesto) VALUES
    ('2027-01-01', 'Año Nuevo', true),
    ('2027-03-25', 'Jueves Santo', true),
    ('2027-03-26', 'Viernes Santo', true),
    ('2027-03-27', 'Sábado Santo', true),
    ('2027-05-01', 'Día del Trabajo', true),
    ('2027-05-10', 'Día de la Madre', true),
    ('2027-06-17', 'Día del Padre', true),
    ('2027-08-03', 'Fiestas agostinas', true),
    ('2027-08-04', 'Fiestas agostinas', true),
    ('2027-08-05', 'Fiestas agostinas', true),
    ('2027-08-06', 'Fiestas agostinas', true),
    ('2027-09-15', 'Independencia', true),
    ('2027-11-02', 'Día de los Difuntos', true),
    ('2027-12-25', 'Navidad', true)
ON CONFLICT (fecha) DO NOTHING;

COMMIT;
