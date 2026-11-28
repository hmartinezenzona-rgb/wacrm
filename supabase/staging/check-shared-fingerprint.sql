-- check-shared-fingerprint.sql — task 1.1a (human-run, READ-ONLY, BOTH environments)
--
-- Produces an md5 fingerprint over every non-staging_ schema object
-- (tables, functions/procedures, triggers, views), broken down by
-- category, plus one combined grand-total fingerprint. Cannot compare
-- two databases in one query (no cross-database dblink/postgres_fdw is
-- set up here), so the human runs this file TWICE — once against
-- crm.onlinefreedom.site staging, once against production — and
-- compares the printed fingerprints by eye. A mismatched category
-- fingerprint tells you WHERE the drift is before you dig into WHAT it
-- is; a matching grand-total fingerprint means the two schemas are
-- byte-identical outside staging_* objects.
--
-- Function bodies are read live via pg_get_functiondef(), which always
-- reflects the CURRENT definition regardless of how it got there —
-- including migrations that patch a function body in place (087) or
-- functions that only ever existed live and were never migration-
-- managed (see 109/112's "capture live cerebro objects" migrations).
-- A plain `grep "CREATE OR REPLACE FUNCTION"` search would have missed
-- both cases; this does not.
--
-- HOW TO RUN: paste this whole file into a SQL editor and execute it
-- as one statement. Self-contained — opens its own read-only
-- transaction and always rolls back — so it cannot write anything in
-- either environment.
--
-- Scope note: this repo's entire migration history (000-114) only
-- ever creates objects in the `public` schema, so that is what this
-- checks. If a future migration starts using another schema, extend
-- the queries below accordingly.
--
-- Known, expected source of drift as of 2026-09-21 (see apply-progress
-- for sdd/port-chat-operations-calculator): staging carries an
-- undocumented overload cerebro_resolver_operacion(uuid, text[]) that
-- exists in NO repo migration (found during Slice 5, migration 097's
-- header). If the [functions] category fingerprint differs and this
-- overload is the only reason, that is a documented, already-known gap
-- — not new drift. Anything else differing is new and must be
-- reconciled (task 1.1b) before the cutover (11.5).

BEGIN;
SET TRANSACTION READ ONLY;

WITH tables_fp AS (
  SELECT
    'tables' AS category,
    count(DISTINCT c.relname) AS object_count,
    md5(string_agg(
      c.relname || '|' || a.attname || '|' || format_type(a.atttypid, a.atttypmod)
        || '|' || a.attnotnull || '|' || coalesce(pg_get_expr(d.adbin, d.adrelid), ''),
      '|' ORDER BY c.relname, a.attnum
    )) AS fingerprint
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
  LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
  WHERE c.relkind = 'r'
    AND c.relnamespace = 'public'::regnamespace
    AND c.relname NOT LIKE 'staging\_%' ESCAPE '\'
),
functions_fp AS (
  -- pg_get_functiondef() only works on prokind='f'/'p' (regular
  -- functions/procedures) — aggregates (prokind='a') and window
  -- functions (prokind='w') make it error with "X is an aggregate
  -- function". This project has custom aggregates (avg/sum overloads
  -- on a domain type) in public, fingerprinted separately below.
  SELECT
    'functions' AS category,
    count(*) AS object_count,
    md5(string_agg(pg_get_functiondef(p.oid), '|' ORDER BY p.proname, p.oid::text)) AS fingerprint
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind IN ('f', 'p')
    AND p.proname NOT LIKE 'staging\_%' ESCAPE '\'
),
aggregates_fp AS (
  SELECT
    'aggregates' AS category,
    count(*) AS object_count,
    md5(string_agg(
      p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
        || '|transfn=' || ag.aggtransfn::regproc::text
        || '|finalfn=' || coalesce(ag.aggfinalfn::regproc::text, '-')
        || '|statetype=' || ag.aggtranstype::regtype::text
        || '|initval=' || coalesce(ag.agginitval, ''),
      '|' ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)
    )) AS fingerprint
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_catalog.pg_aggregate ag ON ag.aggfnoid = p.oid
  WHERE n.nspname = 'public'
    AND p.proname NOT LIKE 'staging\_%' ESCAPE '\'
),
triggers_fp AS (
  SELECT
    'triggers' AS category,
    count(*) AS object_count,
    md5(string_agg(pg_get_triggerdef(t.oid), '|' ORDER BY c.relname, t.tgname)) AS fingerprint
  FROM pg_catalog.pg_trigger t
  JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
  WHERE c.relnamespace = 'public'::regnamespace
    AND NOT t.tgisinternal
    AND t.tgname NOT LIKE 'staging\_%' ESCAPE '\'
    AND c.relname NOT LIKE 'staging\_%' ESCAPE '\'
),
views_fp AS (
  SELECT
    'views' AS category,
    count(*) AS object_count,
    md5(string_agg(pg_get_viewdef(c.oid), '|' ORDER BY c.relname)) AS fingerprint
  FROM pg_catalog.pg_class c
  WHERE c.relkind IN ('v', 'm')
    AND c.relnamespace = 'public'::regnamespace
    AND c.relname NOT LIKE 'staging\_%' ESCAPE '\'
),
all_categories AS (
  SELECT * FROM tables_fp
  UNION ALL SELECT * FROM functions_fp
  UNION ALL SELECT * FROM aggregates_fp
  UNION ALL SELECT * FROM triggers_fp
  UNION ALL SELECT * FROM views_fp
)
SELECT category, object_count, fingerprint
  FROM all_categories
UNION ALL
SELECT
  'GRAND TOTAL' AS category,
  (SELECT sum(object_count) FROM all_categories) AS object_count,
  md5(string_agg(fingerprint, '|' ORDER BY category)) AS fingerprint
  FROM all_categories;

ROLLBACK;
