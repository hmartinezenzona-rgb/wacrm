-- 315: the period summary answers with counts and a conversation list.
DO $$
DECLARE v jsonb; v_fail text := '';
BEGIN
  v := hermes_resumen_periodo(now() - interval '1 day', now(), 10);
  IF jsonb_typeof(v) <> 'object' THEN v_fail := v_fail || ' 1:tipo'; END IF;
  IF v -> 'totales' -> 'conversaciones' IS NULL THEN v_fail := v_fail || ' 2:sin-conteo'; END IF;
  IF jsonb_typeof(v -> 'conversaciones') <> 'array' THEN v_fail := v_fail || ' 3:sin-lista'; END IF;
  IF jsonb_array_length(v -> 'conversaciones') > 10 THEN v_fail := v_fail || ' 4:limite'; END IF;
  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
