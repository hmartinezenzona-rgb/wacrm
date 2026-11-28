-- live-tables-baseline.sql — self-reverting assertion that
-- 112_capture_live_cerebro_tables.sql is a faithful structural capture of
-- the three live cerebro_* tables: applying 112 must not change one byte
-- of any of their structural signatures, and none of the three may go
-- missing.
--
-- A table's "signature" is an md5 over:
--   (a) an ordered string_agg, by attnum, of
--       attname || attnotnull || format_type(atttypid, atttypmod)
--       || coalesce(default_expr, '') for every live (non-dropped) column,
--   (b) '|' as a separator, then
--   (c) an ordered string_agg, by conname, of pg_get_constraintdef() for
--       every constraint on the table (primary key, unique, check, FK).
-- Column order, types, nullability, defaults, and every constraint all
-- feed one hash per table, so any structural drift changes it. Indexes
-- that back a PRIMARY KEY / UNIQUE constraint are already covered via (c);
-- these three tables carry no other indexes live (verified — see this
-- task's report).
--
-- HOW THIS FILE WORKS — same idiom as live-baseline-parity.sql: it is run
-- TWICE, in the same still-open transaction, with 112 applied in between.
-- It decides which of its two roles to play by checking whether the temp
-- table zz_table_baseline_before already holds rows (temp tables live for
-- the session/transaction, so this survives across the two \i's below):
--
--   1st run (BEFORE 112 is applied)  -> CAPTURE mode. Records the
--     signature above for each of the three tables into
--     zz_table_baseline_before. RAISEs immediately if fewer than 3 exist
--     yet — there is nothing sane to compare against, so this is a hard
--     setup failure, not a pass/fail expectation.
--
--   2nd run (AFTER 112 is applied, same transaction) -> COMPARE mode.
--     Recomputes the same signature for each of the three tables and
--     compares it against what CAPTURE mode recorded: RAISE WARNING
--     'FAIL [<table>] ...' per mismatch or per table that went missing,
--     RAISE NOTICE 'PASS [<table>] ...' per match, then a final RAISE
--     EXCEPTION if any expectation failed.
--
-- WHY NO SAVEPOINT (deliberate — same reasoning as live-baseline-parity.sql):
-- this assertion's whole point is a piece of state (the CAPTURE-mode
-- hashes) that MUST survive from before 112 to after it, inside one
-- transaction. Wrapping either run in SAVEPOINT/ROLLBACK TO SAVEPOINT
-- would erase that state before the second run ever sees it. The caller's
-- own outer ROLLBACK (below) already guarantees nothing here is ever
-- committed.
--
-- EXACT RUN ORDER (never COMMIT, never run against production):
--
--   cat <<'SQL' | docker run --rm -i --env-file .env.staging \
--     -v "$PWD:/repo:ro" -w /repo postgres:16-alpine sh -c \
--     'psql "$CRM_STAGING_DATABASE_URL" -X -q -f -'
--   BEGIN;
--   \i supabase/staging/assertions/live-tables-baseline.sql
--   \i supabase/migrations/112_capture_live_cerebro_tables.sql
--   \i supabase/staging/assertions/live-tables-baseline.sql
--   ROLLBACK;
--   SQL
--
-- To prove this assertion can actually fail: between the two \i's above,
-- also run a deliberately different structural change to one of the three
-- (e.g. `ALTER TABLE cerebro_revendedores ADD COLUMN zz_probe text;`)
-- inside its own SAVEPOINT/ROLLBACK TO SAVEPOINT, then confirm the second
-- run reports FAIL for exactly that table and PASS for the other two.

DO $$
DECLARE
  v_baseline_count integer;
  v_captured       integer;
  v_fail_count     integer := 0;
  v_row            record;
  v_now_hash       text;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS zz_table_baseline_before (
    relname  text PRIMARY KEY,
    sig_hash text NOT NULL
  );

  SELECT count(*) INTO v_baseline_count FROM zz_table_baseline_before;

  IF v_baseline_count = 0 THEN
    -- ================== CAPTURE mode (run BEFORE 112) ==================
    INSERT INTO zz_table_baseline_before (relname, sig_hash)
    SELECT c.relname,
           md5(
             coalesce((
               SELECT string_agg(
                        a.attname || a.attnotnull::text
                        || format_type(a.atttypid, a.atttypmod)
                        || coalesce(pg_get_expr(ad.adbin, ad.adrelid), ''),
                        ',' ORDER BY a.attnum)
                 FROM pg_attribute a
                 LEFT JOIN pg_attrdef ad
                        ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
                WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
             ), '')
             || '|' ||
             coalesce((
               SELECT string_agg(pg_get_constraintdef(con.oid), ',' ORDER BY con.conname)
                 FROM pg_constraint con
                WHERE con.conrelid = c.oid
             ), '')
           )
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname IN ('cerebro_objetivo_envio', 'cerebro_revendedores', 'cerebro_servicios');

    SELECT count(*) INTO v_captured FROM zz_table_baseline_before;
    IF v_captured <> 3 THEN
      RAISE EXCEPTION 'live-tables-baseline: expected to capture 3 baseline signature(s) BEFORE applying 112, found % — one or more of the three cerebro_* tables is missing on this database', v_captured;
    END IF;

    RAISE NOTICE 'live-tables-baseline: CAPTURE mode — recorded % baseline signature(s) into zz_table_baseline_before. Now apply 112, then run this file again to compare.', v_captured;

  ELSE
    -- ================== COMPARE mode (run AFTER 112) ===================
    FOR v_row IN SELECT relname, sig_hash FROM zz_table_baseline_before ORDER BY relname LOOP
      SELECT md5(
               coalesce((
                 SELECT string_agg(
                          a.attname || a.attnotnull::text
                          || format_type(a.atttypid, a.atttypmod)
                          || coalesce(pg_get_expr(ad.adbin, ad.adrelid), ''),
                          ',' ORDER BY a.attnum)
                   FROM pg_attribute a
                   LEFT JOIN pg_attrdef ad
                          ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
                  WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
               ), '')
               || '|' ||
               coalesce((
                 SELECT string_agg(pg_get_constraintdef(con.oid), ',' ORDER BY con.conname)
                   FROM pg_constraint con
                  WHERE con.conrelid = c.oid
               ), '')
             )
        INTO v_now_hash
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = v_row.relname;

      IF v_now_hash IS NULL THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [%] table is missing after applying 112 (it existed before)', v_row.relname;
      ELSIF v_now_hash IS DISTINCT FROM v_row.sig_hash THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [%] structural signature changed by 112 — before hash %, after hash %', v_row.relname, v_row.sig_hash, v_now_hash;
      ELSE
        RAISE NOTICE 'PASS [%] structural signature unchanged by 112 (hash %)', v_row.relname, v_now_hash;
      END IF;
    END LOOP;

    IF v_fail_count > 0 THEN
      RAISE EXCEPTION 'live-tables-baseline: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
    END IF;

    RAISE NOTICE 'live-tables-baseline: ALL PASS (3 expectations) — 112 changed not one byte of any of the three live table signatures';
  END IF;
END $$;
