-- =====================================================================
-- Cutover 2026-09-27 — STEP 3.5 (WRITE): seed the calculator rates for the
-- production account, BEFORE migration 113.
--
-- 113 RISK (production-cutover-2026-09-27.md, found 2026-09-27): 113 turns
-- `tasas` into a VIEW over `calculator_rate_versions` (103). In production
-- that table is born EMPTY by 095/103 — nothing has ever written to it —
-- so the moment 113 runs, `tasas` goes from 4 real rows to zero and the
-- bot has no rate to quote. `crm_set_calculator_rates` (103) is the only
-- write path, but it requires an admin session (`is_account_member(...,
-- 'admin')` + `auth.uid()`), which the SQL editor / this maintenance
-- script cannot supply. This file inserts the equivalent row directly,
-- run as postgres/service_role (BYPASSRLS), between 103 and 113.
--
-- RATES (user-confirmed, odd/tasks/cutover-rates-and-legacy-parity.md):
--   usdt_sell_gyd 260   (-> tasas.moneda='usd'.tasa_cup, what 113's view maps)
--   cup_global_rate 3   (-> tasas.moneda='gyd'.tasa_cup)
--   usdt_buy_gyd 240    (cost side, no `tasas` equivalent — see 113 header)
--   usdt_sell_cup 975   (cost side, no `tasas` equivalent — see 113 header)
-- Matches what `tasas` holds in production today (usd 260, gyd 3) exactly
-- on the two rates 113 reads, so the cutover is a no-op for the bot's
-- quoted numbers, not a real rate change.
--
-- WHY A DIRECT INSERT, NOT crm_set_calculator_rates: that function is
-- SECURITY DEFINER but still requires `is_account_member(p_account_id,
-- 'admin')`, which resolves against `auth.uid()` — NULL for a
-- service-role/postgres maintenance session (096's own header documents
-- this same limitation for n8n). Rather than fabricate a JWT, this script
-- reproduces the exact row 103's table expects (same columns, same
-- CHECK constraints, `set_by` left NULL — no human admin actually typed
-- these numbers into the calculator UI) and leaves an audit trail in this
-- file instead of in `remittance_admin_audit` (that table is for
-- automation-vs-human write conflicts on `remittance_operations`, not
-- calculator rate history — `calculator_rate_versions` IS its own
-- append-only audit trail, per 103's header).
--
-- GUARDS (this file refuses to run rather than guess or duplicate):
--   - `calculator_rate_versions` must already exist (103 applied).
--   - the account must already exist in `accounts`.
--   - the account must NOT already have a version (this is a one-time
--     seed, not a rate update — an existing version means either this
--     script already ran, or a human already used the calculator UI, and
--     either way this script is not the place to add a second version).
--
-- VERIFY (this file, at the end): `calculator_rates_vigentes(account)`
-- returns the row just inserted.
-- POST-113 CHECK (run once 113 is applied): `SELECT * FROM tasas` returns
-- exactly two rows, usd 260 and gyd 3 — see
-- supabase/staging/assertions/ for the shape 113 itself was validated
-- against; this is the same read applied to the seeded row.
--
-- RUN ONCE, between 103 and 113. Idempotent by refusal: a second run
-- raises "already has a calculator rate version" instead of silently
-- appending a duplicate.
-- =====================================================================
BEGIN;

DO $$
DECLARE
  v_account_id  CONSTANT uuid := '465fb4ce-33b6-4473-ad2c-42818772f587';
  v_existing    calculator_rate_versions;
  v_new         calculator_rate_versions;
BEGIN
  IF to_regclass('public.calculator_rate_versions') IS NULL THEN
    RAISE EXCEPTION 'calculator_rate_versions does not exist — apply migration 103 first';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM accounts WHERE id = v_account_id) THEN
    RAISE EXCEPTION 'account % does not exist — nothing to seed', v_account_id;
  END IF;

  SELECT * INTO v_existing FROM calculator_rate_versions WHERE account_id = v_account_id LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'account % already has a calculator rate version (id %) — refusing to add a second one; this script is a one-time seed, not an update',
      v_account_id, v_existing.id;
  END IF;

  INSERT INTO calculator_rate_versions (
    account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, set_by
  ) VALUES (
    v_account_id,
    3,      -- cup_global_rate
    240,    -- usdt_buy_gyd
    260,    -- usdt_sell_gyd
    975,    -- usdt_sell_cup
    NULL    -- no human admin session behind this seed — see header
  )
  RETURNING * INTO v_new;

  RAISE NOTICE 'seeded calculator_rate_versions % for account % (cup_global_rate=%, usdt_buy_gyd=%, usdt_sell_gyd=%, usdt_sell_cup=%)',
    v_new.id, v_account_id, v_new.cup_global_rate, v_new.usdt_buy_gyd, v_new.usdt_sell_gyd, v_new.usdt_sell_cup;
END $$;

-- Verify: the vigente row for the account is exactly what was just seeded.
SELECT account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, set_by, effective_at
  FROM calculator_rates_vigentes('465fb4ce-33b6-4473-ad2c-42818772f587');

COMMIT;

-- =====================================================================
-- POST-113 CHECK (run after migration 113 is applied):
--   SELECT * FROM tasas;
--     -> fecha | tasa_cup | fuente | actualizada_at | moneda
--        today | 260      | calculadora | ... | usd
--        today | 3        | calculadora | ... | gyd
--
-- CORRECTING A WRONG VALUE: there is no undo by DELETE. From the moment
-- migration 103 creates it, `calculator_rate_versions` is append-only
-- (trigger `calculator_rate_versions_append_only`: any UPDATE or DELETE is
-- rejected — verified in the rehearsal). `crm_set_calculator_rates` needs an
-- admin session, unusable from the SQL editor. So a correction is simply a
-- NEW version inserted the same way as below (the newest one wins):
--   INSERT INTO calculator_rate_versions
--     (account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup)
--   VALUES ('465fb4ce-33b6-4473-ad2c-42818772f587', <cup>, <buy>, <sell>, <sell_cup>);
-- =====================================================================
