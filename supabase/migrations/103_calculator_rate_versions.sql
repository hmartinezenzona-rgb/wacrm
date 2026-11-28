-- =====================================================================
-- 103 — Calculator rate versions (append-only global rate history)
--
-- PURPOSE: the four global rates the calculator runs on (cup_global_rate,
-- usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup) live today in
-- `remittance_calculator_documents` — ONE mutable row per account (095).
-- Editing a rate there silently rewrites the number every past reading
-- was taken with, so there is no way to answer "what rate was this remesa
-- actually completed at?".
--
-- This migration makes rate history a fact: every edit appends a new
-- immutable version, and 104's ledger feed stamps the version id onto each
-- entry at the moment the remesa completes. Later versions can never reach
-- back and change a stored entry.
--
-- WHY NOT JUST ADD A HISTORY TABLE NEXT TO THE MUTABLE ROW: two writers of
-- the same truth always drift. `remittance_calculator_documents` keeps
-- `raw_text` and `period_label` (the manual shorthand document, which is
-- genuinely mutable scratch), and loses the four rate columns in slice 11's
-- cutover. Until then they stay in place, unread by anything this migration
-- or 104 adds, so a rollback of 103/104 leaves the 095 screen working.
--
-- NO SEED, NO DEFAULTS (design decision 9): this migration does NOT copy
-- `remittance_calculator_documents.cup_global_rate` (which carries a
-- meaningless `DEFAULT 3.0` from 095) into a first version. An account with
-- no version on file has NO rates, and 104 marks its entries
-- `verified_pending` with the missing inputs named rather than computing
-- against a number nobody chose. An admin enters the real rates once, at
-- cutover. A wrong rate silently applied to money is worse than a pending
-- row that says what it needs.
--
-- AUTHORIZATION: reads are member-wide (the calculator screen shows the
-- current rates to anyone who can open it); writes are admin+ only, through
-- `crm_set_calculator_rates` with the caller's own JWT — never a service
-- role client. EXECUTE is revoked from PUBLIC/anon.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- 1. The append-only table
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS calculator_rate_versions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id       uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,

  -- All four nullable and defaultless on purpose: an account may know its
  -- USDT rates before its CUP rate, and a NULL here is the signal 104 uses
  -- to hold an entry in `verified_pending` instead of guessing.
  cup_global_rate  numeric,
  usdt_buy_gyd     numeric,
  usdt_sell_gyd    numeric,
  usdt_sell_cup    numeric,

  set_by           uuid REFERENCES auth.users(id),
  -- clock_timestamp(), not now(): now() freezes at transaction start, so
  -- two versions appended in one transaction (what the staging assertions
  -- do) would tie for "latest" and make `calculator_rates_vigentes`
  -- non-deterministic.
  effective_at     timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT calculator_rate_versions_cup_global_rate_chk
    CHECK (cup_global_rate IS NULL OR (cup_global_rate > 0 AND cup_global_rate < 1e9)),
  CONSTRAINT calculator_rate_versions_usdt_buy_gyd_chk
    CHECK (usdt_buy_gyd IS NULL OR (usdt_buy_gyd > 0 AND usdt_buy_gyd < 1e9)),
  CONSTRAINT calculator_rate_versions_usdt_sell_gyd_chk
    CHECK (usdt_sell_gyd IS NULL OR (usdt_sell_gyd > 0 AND usdt_sell_gyd < 1e9)),
  CONSTRAINT calculator_rate_versions_usdt_sell_cup_chk
    CHECK (usdt_sell_cup IS NULL OR (usdt_sell_cup > 0 AND usdt_sell_cup < 1e9)),

  -- An all-NULL version says nothing and would still shadow the version
  -- before it as "latest".
  CONSTRAINT calculator_rate_versions_not_empty_chk
    CHECK (num_nonnulls(cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup) > 0)
);

CREATE INDEX IF NOT EXISTS calculator_rate_versions_account_effective_idx
  ON calculator_rate_versions (account_id, effective_at DESC, id DESC);

-- ---------------------------------------------------------------------
-- 2. Append-only enforcement
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION calculator_rate_versions_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION
    'calculator_rate_versions is append-only: % rejected. Insert a new version instead.',
    TG_OP
    USING ERRCODE = 'insufficient_privilege';
END;
$$;

DROP TRIGGER IF EXISTS calculator_rate_versions_append_only ON calculator_rate_versions;
CREATE TRIGGER calculator_rate_versions_append_only
  BEFORE UPDATE OR DELETE ON calculator_rate_versions
  FOR EACH ROW EXECUTE FUNCTION calculator_rate_versions_append_only();

ALTER TABLE calculator_rate_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS calculator_rate_versions_select ON calculator_rate_versions;
CREATE POLICY calculator_rate_versions_select ON calculator_rate_versions
  FOR SELECT USING (is_account_member(account_id));

-- No write policy: the only write path is crm_set_calculator_rates, a
-- SECURITY DEFINER function that bypasses RLS and does its own role check.

-- ---------------------------------------------------------------------
-- 3. Current rates
-- ---------------------------------------------------------------------

