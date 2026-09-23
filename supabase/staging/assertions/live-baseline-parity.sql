-- live-baseline-parity.sql — self-reverting assertion that
-- 109_capture_live_cerebro_functions.sql is a byte-identical capture of
-- the seven live cerebro_* functions: applying 109 must not change a
-- single byte of any of their pg_get_functiondef() output, and none of
-- the seven may go missing.
--
-- HOW THIS FILE WORKS — it is run TWICE, in the same still-open
-- transaction, with 109 applied in between. It decides which of its two
-- roles to play by checking whether the temp table zz_baseline_before
-- already holds rows (temp tables live for the session/transaction, so
-- this survives across the two \i's below):
--
--   1st run (BEFORE 109 is applied)  -> CAPTURE mode. Records
--     md5(pg_get_functiondef(oid)) for each of the seven functions into
--     zz_baseline_before. RAISEs immediately if fewer than 7 exist yet —
--     there is nothing sane to compare against, so this is a hard setup
--     failure, not a pass/fail expectation.
--
--   2nd run (AFTER 109 is applied, same transaction) -> COMPARE mode.
--     Recomputes the same hash for each of the seven functions and
--     compares it against what CAPTURE mode recorded: RAISE WARNING
--     'FAIL [<function>] ...' per mismatch or per function that went
--     missing, RAISE NOTICE 'PASS [<function>] ...' per match, then a
--     final RAISE EXCEPTION if any expectation failed — same v_fail_count
--     / WARNING / NOTICE / final-EXCEPTION shape as delivery.sql.
--
-- WHY NO SAVEPOINT (deliberate difference from delivery.sql /
-- deposit-review.sql / guard12-matrix.sql): those assertions build their
-- own fixtures and revert them with ROLLBACK TO SAVEPOINT so they leave no
-- trace even inside a larger shared transaction. This assertion is the
-- opposite: its whole point is a piece of state (the CAPTURE-mode hashes)
-- that MUST survive from before 109 to after it, inside one transaction.
-- Wrapping either run in SAVEPOINT/ROLLBACK TO SAVEPOINT would erase that
-- state before the second run ever sees it. The caller's own outer
-- ROLLBACK (below) already guarantees nothing here is ever committed.
--
-- EXACT RUN ORDER (never COMMIT, never run against production):
--
--   cat <<'SQL' | docker run --rm -i --env-file .env.staging \
--     -v "$PWD:/repo:ro" -w /repo postgres:16-alpine sh -c \
--     'psql "$CRM_STAGING_DATABASE_URL" -X -q -f -'
--   BEGIN;
--   \i supabase/staging/assertions/live-baseline-parity.sql
--   \i supabase/migrations/109_capture_live_cerebro_functions.sql
--   \i supabase/staging/assertions/live-baseline-parity.sql
--   ROLLBACK;
--   SQL
--
-- To prove this assertion can actually fail: between the two \i's above,
-- also run a deliberately different CREATE OR REPLACE FUNCTION for one of
-- the seven (e.g. cerebro_objetivo_cerrar, only 11 lines) inside its own
-- SAVEPOINT/ROLLBACK TO SAVEPOINT, then confirm the second run reports
-- FAIL for exactly that function and PASS for the other six.

DO $$
DECLARE
  v_baseline_count integer;
  v_captured       integer;
  v_fail_count     integer := 0;
  v_row            record;
  v_now_hash       text;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS zz_baseline_before (
    proname  text PRIMARY KEY,
    def_hash text NOT NULL
  );

  SELECT count(*) INTO v_baseline_count FROM zz_baseline_before;

  IF v_baseline_count = 0 THEN
    -- ================== CAPTURE mode (run BEFORE 109) ==================
    INSERT INTO zz_baseline_before (proname, def_hash)
    SELECT p.proname, md5(pg_get_functiondef(p.oid))
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN (
         'cerebro_registrar_deposito',
         'cerebro_cruzar_deposito',
         'cerebro_cruzar_depositos',
         'cerebro_saldo_envio',
         'cerebro_objetivo_atar',
         'cerebro_objetivo_cerrar',
         'cerebro_es_revendedor'
       );

    SELECT count(*) INTO v_captured FROM zz_baseline_before;
    IF v_captured <> 7 THEN
      RAISE EXCEPTION 'live-baseline-parity: expected to capture 7 baseline definitions BEFORE applying 109, found % — one or more of the seven cerebro_* functions is missing on this database', v_captured;
    END IF;

    RAISE NOTICE 'live-baseline-parity: CAPTURE mode — recorded % baseline definition hash(es) into zz_baseline_before. Now apply 109, then run this file again to compare.', v_captured;

  ELSE
    -- ================== COMPARE mode (run AFTER 109) ===================
    FOR v_row IN SELECT proname, def_hash FROM zz_baseline_before ORDER BY proname LOOP
      SELECT md5(pg_get_functiondef(p.oid)) INTO v_now_hash
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = v_row.proname;

      IF v_now_hash IS NULL THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [%] function is missing after applying 109 (it existed before)', v_row.proname;
      ELSIF v_now_hash IS DISTINCT FROM v_row.def_hash THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [%] definition changed by 109 — before hash %, after hash %', v_row.proname, v_row.def_hash, v_now_hash;
      ELSE
        RAISE NOTICE 'PASS [%] definition unchanged by 109 (hash %)', v_row.proname, v_now_hash;
      END IF;
    END LOOP;

    IF v_fail_count > 0 THEN
      RAISE EXCEPTION 'live-baseline-parity: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
    END IF;

    RAISE NOTICE 'live-baseline-parity: ALL PASS (7 expectations) — 109 changed not one byte of any of the seven live definitions';
  END IF;
END $$;
