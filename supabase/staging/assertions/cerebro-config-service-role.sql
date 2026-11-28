-- Assertion for 270 (self-reverting): the service role can read and write cerebro_config, and the grant does not
-- reach anon through this migration (RLS stays enabled).
--   1 service_role SELECT, INSERT, UPDATE on cerebro_config
--   2 RLS still enabled on cerebro_config
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE v_fails int := 0;
BEGIN
  IF NOT (has_table_privilege('service_role', 'public.cerebro_config', 'SELECT')
          AND has_table_privilege('service_role', 'public.cerebro_config', 'INSERT')
          AND has_table_privilege('service_role', 'public.cerebro_config', 'UPDATE')) THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 1] service_role lacks SELECT/INSERT/UPDATE on cerebro_config';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.cerebro_config'::regclass) THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 2] RLS is not enabled on cerebro_config';
  END IF;
  IF v_fails > 0 THEN RAISE EXCEPTION 'cerebro-config-service-role: % case(s) FAILED', v_fails; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
