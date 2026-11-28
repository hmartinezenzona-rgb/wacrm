-- Assertion for 387 (self-reverting): anon loses EXECUTE on seven internal
-- SECURITY DEFINER functions; authenticated and service_role keep theirs;
-- peek_invitation stays anonymous on purpose.
--
--   1 anon cannot EXECUTE any of the seven
--   2 authenticated keeps EXECUTE on all seven
--   3 service_role keeps EXECUTE on all seven
--   4 peek_invitation is still executable by anon (migration 019 contract)
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
    'public.cerebro_telemetria_registrar(text,jsonb)',
    'public.cerebro_combo_en_curso(uuid)',
    'public.cerebro_tasa_usd_mxn()',
    'public.cerebro_tasa_usd_mxn_info()'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_sigs LOOP
    IF has_function_privilege('anon', v_sig, 'EXECUTE') THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 1] anon can EXECUTE %', v_sig;
    END IF;
    IF NOT has_function_privilege('authenticated', v_sig, 'EXECUTE') THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 2] authenticated lost EXECUTE on %', v_sig;
    END IF;
    IF NOT has_function_privilege('service_role', v_sig, 'EXECUTE') THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 3] service_role lost EXECUTE on %', v_sig;
    END IF;
  END LOOP;

  IF NOT has_function_privilege('anon', 'public.peek_invitation(text)', 'EXECUTE') THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 4] peek_invitation lost its anonymous access';
  END IF;

  IF v_fails > 0 THEN RAISE EXCEPTION 'cerebro-anon-execute-lockdown: % case(s) FAILED', v_fails; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
