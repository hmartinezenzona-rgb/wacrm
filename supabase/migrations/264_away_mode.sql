-- =====================================================================
-- 264 — Away mode: temporary absence the bot mentions (staging first)
--
-- Owner, 2026-10-21: any admin can tell the bot from the panel that the team stepped out ("tuvimos que salir un
-- momento, volvemos a las 3:00 pm"). The bot keeps working exactly as always (quotes, registers, answers) and adds ONE
-- natural line with the reason and the return time. Closed days (205) cover whole days only and had no panel.
--   - cerebro_config 'ausencia': empty string = no absence, or JSON {"hasta": ISO-8601 timestamptz, "motivo": "porque ...",
--     "por": "who set it", "desde": ISO-8601 timestamptz}. The panel writes it with the service role (RLS, no policies).
--   - cerebro_ausencia_actual(now) -> {motivo, hasta, hasta_texto, por}, or NULL when the value is empty, not valid
--     JSON, has no valid hasta, or hasta <= now (an expired absence disappears by itself; a broken one changes nothing).
--     hasta_texto is Spanish in Guyana time (UTC-4): "a las 3:00 pm" the same day, "mañana a las 9:00 am" the next
--     day, "el martes 6 a las 9:00 am" later (same wording style as cerebro_cierre_especial_info).
--   - cerebro_cierre_especial_info(today) gains the key "ausencia" (the object above, or JSON null); every other key
--     and its behaviour are unchanged. The Cerebro's 'Contexto conversacion' already carries this function's result.
--
-- Guarded by supabase/staging/assertions/away-mode.sql.
-- ROLLBACK: ROLLBACK-264-away-mode.sql
-- =====================================================================
INSERT INTO public.cerebro_config (clave, valor, descripcion)
VALUES ('ausencia', '', 'Ausencia temporal del equipo: vacio = ninguna, o JSON {"hasta":"ISO-8601","motivo":"porque ...","por":"nombre","desde":"ISO-8601"}. Mientras hasta no haya pasado el bot sigue atendiendo normal y agrega UNA linea con el motivo y la hora de regreso (264). Lo escribe el panel.')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.cerebro_ausencia_actual(p_ahora timestamptz DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_dias text[] := ARRAY['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
  v_cfg jsonb;
  v_hasta timestamptz;
  v_local timestamp;
  v_hoy date := (p_ahora AT TIME ZONE 'America/Guyana')::date;
  v_dia date;
  v_h int;
  v_hora text;
  v_texto text;
BEGIN
  v_cfg := nullif(btrim(coalesce(cerebro_config_get('ausencia'), '')), '')::jsonb;
  IF v_cfg IS NULL OR jsonb_typeof(v_cfg) <> 'object' THEN RETURN NULL; END IF;
  v_hasta := (v_cfg ->> 'hasta')::timestamptz;
  IF v_hasta IS NULL OR v_hasta <= p_ahora THEN RETURN NULL; END IF;

  v_local := v_hasta AT TIME ZONE 'America/Guyana';
  v_dia := v_local::date;
  v_h := extract(hour FROM v_local)::int;
  v_hora := (CASE WHEN v_h % 12 = 0 THEN 12 ELSE v_h % 12 END)::text || ':' || lpad(extract(minute FROM v_local)::int::text, 2, '0')
            || CASE WHEN v_h < 12 THEN ' am' ELSE ' pm' END;
  v_texto := CASE WHEN v_dia = v_hoy THEN 'a las ' || v_hora
                  WHEN v_dia = v_hoy + 1 THEN 'mañana a las ' || v_hora
                  ELSE 'el ' || v_dias[extract(dow FROM v_dia)::int + 1] || ' ' || extract(day FROM v_dia)::int || ' a las ' || v_hora END;

  RETURN jsonb_build_object(
    'motivo', coalesce(nullif(btrim(v_cfg ->> 'motivo'), ''), 'por un asunto del equipo'),
    'hasta', to_char(v_hasta AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'hasta_texto', v_texto,
    'por', nullif(btrim(v_cfg ->> 'por'), ''));
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;   -- a broken config changes nothing
END $function$;

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
                                || ' no trabajamos ' || v_motivo END,
    'ausencia', cerebro_ausencia_actual(now()));
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_ausencia_actual(timestamptz), public.cerebro_cierre_especial_info(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_ausencia_actual(timestamptz), public.cerebro_cierre_especial_info(date) TO authenticated, service_role;
