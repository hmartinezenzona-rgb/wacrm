-- =====================================================================
-- Assertion for migration 136 (business hours in one place).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- =====================================================================
DO $$
DECLARE v_r record; v_f text;
BEGIN
  -- 1. Today's hours come from the single source.
  SELECT * INTO v_r FROM cerebro_horario();
  IF v_r.abre <> '09:00'::time OR v_r.cierra <> '17:00'::time THEN RAISE EXCEPTION 'case 1: expected 09:00-17:00, got %', row_to_json(v_r); END IF;
  RAISE NOTICE 'PASS 1: the business hours are 09:00-17:00, from cerebro_config';

  -- 2. Changing ONE row changes the hours everywhere; an empty value falls back to the default.
  UPDATE cerebro_config SET valor = '18:00' WHERE clave = 'horario_cierra';
  SELECT * INTO v_r FROM cerebro_horario();
  IF v_r.cierra <> '18:00'::time THEN RAISE EXCEPTION 'case 2: horario_cierra must drive the closing time, got %', v_r.cierra; END IF;
  UPDATE cerebro_config SET valor = '' WHERE clave = 'horario_cierra';
  SELECT * INTO v_r FROM cerebro_horario();
  IF v_r.cierra <> '17:00'::time THEN RAISE EXCEPTION 'case 2: an empty value must fall back to 17:00, got %', v_r.cierra; END IF;
  UPDATE cerebro_config SET valor = '17:00' WHERE clave = 'horario_cierra';
  RAISE NOTICE 'PASS 2: one row changes the hours; an empty value falls back to 09:00/17:00';

  -- 3. No watcher keeps its own copy of the hours.
  FOREACH v_f IN ARRAY ARRAY['cerebro_avisar_chats_atascados','cerebro_avisar_envios_incompletos',
      'cerebro_avisar_envios_sin_beneficiario','cerebro_avisar_mensajes_perdidos','cerebro_avisar_remesas_abiertas_viejas'] LOOP
    IF (SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = v_f) ~ '''(09|17):00''::time|::int, (9|17)\)'
       OR (SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = v_f) !~ 'cerebro_horario\(\)' THEN
      RAISE EXCEPTION 'case 3: % still has its own hours or does not read cerebro_horario()', v_f;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM cerebro_config WHERE clave IN ('envio_incompleto_desde','envio_incompleto_hasta','perdido_hora_desde','perdido_hora_hasta')
              AND valor IN ('09:00','17:00','9','17')) THEN
    RAISE EXCEPTION 'case 3: per-watcher rows still repeat the global hours';
  END IF;
  RAISE NOTICE 'PASS 3: the 5 watchers read cerebro_horario(); no copy of the hours left';

  -- 4. Every watcher still runs.
  PERFORM * FROM cerebro_avisar_chats_atascados();
  PERFORM * FROM cerebro_avisar_envios_incompletos();
  PERFORM * FROM cerebro_avisar_envios_sin_beneficiario();
  PERFORM * FROM cerebro_avisar_mensajes_perdidos();
  PERFORM * FROM cerebro_avisar_remesas_abiertas_viejas();
  RAISE NOTICE 'PASS 4: the 5 watchers run without errors';

  IF has_function_privilege('anon', 'cerebro_horario()', 'EXECUTE') THEN RAISE EXCEPTION 'case 5: anon must not execute cerebro_horario'; END IF;
  RAISE NOTICE 'PASS 5: not exposed to anon';
END $$;
