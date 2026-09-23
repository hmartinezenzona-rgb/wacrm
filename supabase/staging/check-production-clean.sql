-- check-production-clean.sql — task 1.1c (human-run, READ-ONLY, PRODUCTION ONLY)
--
-- Confirms production has never been contaminated by staging-only
-- tooling: no staging_*-prefixed relation, function/procedure, trigger
-- or schema exists, and no "test-receipts" storage bucket exists. This
-- is a precondition for the Slice 11 production cutover (task 11.5) —
-- if any check below FAILs, STOP and investigate before applying
-- anything to production.
--
-- HOW TO RUN: paste this whole file into the production SQL editor
-- (Supabase dashboard, project hqztotshnlzaiziwjyzh) and execute it as
-- one statement. It is self-contained — opens its own read-only
-- transaction and always rolls back at the end — so it cannot write
-- anything to production even if a check here were wrong.
--
-- Never run this against staging by mistake — it exists specifically
-- to gate the production cutover (11.5) and has no reason to run
-- anywhere else. (As of 2026-09-21, staging happens to PASS this too:
-- the staging_* test-tooling described in the original Slice 1 plan —
-- S001's staging_test_runs/staging_test_markers — was never actually
-- implemented, so there is nothing staging_-prefixed there to detect.
-- Do not read a staging PASS as evidence this script works; it was
-- verified against staging only to confirm it executes without a SQL
-- error, not to exercise its FAIL path.)
--
-- Scope note: this repo's entire migration history (000-114) only
-- ever creates objects in the `public` schema, so that is what this
-- checks. If a future migration starts using another schema, extend
-- the queries below accordingly.

BEGIN;
SET TRANSACTION READ ONLY;

DO $$
DECLARE
  v_fail_count integer := 0;
  v_count      integer;
  v_names      text;
BEGIN
  -- 1. Relations (tables, views, etc.) named staging_*
  SELECT count(*), string_agg(relname, ', ' ORDER BY relname)
    INTO v_count, v_names
    FROM pg_catalog.pg_class
   WHERE relname LIKE 'staging\_%' ESCAPE '\'
     AND relnamespace = 'public'::regnamespace;
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [pg_class] % staging_* relation(s) found in production: %', v_count, v_names;
  ELSE
    RAISE NOTICE 'PASS [pg_class] no staging_* relations in public';
  END IF;

  -- 2. Functions/procedures named staging_*
  SELECT count(*), string_agg(p.proname, ', ' ORDER BY p.proname)
    INTO v_count, v_names
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
   WHERE p.proname LIKE 'staging\_%' ESCAPE '\'
     AND n.nspname = 'public';
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [pg_proc] % staging_* function(s)/procedure(s) found in production: %', v_count, v_names;
  ELSE
    RAISE NOTICE 'PASS [pg_proc] no staging_* functions/procedures in public';
  END IF;

  -- 3. Triggers named staging_* (excluding internal constraint triggers)
  SELECT count(*), string_agg(t.tgname, ', ' ORDER BY t.tgname)
    INTO v_count, v_names
    FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
   WHERE t.tgname LIKE 'staging\_%' ESCAPE '\'
     AND NOT t.tgisinternal
     AND c.relnamespace = 'public'::regnamespace;
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [pg_trigger] % staging_* trigger(s) found in production: %', v_count, v_names;
  ELSE
    RAISE NOTICE 'PASS [pg_trigger] no staging_* triggers in public';
  END IF;

  -- 4. Schemas/namespaces named staging_*
  SELECT count(*), string_agg(nspname, ', ' ORDER BY nspname)
    INTO v_count, v_names
    FROM pg_catalog.pg_namespace
   WHERE nspname LIKE 'staging\_%' ESCAPE '\';
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [pg_namespace] % staging_* schema(s) found in production: %', v_count, v_names;
  ELSE
    RAISE NOTICE 'PASS [pg_namespace] no staging_* schemas';
  END IF;

  -- 5. The "test-receipts" storage bucket
  SELECT count(*) INTO v_count
    FROM storage.buckets
   WHERE id = 'test-receipts' OR name = 'test-receipts';
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [storage.buckets] a "test-receipts" bucket exists in production';
  ELSE
    RAISE NOTICE 'PASS [storage.buckets] no test-receipts bucket';
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'check-production-clean: % check(s) FAILED — production is NOT clean; do not proceed with the cutover (task 11.5) until this is resolved', v_fail_count;
  END IF;

  RAISE NOTICE 'check-production-clean: ALL PASS — production has no staging-only artifacts';
END $$;

ROLLBACK;
