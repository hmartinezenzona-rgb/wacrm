-- operations-realtime.sql — self-reverting assertion for
-- 171_operations_realtime_publication.sql
--
-- Proves the Phase 6.5 fix at the only level a migration this small has:
-- that `remittance_operations` is actually in the `supabase_realtime`
-- publication (so a `postgres_changes` subscription on it can fire at all),
-- and that the account-scoped SELECT policy the table already had is still
-- exactly what will gate which rows each subscriber's events carry
-- (regression check — 171 must not touch RLS).
--
-- RED (before 171 is applied): the publication-membership check FAILS —
--   the table isn't there yet.
-- GREEN (after 171 is applied): both checks PASS.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker exec -i wacrm-ensayo psql -U supabase_admin -d postgres,
-- wrapped in BEGIN ... \i (or paste) 171 ... \i this file ... ROLLBACK).
-- Never COMMIT. Never run against production. No fixtures needed — this
-- checks catalog state, not row data.

SAVEPOINT operations_realtime;

DO $$
DECLARE
  v_in_publication boolean;
  v_has_select_policy boolean;
  v_fail_count integer := 0;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'remittance_operations'
  ) INTO v_in_publication;

  IF NOT v_in_publication THEN
    RAISE WARNING 'FAIL: remittance_operations is not in the supabase_realtime publication';
    v_fail_count := v_fail_count + 1;
  ELSE
    RAISE NOTICE 'PASS: remittance_operations is in the supabase_realtime publication';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'remittance_operations'
      AND policyname = 'remittance_operations_select'
      AND cmd = 'SELECT'
  ) INTO v_has_select_policy;

  IF NOT v_has_select_policy THEN
    RAISE WARNING 'FAIL: remittance_operations_select SELECT policy is missing (RLS regression)';
    v_fail_count := v_fail_count + 1;
  ELSE
    RAISE NOTICE 'PASS: remittance_operations_select SELECT policy is still present (RLS unchanged)';
  END IF;

  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'operations-realtime: % check(s) FAILED', v_fail_count;
  END IF;

  RAISE NOTICE 'operations-realtime: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT operations_realtime;
