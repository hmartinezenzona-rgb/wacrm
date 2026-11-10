-- 308: the cadence is 30 minutes / 6 hours and a courtesy message never alerts.
DO $$
DECLARE
  v_def text;
  v_fail text := '';
BEGIN
  IF (SELECT valor FROM cerebro_config WHERE clave = 'chat_atascado_minutos') <> '30' THEN
    v_fail := v_fail || ' 1:minutos';
  END IF;
  IF (SELECT valor FROM cerebro_config WHERE clave = 'chat_atascado_repetir_min') <> '360' THEN
    v_fail := v_fail || ' 2:repetir';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.proname = 'cerebro_avisar_chats_atascados' AND p.pronamespace = 'public'::regnamespace;
  -- 364 moved the detection loop (and its courtesy filter) into _cerebro_atascados_detectar.
  v_def := v_def || COALESCE(
    (SELECT pg_get_functiondef(p.oid) FROM pg_proc p
      WHERE p.proname = '_cerebro_atascados_detectar' AND p.pronamespace = 'public'::regnamespace), '');
  IF v_def ILIKE '%a.sender_type = ''agent''%' THEN
    v_fail := v_fail || ' 3:condicion-vieja';
  END IF;
  IF v_def NOT ILIKE '%NOT cerebro_es_cortesia(u.content_text, u.content_type)%' THEN
    v_fail := v_fail || ' 4:sin-cortesia';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
