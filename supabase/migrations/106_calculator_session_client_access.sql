-- =====================================================================
-- 106 — The calculator reads and writes as the user, not as an admin
--
-- PURPOSE: `/api/calculadora` is the last CRM route that talks to the
-- database with a service-role client. The design rule for this whole
-- change is the opposite — the CRM writes ONLY through SECURITY DEFINER
-- `crm_*` functions called with the caller's own session client, never an
-- admin client — and that route is the one place it was never applied,
-- because 095 shipped its two tables locked to `service_role`:
--
--   remittance_calculator_documents  RLS on, 0 policies, grants: service_role only
--   remittance_calculator_entries    RLS on, 0 policies, grants: service_role only
--
-- With no policy AND no grant, a logged-in user cannot read a single row,
-- so the route had no choice. This migration gives those tables the same
-- shape every other table in this change already has — members may read,
-- and writes go through one authorized function — so the route can drop
-- the admin client entirely.
--
-- WHY THIS IS NOT JUST TIDINESS: a service-role key is an unrestricted
-- master key for the whole database. Keeping one on a web server to read a
-- rate and a block of text means every bug in that process is a total
-- compromise instead of a scoped one. Removing the need for the key is
-- worth more than any policy written around it. Staging currently has no
-- such key at all, which is why the calculator screen cannot load there —
-- after this, it does not need one.
--
-- ALSO TIGHTENS 103: `calculator_rate_versions` inherited Supabase's
-- default privileges, which hand `anon` and `authenticated` INSERT, UPDATE,
-- DELETE and TRUNCATE. RLS already refuses all of it (there is no write
-- policy) and the append-only trigger refuses the rest, but a money table
-- should not be one forgotten policy away from a stranger writing to it.
-- Only SELECT survives, and only for `authenticated`.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Members may read the ledger and the document
-- ---------------------------------------------------------------------

GRANT SELECT ON remittance_calculator_entries   TO authenticated;
GRANT SELECT ON remittance_calculator_documents TO authenticated;

DROP POLICY IF EXISTS remittance_calculator_entries_select ON remittance_calculator_entries;
CREATE POLICY remittance_calculator_entries_select ON remittance_calculator_entries
  FOR SELECT USING (is_account_member(account_id));

DROP POLICY IF EXISTS remittance_calculator_documents_select ON remittance_calculator_documents;
CREATE POLICY remittance_calculator_documents_select ON remittance_calculator_documents
  FOR SELECT USING (is_account_member(account_id));

-- No write policy on either table. Every write already goes through a
-- SECURITY DEFINER function that does its own role check and bypasses RLS:
-- the feed trigger and crm_resolve_pending_entry for the ledger, and
-- crm_guardar_documento_calculadora below for the document.

-- ---------------------------------------------------------------------
-- 2. Tighten 103's inherited privileges
-- ---------------------------------------------------------------------

REVOKE ALL ON calculator_rate_versions FROM anon, authenticated;
GRANT SELECT ON calculator_rate_versions TO authenticated;

-- ---------------------------------------------------------------------
-- 3. The document's only write path
-- ---------------------------------------------------------------------

-- The manual shorthand document: free text plus the period label it
-- belongs to. One row per account, genuinely mutable scratch — unlike the
-- ledger, nothing here is a financial record, so it is overwritten in
-- place rather than versioned.
--
-- agent+ to write (same bar as sending a message, which is what the route
-- enforced before), any member to read via the policy above.
CREATE OR REPLACE FUNCTION crm_guardar_documento_calculadora(
  p_account_id   uuid,
  p_raw_text     text,
  p_period_label text
) RETURNS remittance_calculator_documents
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_doc remittance_calculator_documents;
BEGIN
  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT is_account_member(p_account_id, 'agent') THEN
    RAISE EXCEPTION 'not authorized to edit the calculator document' USING ERRCODE = '42501';
  END IF;

  IF p_raw_text IS NULL OR p_period_label IS NULL THEN
    RAISE EXCEPTION 'raw_text and period_label are required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO remittance_calculator_documents (account_id, raw_text, period_label, updated_by, updated_at)
  VALUES (p_account_id, p_raw_text, p_period_label, auth.uid(), clock_timestamp())
  ON CONFLICT (account_id) DO UPDATE
    SET raw_text     = EXCLUDED.raw_text,
        period_label = EXCLUDED.period_label,
        updated_by   = EXCLUDED.updated_by,
        updated_at   = EXCLUDED.updated_at
  RETURNING * INTO v_doc;

  RETURN v_doc;
END;
$$;

REVOKE ALL ON FUNCTION crm_guardar_documento_calculadora(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_guardar_documento_calculadora(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION crm_guardar_documento_calculadora(uuid, text, text) IS
  'Agent+ only. Upserts the account''s manual calculator document (free '
  'text + period label). The only write path to that table: it carries no '
  'financial record, so it is overwritten in place rather than versioned.';
