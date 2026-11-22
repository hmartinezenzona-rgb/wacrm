-- Assertion for 388 (self-reverting): the four mutating bot functions are
-- service_role-only for application roles, while remesas_handoff keeps the
-- single grant it had.
--
--   1 authenticated cannot EXECUTE any of the four
--   2 service_role keeps EXECUTE on all four
--   3 anon cannot EXECUTE any of the four (stays closed after 387)
--   4 when the role exists, remesas_handoff can EXECUTE cerebro_registrar_derivacion
--   5 when the role exists, remesas_handoff cannot EXECUTE the other three
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
  v_fails int := 0;
  v_sig text;
  v_sigs text[] := ARRAY[
    'public.cerebro_registrar_derivacion(uuid,text,text,boolean)',
    'public.cerebro_liberar_derivacion_ambigua(uuid)',
    'public.cerebro_auditoria_semantica_registrar(text,jsonb)',
    'public.cerebro_telemetria_registrar(text,jsonb)'
  ];
  v_has_handoff boolean := EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'remesas_handoff');
BEGIN
  FOREACH v_sig IN ARRAY v_sigs LOOP
    IF has_function_privilege('authenticated', v_sig, 'EXECUTE') THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 1] authenticated can EXECUTE %', v_sig;
    END IF;
    IF NOT has_function_privilege('service_role', v_sig, 'EXECUTE') THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 2] service_role lost EXECUTE on %', v_sig;
    END IF;
    IF has_function_privilege('anon', v_sig, 'EXECUTE') THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 3] anon can EXECUTE %', v_sig;
    END IF;
  END LOOP;

  IF v_has_handoff THEN
    IF NOT has_function_privilege('remesas_handoff',
        'public.cerebro_registrar_derivacion(uuid,text,text,boolean)', 'EXECUTE') THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 4] remesas_handoff lost cerebro_registrar_derivacion';
    END IF;
    IF has_function_privilege('remesas_handoff',
        'public.cerebro_liberar_derivacion_ambigua(uuid)', 'EXECUTE')
       OR has_function_privilege('remesas_handoff',
        'public.cerebro_auditoria_semantica_registrar(text,jsonb)', 'EXECUTE')
       OR has_function_privilege('remesas_handoff',
        'public.cerebro_telemetria_registrar(text,jsonb)', 'EXECUTE') THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 5] remesas_handoff gained EXECUTE on another function';
    END IF;
  ELSE
    RAISE NOTICE 'remesas_handoff absent: cases 4-5 skipped';
  END IF;

  IF v_fails > 0 THEN RAISE EXCEPTION 'cerebro-authenticated-execute-lockdown: % case(s) FAILED', v_fails; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
