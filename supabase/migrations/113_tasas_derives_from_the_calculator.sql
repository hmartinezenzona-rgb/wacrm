-- =====================================================================
-- 113 — `tasas` derives from the calculator; it stops being a place a
--        rate can be set
--
-- DECISION (product, not engineering): "Las tasas deben regirse por las
-- que se pongan en la calculadora." The calculator
-- (`calculator_rate_versions`, written only through 103's
-- `crm_set_calculator_rates`) becomes the single source of truth for
-- exchange rates. `tasas` — the legacy table n8n's bot and a few
-- SQL functions read — stops being writable anywhere. From now on it is
-- a VIEW projecting the calculator's current numbers, so setting a rate
-- in the calculator is the only way the bot's quoted rate ever changes.
--
-- WHY THIS WAS SAFE TO DO AS A PURE PROJECTION: nothing writes to
-- `tasas` today. Zero functions INSERT/UPDATE/DELETE it, zero triggers
-- fire on it, zero foreign keys reference it (verified against the live
-- catalog). Its only readers run `SELECT ... FROM tasas`, filtered by
-- `WHERE moneda = 'usd'/'gyd'` and ordered `ORDER BY fecha DESC,
-- actualizada_at DESC LIMIT 1` (or `SELECT DISTINCT ON (moneda) ...
-- ORDER BY moneda, fecha DESC, actualizada_at DESC`) — every one of
-- those keeps working unchanged against a view shaped like the table it
-- replaces.
--
-- THE MAPPING (exactly two of the calculator's four rates have a `tasas`
-- equivalent):
--   tasas.moneda='usd'.tasa_cup  ==  calculator_rate_versions.usdt_sell_gyd  (GYD per USD)
--   tasas.moneda='gyd'.tasa_cup  ==  calculator_rate_versions.cup_global_rate (CUP per GYD)
-- `usdt_buy_gyd` and `usdt_sell_cup` are the calculator's cost side
-- (used for `invertido`/`retorno`) and have no `tasas` row at all — they
-- were never part of what the bot quotes.
--
-- ---------------------------------------------------------------------
-- ACCOUNT CAVEAT — READ THIS BEFORE ADDING A SECOND ACTIVE ACCOUNT
-- ---------------------------------------------------------------------
-- `calculator_rate_versions` is per-account (`account_id`); `tasas` has
-- never had an account column and every reader — the n8n bot especially
-- — queries it with NO account filter at all. The view below therefore
-- resolves across EVERY account by recency (`ORDER BY effective_at
-- DESC`), exactly mirroring the account-blind shape the readers already
-- assume.
--
-- That is honest today: exactly one account
-- (472917ed-fca5-4679-b64c-e76a54089a16) has ever set a rate, so "the
-- newest rate from any account" and "the newest rate from THE account"
-- are the same number. IT WOULD BE WRONG the day a second real account
-- starts setting its own calculator rates — the bot would quote whichever
-- account happened to save last to EVERY customer, including the other
-- account's. Nothing in this migration can fix that without either
-- giving `tasas`'s readers (the n8n workflow, which this migration must
-- not touch) an account to filter by, or accepting that this legacy
-- global rate feed is retired outright. Whoever activates a second
-- account's calculator must revisit this view first.
-- ---------------------------------------------------------------------
--
-- ROLLBACK: ROLLBACK-113-tasas-derives-from-the-calculator.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Preserve the existing rows. `tasas` currently holds 4 real rows
--    (the only historical rate record that exists anywhere) and step 2
--    below destroys the table they live in. Copy them out first.
--
--    Idempotent by construction: tasas_historico's primary key is the
--    same (fecha, moneda) pair `tasas` itself used, so a re-run of this
--    block (e.g. a from-scratch build re-applying every migration) can
--    never double-insert. The copy itself is additionally guarded to
--    only fire while `tasas` is still a real table (relkind 'r') — once
--    step 2 has turned it into a view, re-running this migration is a
--    silent no-op here instead of trying to SELECT historical rows out
--    of the view.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS tasas_historico (
  fecha          date        NOT NULL DEFAULT CURRENT_DATE,
  tasa_cup       numeric     NOT NULL,
  fuente         text        NOT NULL DEFAULT 'whatsapp',
  actualizada_at timestamptz NOT NULL DEFAULT now(),
  moneda         text        NOT NULL DEFAULT 'usd',
  archivado_en   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fecha, moneda)
);

-- Same lockdown posture as the table it archives (see PRIVILEGES below):
-- RLS enabled, no policies, so only postgres/service_role (both
-- BYPASSRLS) can ever see or touch it. anon/authenticated get the
-- default schema-wide grant (see PRIVILEGES) but RLS blocks all of it.
ALTER TABLE tasas_historico ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_class
     WHERE relname = 'tasas' AND relnamespace = 'public'::regnamespace AND relkind = 'r'
  ) THEN
    INSERT INTO tasas_historico (fecha, tasa_cup, fuente, actualizada_at, moneda)
    SELECT fecha, tasa_cup, fuente, actualizada_at, moneda FROM tasas
    ON CONFLICT (fecha, moneda) DO NOTHING;

    EXECUTE 'DROP TABLE tasas';
  END IF;
END $$;