-- The newest version for an account, or no row when none was ever set.
-- Used by 104's feed trigger and by the calculator read path. STABLE, not
-- IMMUTABLE: the answer changes as versions are appended.
CREATE OR REPLACE FUNCTION calculator_rates_vigentes(p_account_id uuid)
RETURNS calculator_rate_versions
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT v.*
    FROM calculator_rate_versions v
   WHERE v.account_id = p_account_id
   ORDER BY v.effective_at DESC, v.id DESC
   LIMIT 1;
$$;

-- ---------------------------------------------------------------------
-- 4. crm_set_calculator_rates — the only write path
-- ---------------------------------------------------------------------

-- p_rates carries only the rates being changed, keyed by column name:
--   {"cup_global_rate": 3.2, "usdt_sell_cup": 410}
-- Unspecified rates carry forward from the current version, so an admin who
-- only knows the new CUP rate does not have to retype the other three (and
-- cannot blank them by omission). Passing an explicit JSON null clears a
-- rate back to "unknown".
--
-- p_expected_version_id is the version the caller believed was current when
-- they opened the form. A mismatch means someone else appended in between:
-- the write is refused with 40001 rather than silently burying their edit.
-- Pass NULL to skip the check (first write, or a deliberate override).
CREATE OR REPLACE FUNCTION crm_set_calculator_rates(
  p_account_id          uuid,
  p_rates               jsonb,
  p_expected_version_id uuid DEFAULT NULL
) RETURNS calculator_rate_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current  calculator_rate_versions;
  v_new      calculator_rate_versions;
  v_key      text;
  v_value    numeric;
BEGIN
  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT is_account_member(p_account_id, 'admin') THEN
    RAISE EXCEPTION 'not authorized to set calculator rates' USING ERRCODE = '42501';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' OR p_rates = '{}'::jsonb THEN
    RAISE EXCEPTION 'no rates provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_rates) LOOP
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup') THEN
      RAISE EXCEPTION 'unknown rate: %', v_key USING ERRCODE = '22023';
    END IF;

    IF jsonb_typeof(p_rates -> v_key) NOT IN ('number', 'null') THEN
      RAISE EXCEPTION 'rate % must be a number or null', v_key USING ERRCODE = '22023';
    END IF;

    v_value := (p_rates ->> v_key)::numeric;
    IF v_value IS NOT NULL AND (v_value <= 0 OR v_value >= 1e9) THEN
      RAISE EXCEPTION 'rate % must be greater than 0 and less than 1e9', v_key
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Lock the account's rate history so two concurrent admins cannot both
  -- read the same "current" and both append on top of it.
  PERFORM 1 FROM accounts WHERE id = p_account_id FOR UPDATE;

  v_current := calculator_rates_vigentes(p_account_id);

  IF p_expected_version_id IS NOT NULL
     AND p_expected_version_id IS DISTINCT FROM v_current.id THEN
    RAISE EXCEPTION 'calculator rates changed concurrently, reload and retry'
      USING ERRCODE = '40001';
  END IF;

  INSERT INTO calculator_rate_versions (
    account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, set_by
  ) VALUES (
    p_account_id,
    CASE WHEN p_rates ? 'cup_global_rate'
         THEN (p_rates ->> 'cup_global_rate')::numeric ELSE v_current.cup_global_rate END,
    CASE WHEN p_rates ? 'usdt_buy_gyd'
         THEN (p_rates ->> 'usdt_buy_gyd')::numeric ELSE v_current.usdt_buy_gyd END,
    CASE WHEN p_rates ? 'usdt_sell_gyd'
         THEN (p_rates ->> 'usdt_sell_gyd')::numeric ELSE v_current.usdt_sell_gyd END,
    CASE WHEN p_rates ? 'usdt_sell_cup'
         THEN (p_rates ->> 'usdt_sell_cup')::numeric ELSE v_current.usdt_sell_cup END,
    auth.uid()
  )
  RETURNING * INTO v_new;

  RETURN v_new;
END;
$$;

REVOKE ALL ON FUNCTION crm_set_calculator_rates(uuid, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_set_calculator_rates(uuid, jsonb, uuid) TO authenticated;

REVOKE ALL ON FUNCTION calculator_rates_vigentes(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION calculator_rates_vigentes(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 5. Documentation
-- ---------------------------------------------------------------------

COMMENT ON TABLE calculator_rate_versions IS
  'Append-only history of the four global calculator rates. The newest row '
  'per account is the current rate set; 104 stamps its id onto every ledger '
  'entry so a completed remesa keeps the rate it was actually priced at. '
  'UPDATE and DELETE are rejected by trigger. No defaults: an account with '
  'no row has no rates, and entries wait in verified_pending.';

COMMENT ON COLUMN calculator_rate_versions.effective_at IS
  'clock_timestamp() at insert — the tiebreaker for "latest" alongside id.';

COMMENT ON FUNCTION calculator_rates_vigentes(uuid) IS
  'Newest rate version for an account, or no row when none was ever set.';

COMMENT ON FUNCTION crm_set_calculator_rates(uuid, jsonb, uuid) IS
  'Admin+ only. Appends a rate version, carrying forward every rate absent '
  'from p_rates. Raises 40001 when p_expected_version_id is not the current '
  'version (someone else edited first), 42501 for non-admins, 22023 for an '
  'unknown key or a non-positive rate.';
