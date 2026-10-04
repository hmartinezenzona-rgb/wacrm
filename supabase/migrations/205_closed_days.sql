-- =====================================================================
-- 205 — Special closed days (staging first)
--
-- Owner, 2026-10-03: Monday 2026-10-05 the business does not work (its anniversary). The bot must answer that day as
-- out of hours, all day, saying why, and point any work to the next business day. Hours lived only in cerebro_horario
-- (opening/closing, Sundays closed in the Cerebro's code); there was no way to close a whole weekday.
--   - cerebro_config 'dias_cerrados': a JSON list of {"fecha": "YYYY-MM-DD", "motivo": "..."} (empty by default; the
--     owner's dates are data, set per environment). The motivo is the clause that follows "no estamos trabajando",
--     e.g. "porque estamos de aniversario" (owner's wording).
--   - cerebro_dia_cerrado(date) -> the reason, or NULL (a broken config closes nothing).
--   - cerebro_proximo_dia_habil(date) -> the next day that is neither Sunday nor a closed day.
--   - cerebro_cierre_especial_info(today) -> {hoy_motivo, proximo_habil ("mañana martes 6" / "el martes 6"),
--     proximo_cierre ("el lunes 5 no trabajamos porque ...", a closed day before the next business day)} for the Cerebro's
--     'Contexto conversacion' (gate101), whose Decisor and agent treat a closed day as out of hours all day.
--
-- Guarded by supabase/staging/assertions/closed-days.sql.
-- ROLLBACK: ROLLBACK-205-closed-days.sql
-- =====================================================================
INSERT INTO public.cerebro_config (clave, valor, descripcion)
VALUES ('dias_cerrados', '[]', 'Dias sin trabajar ademas de los domingos: lista JSON de {"fecha":"YYYY-MM-DD","motivo":"porque ..."} (el motivo sigue a "no estamos trabajando"). Ese dia el bot atiende como fuera de horario todo el dia y dice el motivo (205).')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.cerebro_dia_cerrado(p_fecha date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_motivo text;
BEGIN
  SELECT nullif(btrim(e ->> 'motivo'), '') INTO v_motivo
    FROM jsonb_array_elements(coalesce(nullif(cerebro_config_get('dias_cerrados'), ''), '[]')::jsonb) e
   WHERE (e ->> 'fecha')::date = p_fecha
   LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN coalesce(v_motivo, 'por un dia festivo');
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;   -- a broken config closes nothing
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_proximo_dia_habil(p_desde date)
 RETURNS date
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE d date := p_desde + 1;
BEGIN
  FOR i IN 1 .. 30 LOOP
    IF extract(dow FROM d) <> 0 AND cerebro_dia_cerrado(d) IS NULL THEN RETURN d; END IF;
    d := d + 1;
  END LOOP;
  RETURN d;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_cierre_especial_info(p_hoy date DEFAULT ((now() AT TIME ZONE 'America/Guyana'))::date)
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

REVOKE ALL ON FUNCTION public.cerebro_dia_cerrado(date), public.cerebro_proximo_dia_habil(date), public.cerebro_cierre_especial_info(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_dia_cerrado(date), public.cerebro_proximo_dia_habil(date), public.cerebro_cierre_especial_info(date) TO authenticated, service_role;