-- ---------------------------------------------------------------------
-- 2. Replace `tasas` with a view onto the calculator.
--
--    One row per rate version per currency, skipping a currency
--    entirely when its underlying rate is NULL — a missing rate must
--    never surface as a `tasa_cup = NULL` row, because every reader's
--    `ORDER BY ... LIMIT 1` would then treat NULL as this period's
--    quote instead of falling back to the last version that actually
--    set one.
--
--    Column names, order and types match the original table exactly
--    (verified against the live catalog): fecha date, tasa_cup numeric,
--    fuente text, actualizada_at timestamptz, moneda text.
--
--    `fuente` is a constant 'calculadora' — the one honest answer now
--    that there is exactly one source. `fecha`/`actualizada_at` both
--    derive from `effective_at`, the calculator's own append timestamp.
--
--    security_invoker = true (defense in depth, not load-bearing today):
--    postgres and service_role both carry BYPASSRLS, so this changes
--    nothing for the only two roles actually granted access (see
--    PRIVILEGES below) — but it means that if anon/authenticated were
--    ever mistakenly granted SELECT on this view in the future, Postgres
--    would evaluate calculator_rate_versions' own RLS policy
--    (`is_account_member`) against THAT caller instead of silently
--    handing them every account's rates through the view owner's
--    bypass. Without it, a view owned by a BYPASSRLS role reads straight
--    through RLS regardless of who queries it — confirmed empirically
--    against staging before writing this migration.
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW tasas
WITH (security_invoker = true) AS
SELECT
  v.effective_at::date AS fecha,
  v.usdt_sell_gyd      AS tasa_cup,
  'calculadora'::text  AS fuente,
  v.effective_at       AS actualizada_at,
  'usd'::text          AS moneda
FROM calculator_rate_versions v
WHERE v.usdt_sell_gyd IS NOT NULL
UNION ALL
SELECT
  v.effective_at::date AS fecha,
  v.cup_global_rate    AS tasa_cup,
  'calculadora'::text  AS fuente,
  v.effective_at       AS actualizada_at,
  'gyd'::text          AS moneda
FROM calculator_rate_versions v
WHERE v.cup_global_rate IS NOT NULL;

COMMENT ON VIEW tasas IS
  'Legacy read shape over calculator_rate_versions (113). No longer a '
  'table: a rate can only be set through crm_set_calculator_rates. '
  'Resolves the current rate across ALL accounts by recency — see the '
  'ACCOUNT CAVEAT in 113''s header before a second account sets its own '
  'calculator rates.';


-- ---------------------------------------------------------------------
-- 3. PRIVILEGES — reproduce the table's effective access, not its
--    nominal one.
--
--    Observed live on staging before this migration:
--      relacl              {postgres=arwdDxtm, anon=arwdDxtm,
--                            authenticated=arwdDxtm, service_role=arwdDxtm}
--                           (all four — this is this project's default
--                           ACL for every new table/view, granted by
--                           ALTER DEFAULT PRIVILEGES, not anything 037
--                           asked for explicitly)
--      relrowsecurity       true
--      relforcerowsecurity  false
--      policies on tasas    0 (none)
--
--    RLS enabled with ZERO policies means the nominal grants above are
--    fiction for anon/authenticated: Postgres denies every row to any
--    role without BYPASSRLS when a table has RLS on and no policy
--    grants anything. Only postgres and service_role (both
--    rolbypassrls = true) ever actually read a row. anon/authenticated
--    have held arwdDxtm on paper and zero rows in practice the whole
--    time.
--
--    A view cannot carry row-level security of its own — RLS attaches
--    only to tables. Confirmed empirically against staging: a plain
--    view owned by postgres bypasses the underlying table's RLS
--    entirely, for ANY querying role, because permission and RLS checks
--    for a non-security_invoker view run as the view's OWNER, not the
--    caller. This project's schema-wide default ACL would otherwise
--    hand this new view SELECT (among other things) to anon and
--    authenticated automatically on creation — which, combined with the
--    view-owner-bypasses-RLS behaviour above, would leak every
--    account's calculator rates to anon/authenticated the moment this
--    migration runs. That is MORE than they had before (they had zero
--    effective rows), so it is revoked explicitly below.
--
--    security_invoker = true (set on the view itself, above) closes
--    that hole a second, independent way: even if anon/authenticated
--    were ever granted SELECT here by mistake, RLS would then evaluate
--    against the actual caller and `is_account_member` would refuse
--    them, not the view owner's BYPASSRLS.
-- ---------------------------------------------------------------------

REVOKE ALL ON tasas FROM PUBLIC, anon, authenticated;
GRANT SELECT ON tasas TO service_role;

REVOKE ALL ON tasas_historico FROM PUBLIC, anon, authenticated;
GRANT SELECT ON tasas_historico TO service_role;

NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- VALIDATED ON STAGING (crm.onlinefreedom.site's isolated DB), inside a
-- transaction that always ends in ROLLBACK — see
-- supabase/staging/assertions/tasas-derives.sql for the exact fixtures
-- and expectations.
--
-- ROLLBACK
--   supabase/migrations/ROLLBACK-113-tasas-derives-from-the-calculator.sql
-- =====================================================================
