-- Assertion for 386 (self-reverting): the anonymous insert hole on messages is
-- closed without breaking authenticated writes.
--   1 the permissive policy "Service role can insert messages" no longer exists
--   2 anon cannot INSERT on public.messages
--   3 anon cannot UPDATE or DELETE on public.messages
--   4 authenticated still has INSERT (messages_modify scopes it by account)
--   5 RLS stays enabled on public.messages
--   6 service_role keeps BYPASSRLS (webhook inserts do not need a policy)
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE v_fails int := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE schemaname = 'public' AND tablename = 'messages'
                AND policyname = 'Service role can insert messages') THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 1] permissive policy still exists';
  END IF;
  IF has_table_privilege('anon', 'public.messages', 'INSERT') THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 2] anon still has INSERT on messages';
  END IF;
  IF has_table_privilege('anon', 'public.messages', 'UPDATE')
     OR has_table_privilege('anon', 'public.messages', 'DELETE') THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 3] anon still has UPDATE or DELETE on messages';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.messages', 'INSERT') THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 4] authenticated lost INSERT on messages';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.messages'::regclass) THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 5] RLS is not enabled on messages';
  END IF;
  IF NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'service_role') THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 6] service_role does not have BYPASSRLS';
  END IF;
  IF v_fails > 0 THEN RAISE EXCEPTION 'messages-insert-lockdown: % case(s) FAILED', v_fails; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
