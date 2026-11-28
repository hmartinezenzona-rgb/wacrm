-- 314: the six read-only Hermes queries answer with JSON and return nothing to write.
DO $$
DECLARE
  v_conv uuid; v_id text; v_fail text := '';
BEGIN
  SELECT left(id::text, 8), id INTO v_id, v_conv FROM conversations WHERE deleted_at IS NULL ORDER BY updated_at DESC LIMIT 1;

  IF jsonb_typeof(hermes_buscar_conversacion(coalesce(v_id, 'zzz'))) <> 'array' THEN v_fail := v_fail || ' 1:buscar'; END IF;
  IF jsonb_typeof(hermes_leer_mensajes(coalesce(v_id, 'zzz'), 5, NULL)) <> 'object' THEN v_fail := v_fail || ' 2:mensajes'; END IF;
  IF jsonb_typeof(hermes_listar_operaciones(NULL, now() - interval '30 days', now())) <> 'array' THEN v_fail := v_fail || ' 3:operaciones'; END IF;
  IF jsonb_typeof(hermes_ver_calculadora(current_date - 7, current_date)) <> 'object' THEN v_fail := v_fail || ' 4:calculadora'; END IF;
  IF jsonb_typeof(hermes_alertas(now() - interval '1 day', now())) <> 'object' THEN v_fail := v_fail || ' 5:alertas'; END IF;
  IF jsonb_typeof(hermes_tasas()) <> 'object' THEN v_fail := v_fail || ' 6:tasas'; END IF;

  IF v_conv IS NOT NULL THEN
    IF jsonb_typeof(hermes_leer_mensajes(v_id, 5, NULL) -> 'mensajes') <> 'array' THEN v_fail := v_fail || ' 7:mensajes-lista'; END IF;
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
