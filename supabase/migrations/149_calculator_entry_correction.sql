-- =====================================================================
-- 149 — Admin correction of chat-fed calculator entries (B3.2)
--
-- PRODUCT DECISION (user, 2026-09-29, production-feedback-2026-09-29.md):
-- "en este punto se edita las columnas de las remesas que ya se
-- completaron y salen en la calculadora, la idea es poder ajustar los
-- valores ya que hay veces que las tasas cambian por algún motivo y las
-- pueden editar los admin" — admins can correct facturado_gyd/
-- invertido_gyd on an already-fed "Operaciones del chat" line because an
-- exchange rate sometimes gets corrected after the fact.
--
-- EDITABLE COLUMNS: facturado_gyd and invertido_gyd only — the two
-- independent numbers a rate correction would actually change.
-- retorno_gyd STAYS DERIVED (facturado - invertido), recomputed here so
-- the two can never disagree, exactly like 104/142's own feed and 105's
-- crm_resolve_pending_entry already do.
--
-- WHO: admin+, same is_account_member(account_id, 'admin') bar as
-- crm_forzar_verificacion (099) and crm_resolve_pending_entry (105) —
-- both are "override the numbers/skip the normal check" escalations, one
-- level above the agent+ bar on crm_corregir_operacion (098).
--
-- SCOPE: source = 'completed_operation' only (never a manual weekly-log
-- line — those have source = 'manual' and no operation_id, see 095's
-- source_shape_chk) and status IN ('completed', 'verified_pending') —
-- never 'void'.
--
-- STRUCTURAL NOTE — why a 'verified_pending' entry also flips to
-- 'completed' here (not just documentation, a real constraint): 104's
-- own remittance_calculator_entries_pending_has_no_snapshot_chk REQUIRES
-- facturado_gyd/invertido_gyd/retorno_gyd to be NULL while status =
-- 'verified_pending'. Writing a number into either column while leaving
-- status untouched is not just undesired, it is impossible — the INSERT/
-- UPDATE itself would violate that CHECK. So correcting a pending line's
-- figures IS resolving it, the same outcome crm_resolve_pending_entry
-- (105/142) reaches by a different route (feeding it a RATE and letting
-- the deposit basis compute facturado/invertido). This function reaches
-- the same end state (status='completed', missing_inputs cleared) but
-- from a DIRECT admin-supplied figure instead of a rate + basis
-- computation — flagged here because it is a second write path to the
-- same transition, deliberately authorized by the scope above, not
-- discovered and silently patched over.
--
-- WHY THE APPEND-ONLY TRIGGER NEEDS A NARROW HOLE (structural finding):
-- 104's remittance_calculator_entries_lock_completed() trigger makes a
-- 'completed' row's facturado_gyd/invertido_gyd/retorno_gyd permanently
-- unwritable outside of voiding it — by design, so a delivered remesa's
-- historical figures can never silently drift. B3.2 asks for exactly the
-- one exception that guard was built to prevent in general: a human,
-- audited, deliberately correcting those three figures on a row that
-- STAYS 'completed' (not void). Rather than weaken the guard for every
-- writer, the trigger now opens a narrow, session-scoped hole
-- (wacrm.calculator_correction = 'true', mirroring the wacrm.origin GUC
-- pattern 096/127/129 already use for "this write is human-authorized
-- automation") that ONLY this function ever sets, and only for the
-- duration of its own UPDATE. Every other column the append-only guard
-- already protected (amount, service, operation_id, rate_version_id)
-- stays exactly as locked as before, even during a correction — a rate
-- correction changes what the deposit was worth, never which deposit,
-- which service, or which rate VERSION it was priced against.
--
-- AUDITED: one remittance_admin_audit row per correction, action
-- 'human_calculator_correction', before/after snapshots of the whole
-- row, actor from wacrm_current_actor() — same shape as human_correction
-- (098) and calculator_pending_resolved (105/142).
--
-- ROLLBACK: ROLLBACK-149-calculator-entry-correction.sql
-- Guarded by supabase/staging/assertions/calculator-entry-correction.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Audit action vocabulary: add the one new human-initiated action.
-- ---------------------------------------------------------------------
-- Full list carried forward byte-for-byte from 127 (the latest migration
-- to touch this constraint) plus 'human_calculator_correction'.

ALTER TABLE remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit
  ADD CONSTRAINT remittance_admin_audit_action_chk
  CHECK (action IN (
    'automation_write_suppressed',
    'automation_completion_suppressed',
    'automation_revert_suppressed',
    'human_correction',
    'human_reassignment',
    'human_deposit_verification',
    'human_forced_verification',
    'human_delivery',
    'calculator_feed_failed',
    'calculator_pending_resolved',
    'human_beneficiary_added',
    'automation_reparto_registered',
    'human_calculator_correction'
  ));

-- ---------------------------------------------------------------------
-- 2. The append-only guard's one narrow, audited hole.
-- ---------------------------------------------------------------------
-- Byte-identical to 104's remittance_calculator_entries_lock_completed()
-- except for the new v_correcting branch inserted right after the
-- OLD.status = 'completed' check begins.

CREATE OR REPLACE FUNCTION remittance_calculator_entries_lock_completed()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_correcting boolean := coalesce(current_setting('wacrm.calculator_correction', true), '') = 'true';
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'completed' THEN
      RAISE EXCEPTION 'remittance_calculator_entries: completed rows are append-only'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.status = 'completed' THEN
    -- (149) crm_corregir_entrada_calculadora is the ONLY caller ever
    -- allowed to set this GUC, and only for the duration of its own
    -- UPDATE. It may revise facturado_gyd/invertido_gyd/retorno_gyd
    -- WITHOUT voiding the row; every other figure this guard already
    -- protected must still survive untouched.
    IF v_correcting AND NEW.status = 'completed' THEN
      IF NEW.amount          IS DISTINCT FROM OLD.amount
         OR NEW.service        IS DISTINCT FROM OLD.service
         OR NEW.operation_id   IS DISTINCT FROM OLD.operation_id
         OR NEW.rate_version_id IS DISTINCT FROM OLD.rate_version_id
      THEN
        RAISE EXCEPTION 'remittance_calculator_entries: a correction may only change facturado_gyd, invertido_gyd and retorno_gyd'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      RETURN NEW;
    END IF;

    -- The only other permitted change is voiding it, and even then every
    -- figure must survive untouched so the audit trail stays readable.
    IF NEW.status <> 'void' THEN
      RAISE EXCEPTION 'remittance_calculator_entries: completed rows are append-only'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NEW.amount        IS DISTINCT FROM OLD.amount
       OR NEW.service       IS DISTINCT FROM OLD.service
       OR NEW.operation_id  IS DISTINCT FROM OLD.operation_id
       OR NEW.facturado_gyd IS DISTINCT FROM OLD.facturado_gyd
       OR NEW.invertido_gyd IS DISTINCT FROM OLD.invertido_gyd
       OR NEW.retorno_gyd   IS DISTINCT FROM OLD.retorno_gyd
       OR NEW.rate_version_id IS DISTINCT FROM OLD.rate_version_id
    THEN
      RAISE EXCEPTION 'remittance_calculator_entries: voiding must not alter the recorded figures'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- 3. crm_corregir_entrada_calculadora — the audited correction RPC.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_corregir_entrada_calculadora(
  p_entry_id      uuid,
  p_facturado_gyd numeric,
  p_invertido_gyd numeric
) RETURNS remittance_calculator_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry  remittance_calculator_entries;
  v_before jsonb;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to correct calculator entries' USING ERRCODE = '42501';
  END IF;

  IF v_entry.source <> 'completed_operation' THEN
    RAISE EXCEPTION 'only a chat-fed entry can be corrected here' USING ERRCODE = '22023';
  END IF;

  IF v_entry.status NOT IN ('completed', 'verified_pending') THEN
    RAISE EXCEPTION 'entry is % and cannot be corrected here', v_entry.status USING ERRCODE = '22023';
  END IF;

  IF p_facturado_gyd IS NULL OR p_facturado_gyd < 0 OR p_facturado_gyd >= 1e15 THEN
    RAISE EXCEPTION 'facturado_gyd must be zero or greater' USING ERRCODE = '22023';
  END IF;

  IF p_invertido_gyd IS NULL OR p_invertido_gyd < 0 OR p_invertido_gyd >= 1e15 THEN
    RAISE EXCEPTION 'invertido_gyd must be zero or greater' USING ERRCODE = '22023';
  END IF;

  v_before := to_jsonb(v_entry);

  -- Open the append-only guard's narrow hole for exactly this UPDATE.
  PERFORM set_config('wacrm.calculator_correction', 'true', true);

  UPDATE remittance_calculator_entries
     SET facturado_gyd  = p_facturado_gyd,
         invertido_gyd  = p_invertido_gyd,
         retorno_gyd    = p_facturado_gyd - p_invertido_gyd,
         status         = 'completed',
         missing_inputs = NULL
   WHERE id = p_entry_id
  RETURNING * INTO v_entry;

  PERFORM set_config('wacrm.calculator_correction', '', true);

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id,
          'facturado_gyd,invertido_gyd,retorno_gyd,status', 'human_calculator_correction',
          wacrm_current_actor(), v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$$;

REVOKE ALL ON FUNCTION crm_corregir_entrada_calculadora(uuid, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_corregir_entrada_calculadora(uuid, numeric, numeric) TO authenticated;

COMMENT ON FUNCTION crm_corregir_entrada_calculadora(uuid, numeric, numeric) IS
  'Admin+ only. Corrects facturado_gyd/invertido_gyd (retorno_gyd always '
  're-derived) on a completed_operation-sourced calculator entry whose '
  'status is completed or verified_pending — never void, never a manual '
  'weekly-log line. A verified_pending entry also transitions to '
  'completed and clears missing_inputs, because 104''s own CHECK '
  'constraint forbids a non-null facturado/invertido while pending. '
  'Every correction is audited (human_calculator_correction).';
