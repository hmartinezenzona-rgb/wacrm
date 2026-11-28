-- ROLLBACK of 264_away_mode.sql. Restores cerebro_cierre_especial_info as defined by 205 (no "ausencia" key), then drops
-- the new function and the config row. If the Cerebro's Decisor already reads cierre_especial.ausencia, restore its backup first.
CREATE OR REPLACE FUNCTION public.cerebro_cierre_especial_info(p_hoy date DEFAULT ((now() AT TIME ZONE 'America/Guyana'::text))::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_dias text[] := ARRAY['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
  v_habil date := cerebro_proximo_dia_habil(p_hoy);
  v_cierre date;
  v_motivo text;
BEGIN
  SELECT d::date INTO v_cierre
    FROM generate_series(p_hoy + 1, v_habil - 1, interval '1 day') d
   WHERE cerebro_dia_cerrado(d::date) IS NOT NULL
   ORDER BY d LIMIT 1;
  v_motivo := CASE WHEN v_cierre IS NULL THEN NULL ELSE cerebro_dia_cerrado(v_cierre) END;
  RETURN jsonb_build_object(
    'hoy_motivo', cerebro_dia_cerrado(p_hoy),
    'proximo_habil', CASE WHEN v_habil = p_hoy + 1 THEN 'mañana ' ELSE 'el ' END
                     || v_dias[extract(dow FROM v_habil)::int + 1] || ' ' || extract(day FROM v_habil)::int,
    'proximo_cierre', CASE WHEN v_cierre IS NULL THEN NULL
                           ELSE CASE WHEN v_cierre = p_hoy + 1 THEN 'mañana ' ELSE 'el ' END
                                || v_dias[extract(dow FROM v_cierre)::int + 1] || ' ' || extract(day FROM v_cierre)::int
                                || ' no trabajamos ' || v_motivo END);
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_cierre_especial_info(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_cierre_especial_info(date) TO authenticated, service_role;
DROP FUNCTION IF EXISTS public.cerebro_ausencia_actual(timestamptz);
DELETE FROM public.cerebro_config WHERE clave = 'ausencia';
