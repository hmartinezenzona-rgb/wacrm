-- calculator-entries-realtime.sql — self-reverting assertion for
-- 145_calculator_entries_realtime.sql
--
-- Proves the B4.2 fix at the only level a migration this small has: that
-- `remittance_calculator_entries` is actually in the `supabase_realtime`
-- publication (so a `postgres_changes` subscription on it can fire at
-- all), and that the account-scoped SELECT policy 106 already gave the
-- table is still exactly what will gate which rows each subscriber's
-- events carry (regression check — 145 must not touch RLS).
--
-- RED (before 145 is applied): the publication-membership check FAILS —
--   the table isn't there yet.
-- GREEN (after 145 is applied): both checks PASS.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker exec -i wacrm-ensayo psql -U supabase_admin -d postgres,
-- wrapped in BEGIN ... \i (or paste) 145 ... \i this file ... ROLLBACK).
-- Never COMMIT. Never run against production. No fixtures needed — this
-- checks catalog state, not row data.

SAVEPOINT calculator_entries_realtime;

DO $$
DECLARE
  v_in_publication boolean;
  v_has_select_policy boolean;
  v_fail_count integer := 0;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'remittance_calculator_entries'
  ) INTO v_in_publication;

  IF NOT v_in_publication THEN
    RAISE WARNING 'FAIL: remittance_calculator_entries is not in the supabase_realtime publication';
    v_fail_count := v_fail_count + 1;
  ELSE
    RAISE NOTICE 'PASS: remittance_calculator_entries is in the supabase_realtime publication';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'remittance_calculator_entries'
      AND policyname = 'remittance_calculator_entries_select'
      AND cmd = 'SELECT'
  ) INTO v_has_select_policy;

  IF NOT v_has_select_policy THEN
    RAISE WARNING 'FAIL: remittance_calculator_entries_select SELECT policy is missing (106 regression)';
    v_fail_count := v_fail_count + 1;
  ELSE
    RAISE NOTICE 'PASS: remittance_calculator_entries_select SELECT policy is still present (106 unchanged)';
  END IF;

  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'calculator-entries-realtime: % check(s) FAILED', v_fail_count;
  END IF;

  RAISE NOTICE 'calculator-entries-realtime: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT calculator_entries_realtime;
