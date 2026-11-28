\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 264 (away mode). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- Owner, 2026-10-21: admins set a temporary absence from the panel; the bot keeps working and adds one line with the
-- reason and the return time. The absence lives in cerebro_config 'ausencia' (empty = none, or JSON
-- {"hasta","motivo","por","desde"}); cerebro_ausencia_actual(now) reads it, cerebro_cierre_especial_info() exposes it.
--
-- Cases (fixed "now" timestamps, Guyana = UTC-4, 2026-10-21 is a Wednesday):
--   1 empty -> NULL        2 invalid JSON -> NULL      3 missing / invalid hasta -> NULL   4 expired (past / equal) -> NULL
--   5 same day 3:00 pm     6 9:05 am                   7 12:00 pm                          8 12:30 am
--   9 tomorrow             10 later day (weekday + day) 11 motivo empty -> default text    12 motivo trimmed, por, hasta ISO
--   13 cerebro_cierre_especial_info: new key + old keys unchanged   14 ausencia NULL in info when none   15 ACL
-- =====================================================================
DO $$
DECLARE
  v_res jsonb;
  v_info jsonb;
BEGIN
  INSERT INTO cerebro_config (clave, valor) VALUES ('ausencia', '') ON CONFLICT (clave) DO NOTHING;

  -- 1. Empty value -> no absence.
  UPDATE cerebro_config SET valor = '' WHERE clave = 'ausencia';
  IF cerebro_ausencia_actual('2026-10-21 13:10-04') IS NOT NULL THEN RAISE EXCEPTION 'case 1: got %', cerebro_ausencia_actual('2026-10-21 13:10-04'); END IF;

  -- 2. Invalid JSON -> NULL (fail open).
  UPDATE cerebro_config SET valor = 'no es json' WHERE clave = 'ausencia';
  IF cerebro_ausencia_actual('2026-10-21 13:10-04') IS NOT NULL THEN RAISE EXCEPTION 'case 2: got %', cerebro_ausencia_actual('2026-10-21 13:10-04'); END IF;

  -- 3. Missing or invalid hasta -> NULL.
  UPDATE cerebro_config SET valor = '{"motivo": "x"}' WHERE clave = 'ausencia';
  IF cerebro_ausencia_actual('2026-10-21 13:10-04') IS NOT NULL THEN RAISE EXCEPTION 'case 3a: got %', cerebro_ausencia_actual('2026-10-21 13:10-04'); END IF;
  UPDATE cerebro_config SET valor = '{"hasta": "manana", "motivo": "x"}' WHERE clave = 'ausencia';
  IF cerebro_ausencia_actual('2026-10-21 13:10-04') IS NOT NULL THEN RAISE EXCEPTION 'case 3b: got %', cerebro_ausencia_actual('2026-10-21 13:10-04'); END IF;
  UPDATE cerebro_config SET valor = '[1, 2]' WHERE clave = 'ausencia';
  IF cerebro_ausencia_actual('2026-10-21 13:10-04') IS NOT NULL THEN RAISE EXCEPTION 'case 3c: got %', cerebro_ausencia_actual('2026-10-21 13:10-04'); END IF;

  -- 4. Expired (hasta in the past, or equal to now) -> NULL.
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-21T15:00:00-04:00", "motivo": "x"}' WHERE clave = 'ausencia';
  IF cerebro_ausencia_actual('2026-10-21 15:01-04') IS NOT NULL THEN RAISE EXCEPTION 'case 4a: got %', cerebro_ausencia_actual('2026-10-21 15:01-04'); END IF;
  IF cerebro_ausencia_actual('2026-10-21 15:00-04') IS NOT NULL THEN RAISE EXCEPTION 'case 4b: got %', cerebro_ausencia_actual('2026-10-21 15:00-04'); END IF;

  -- 5. Same Guyana day -> "a las 3:00 pm" (the offset in the stored value is irrelevant: 19:00Z = 15:00 Guyana).
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-21T19:00:00Z", "motivo": "porque tuvimos que salir"}' WHERE clave = 'ausencia';
  v_res := cerebro_ausencia_actual('2026-10-21 13:10-04');
  IF v_res ->> 'hasta_texto' IS DISTINCT FROM 'a las 3:00 pm' THEN RAISE EXCEPTION 'case 5: got %', v_res; END IF;

  -- 6. Minutes always two digits.
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-21T09:05:00-04:00", "motivo": "x"}' WHERE clave = 'ausencia';
  v_res := cerebro_ausencia_actual('2026-10-21 08:00-04');
  IF v_res ->> 'hasta_texto' IS DISTINCT FROM 'a las 9:05 am' THEN RAISE EXCEPTION 'case 6: got %', v_res; END IF;

  -- 7. Noon is 12:00 pm.
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-21T12:00:00-04:00", "motivo": "x"}' WHERE clave = 'ausencia';
  v_res := cerebro_ausencia_actual('2026-10-21 08:00-04');
  IF v_res ->> 'hasta_texto' IS DISTINCT FROM 'a las 12:00 pm' THEN RAISE EXCEPTION 'case 7: got %', v_res; END IF;

  -- 8. 0:30 is 12:30 am.
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-21T00:30:00-04:00", "motivo": "x"}' WHERE clave = 'ausencia';
  v_res := cerebro_ausencia_actual('2026-10-21 00:10-04');
  IF v_res ->> 'hasta_texto' IS DISTINCT FROM 'a las 12:30 am' THEN RAISE EXCEPTION 'case 8: got %', v_res; END IF;

  -- 9. Next Guyana date -> "mañana a las 9:00 am". The Guyana date, not the UTC one, decides (23:30 Guyana is already
  --    the next UTC day).
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-22T09:00:00-04:00", "motivo": "x"}' WHERE clave = 'ausencia';
  v_res := cerebro_ausencia_actual('2026-10-21 13:10-04');
  IF v_res ->> 'hasta_texto' IS DISTINCT FROM 'mañana a las 9:00 am' THEN RAISE EXCEPTION 'case 9a: got %', v_res; END IF;
  v_res := cerebro_ausencia_actual('2026-10-21 23:30-04');
  IF v_res ->> 'hasta_texto' IS DISTINCT FROM 'mañana a las 9:00 am' THEN RAISE EXCEPTION 'case 9b: got %', v_res; END IF;
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-22T02:00:00Z", "motivo": "x"}' WHERE clave = 'ausencia';  -- 22:00 on the 21st in Guyana
  v_res := cerebro_ausencia_actual('2026-10-21 13:10-04');
  IF v_res ->> 'hasta_texto' IS DISTINCT FROM 'a las 10:00 pm' THEN RAISE EXCEPTION 'case 9c: got %', v_res; END IF;

  -- 10. Later day -> "el <weekday> <day> a las ..." (2026-10-24 is a Saturday, 2026-10-26 a Monday).
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-24T09:00:00-04:00", "motivo": "x"}' WHERE clave = 'ausencia';
  v_res := cerebro_ausencia_actual('2026-10-21 13:10-04');
  IF v_res ->> 'hasta_texto' IS DISTINCT FROM 'el sábado 24 a las 9:00 am' THEN RAISE EXCEPTION 'case 10a: got %', v_res; END IF;
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-26T17:45:00-04:00", "motivo": "x"}' WHERE clave = 'ausencia';
  v_res := cerebro_ausencia_actual('2026-10-21 13:10-04');
  IF v_res ->> 'hasta_texto' IS DISTINCT FROM 'el lunes 26 a las 5:45 pm' THEN RAISE EXCEPTION 'case 10b: got %', v_res; END IF;

  -- 11. Empty or blank motivo -> default text.
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-21T15:00:00-04:00", "motivo": "   "}' WHERE clave = 'ausencia';
  v_res := cerebro_ausencia_actual('2026-10-21 13:10-04');
  IF v_res ->> 'motivo' IS DISTINCT FROM 'por un asunto del equipo' THEN RAISE EXCEPTION 'case 11a: got %', v_res; END IF;
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-21T15:00:00-04:00"}' WHERE clave = 'ausencia';
  v_res := cerebro_ausencia_actual('2026-10-21 13:10-04');
  IF v_res ->> 'motivo' IS DISTINCT FROM 'por un asunto del equipo' OR v_res ->> 'por' IS NOT NULL THEN RAISE EXCEPTION 'case 11b: got %', v_res; END IF;

  -- 12. Trimmed motivo, por, hasta as ISO.
  UPDATE cerebro_config SET valor = '{"hasta": "2026-10-21T15:00:00-04:00", "motivo": "  porque tuvimos que salir  ", "por": "Ana", "desde": "2026-10-21T13:00:00-04:00"}' WHERE clave = 'ausencia';
  v_res := cerebro_ausencia_actual('2026-10-21 13:10-04');
  IF v_res ->> 'motivo' IS DISTINCT FROM 'porque tuvimos que salir' OR v_res ->> 'por' IS DISTINCT FROM 'Ana'
     OR (v_res ->> 'hasta')::timestamptz IS DISTINCT FROM '2026-10-21 15:00-04'::timestamptz THEN
    RAISE EXCEPTION 'case 12: got %', v_res; END IF;

  -- 13. cerebro_cierre_especial_info: new key, old keys unchanged (known closed day config).
  UPDATE cerebro_config SET valor = '[{"fecha": "2026-10-05", "motivo": "porque estamos de aniversario"}]' WHERE clave = 'dias_cerrados';
  IF NOT FOUND THEN
    INSERT INTO cerebro_config (clave, valor) VALUES ('dias_cerrados', '[{"fecha": "2026-10-05", "motivo": "porque estamos de aniversario"}]');
  END IF;
  UPDATE cerebro_config SET valor = to_jsonb(json_build_object('hasta', (now() + interval '2 hours'), 'motivo', 'porque salimos', 'por', 'Ana'))::text WHERE clave = 'ausencia';
  v_info := cerebro_cierre_especial_info('2026-10-03');
  IF NOT (v_info ? 'ausencia') OR v_info -> 'ausencia' ->> 'motivo' IS DISTINCT FROM 'porque salimos' THEN RAISE EXCEPTION 'case 13a: got %', v_info; END IF;
  IF v_info ->> 'hoy_motivo' IS NOT NULL OR v_info ->> 'proximo_habil' IS DISTINCT FROM 'el martes 6'
     OR v_info ->> 'proximo_cierre' IS DISTINCT FROM 'el lunes 5 no trabajamos porque estamos de aniversario' THEN
    RAISE EXCEPTION 'case 13b (Saturday): got %', v_info; END IF;
  v_info := cerebro_cierre_especial_info('2026-10-05');
  IF v_info ->> 'hoy_motivo' IS DISTINCT FROM 'porque estamos de aniversario' OR v_info ->> 'proximo_habil' IS DISTINCT FROM 'mañana martes 6' THEN
    RAISE EXCEPTION 'case 13c (Monday): got %', v_info; END IF;
  v_info := cerebro_cierre_especial_info();
  IF NOT (v_info ? 'ausencia') THEN RAISE EXCEPTION 'case 13d: default-argument call lost the key: %', v_info; END IF;

  -- 14. No absence -> key present with JSON null.
  UPDATE cerebro_config SET valor = '' WHERE clave = 'ausencia';
  v_info := cerebro_cierre_especial_info('2026-10-13');
  IF NOT (v_info ? 'ausencia') OR jsonb_typeof(v_info -> 'ausencia') IS DISTINCT FROM 'null'
     OR v_info ->> 'hoy_motivo' IS NOT NULL OR v_info ->> 'proximo_cierre' IS NOT NULL OR v_info ->> 'proximo_habil' IS DISTINCT FROM 'mañana miércoles 14' THEN
    RAISE EXCEPTION 'case 14: got %', v_info; END IF;

  -- 15. ACL: anon and PUBLIC cannot execute; authenticated and service_role can.
  IF has_function_privilege('anon', 'public.cerebro_ausencia_actual(timestamptz)', 'EXECUTE') THEN RAISE EXCEPTION 'case 15a: anon can execute'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.cerebro_ausencia_actual(timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_ausencia_actual(timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 15b: authenticated/service_role cannot execute'; END IF;
  IF has_function_privilege('anon', 'public.cerebro_cierre_especial_info(date)', 'EXECUTE') THEN RAISE EXCEPTION 'case 15c: anon can execute info'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
