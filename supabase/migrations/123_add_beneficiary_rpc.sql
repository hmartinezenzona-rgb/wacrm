-- =====================================================================
-- 123 — crm_agregar_beneficiario: add a beneficiary by hand
--
-- Gives agents (and above) a fourth explicit, audited beneficiary action
-- alongside the three 098 already added
-- (crm_corregir_operacion/crm_corregir_beneficiario/crm_reasignar_beneficiario):
--
--   crm_agregar_beneficiario(operation_id, datos) -- ADD a new beneficiary
--
-- WHY (odd/tasks/panel-add-beneficiary.md, found 2026-09-27): the bot only
-- records a beneficiary for part of the remesas — the rest are handled by
-- humans in the chat. `crm_entregar_operacion` (114) refuses delivery
-- unless `crm_beneficiarios_completos` (102) is true, and until now the
-- panel could only EDIT or REASSIGN an EXISTING beneficiary — there was
-- no path to add one when the bot never captured any beneficiary at all.
--
-- Same shape as 098's crm_corregir_beneficiario, minus the "replace an
-- existing row" step: this INSERTs a brand-new 'vigente' row instead of
-- superseding one. It reuses:
--   - the same auth check (agent+ via is_account_member), same error
--     codes (42501/22023/P0002),
--   - `wacrm_current_actor()` for the audit actor,
--   - the same admin lock on `remittance_operations.admin_locked_fields
--     -> 'beneficiaries'`, so `cerebro_sync_beneficiarios()` (042/098)
--     stops touching this operation's beneficiaries the moment a human
--     has added one by hand — exactly the same protection 098 already
--     gives corrections and reassignments (verified again for the ADD
--     case in the "cerebro sync does not wipe it" assertion case below).
--   - the same beneficiary_type vocabulary and per-type validation shape
--     as `crm_corregir_beneficiario` (zelle: name + zelle_account; every
--     other type: 16-digit card_number + 8-15 digit phone).
--
-- DIFFERENCE FROM crm_corregir_beneficiario: a brand-new beneficiary has
-- no prior row to inherit an amount/currency from, and the whole point of
-- this feature is letting the operator record how much this beneficiary
-- receives — so `amount` (> 0) and `currency` (3-letter code) are
-- REQUIRED here, not optional overrides like they are in a correction.
-- `crm_beneficiarios_completos` itself never looks at amount/currency
-- (rule B only checks name/zelle_account or card_number/phone), so this
-- is a product decision for this RPC, not a completeness requirement —
-- see the feature doc's "Decisions to confirm".
--
-- Refuses:
--   - a non-agent caller                              -> 42501
--   - operation not found                              -> P0002
--   - a closed operation (completed/cancelled)         -> 22023
--   - a non-remesa operation (service_type <> 'remesa') -> 22023
--   - an unknown p_datos key, or a missing/invalid required field
--     (beneficiary_type, amount, currency, and the per-type fields)
--                                                       -> 22023
--
-- ROLLBACK: see ROLLBACK-123-add-beneficiary-rpc.sql
-- STAGING ASSERTION: supabase/staging/assertions/add-beneficiary.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Audit action vocabulary: add the one new human-initiated action.
-- ---------------------------------------------------------------------
-- The full current set (through 104's calculator_feed_failed/
-- calculator_pending_resolved) is carried forward here, not just 098's —
-- the CHECK has been redefined by 099/101/104 since, and this ALTER
-- replaces the whole constraint, so it must restate every value already
-- in production/staging use or existing audit rows would violate it.

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
    'human_beneficiary_added'
  ));


-- ---------------------------------------------------------------------
-- 2. crm_agregar_beneficiario — add a new 'vigente' beneficiary by hand.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_agregar_beneficiario(p_operation_id uuid, p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id        uuid;
  v_op_status          text;
  v_service_type       text;
  v_key                text;
  v_new_id             uuid;
  v_next_position      integer;
  v_next_block_index   integer;

  v_beneficiary_type   text;
  v_name               text;
  v_card_number        text;
  v_phone              text;
  v_zelle_account      text;
  v_delivery_method    text;
  v_amount             numeric;
  v_currency           text;
BEGIN
  SELECT account_id, status, service_type
    INTO v_account_id, v_op_status, v_service_type
    FROM remittance_operations
   WHERE id = p_operation_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to add a beneficiary to this operation' USING ERRCODE = '42501';
  END IF;

  IF v_op_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF v_service_type IS DISTINCT FROM 'remesa' THEN
    RAISE EXCEPTION 'beneficiaries can only be added to remesa operations' USING ERRCODE = '22023';
  END IF;

  IF p_datos IS NULL OR jsonb_typeof(p_datos) <> 'object' THEN
    RAISE EXCEPTION 'datos must be a JSON object' USING ERRCODE = '22023';
  END IF;

  -- Reject unknown keys up front, same posture as crm_corregir_beneficiario.
  FOR v_key IN SELECT jsonb_object_keys(p_datos) LOOP
    IF v_key NOT IN ('beneficiary_type', 'name', 'card_number', 'phone', 'zelle_account',
                      'delivery_method', 'amount', 'currency') THEN
      RAISE EXCEPTION 'unknown field: %', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_beneficiary_type := p_datos ->> 'beneficiary_type';
  IF v_beneficiary_type IS NULL
     OR v_beneficiary_type NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution') THEN
    RAISE EXCEPTION 'invalid beneficiary_type: %', v_beneficiary_type USING ERRCODE = '22023';
  END IF;

  -- amount and currency are required: unlike a correction, a newly added
  -- beneficiary has no prior row to fall back on for its destination amount.
  IF NOT (p_datos ? 'amount') OR p_datos ->> 'amount' IS NULL
     OR (p_datos ->> 'amount')::numeric <= 0 THEN
    RAISE EXCEPTION 'amount is required and must be greater than 0' USING ERRCODE = '22023';
  END IF;
  v_amount := (p_datos ->> 'amount')::numeric;

  IF NOT (p_datos ? 'currency') OR p_datos ->> 'currency' IS NULL
     OR p_datos ->> 'currency' !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'currency is required and must be a 3-letter uppercase code' USING ERRCODE = '22023';
  END IF;
  v_currency := p_datos ->> 'currency';

  v_delivery_method := p_datos ->> 'delivery_method';
  IF p_datos ? 'delivery_method' AND btrim(coalesce(v_delivery_method, '')) = '' THEN
    RAISE EXCEPTION 'delivery_method must not be empty' USING ERRCODE = '22023';
  END IF;

  IF v_beneficiary_type = 'zelle' THEN
    v_name := p_datos ->> 'name';
    v_zelle_account := p_datos ->> 'zelle_account';
    IF btrim(coalesce(v_name, '')) = '' THEN
      RAISE EXCEPTION 'name is required for a zelle beneficiary' USING ERRCODE = '22023';
    END IF;
    IF btrim(coalesce(v_zelle_account, '')) = '' THEN
      RAISE EXCEPTION 'zelle_account is required for a zelle beneficiary' USING ERRCODE = '22023';
    END IF;
    v_card_number := NULL;
    v_phone := NULL;
  ELSE
    v_card_number := p_datos ->> 'card_number';
    v_phone := p_datos ->> 'phone';
    IF v_card_number IS NULL OR v_card_number !~ '^[0-9]{16}$' THEN
      RAISE EXCEPTION 'card_number must be exactly 16 digits' USING ERRCODE = '22023';
    END IF;
    IF v_phone IS NULL OR v_phone !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_name := p_datos ->> 'name';
    v_zelle_account := NULL;
  END IF;

  SELECT coalesce(max(position), 0) + 1 INTO v_next_position
    FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';

  SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
    FROM remittance_beneficiaries WHERE operation_id = p_operation_id;

  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone, zelle_account,
    delivery_method, amount, currency, position, status, source, block_index
  ) VALUES (
    p_operation_id, v_beneficiary_type, v_name, v_card_number, v_phone, v_zelle_account,
    v_delivery_method, v_amount, v_currency, v_next_position, 'vigente', 'admin_addition', v_next_block_index
  ) RETURNING id INTO v_new_id;

  -- Lock beneficiaries on this operation so automation cannot overwrite or
  -- delete the row a human just added — same lock crm_corregir_beneficiario
  -- and crm_reasignar_beneficiario place (098), honored by
  -- cerebro_sync_beneficiarios' early return (also 098).
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields ||
         jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,name,card_number,phone,zelle_account,delivery_method,amount,currency',
          'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);

  RETURN jsonb_build_object(
    'id', v_new_id,
    'complete', crm_beneficiarios_completos(p_operation_id)
  );
END $$;

REVOKE ALL ON FUNCTION crm_agregar_beneficiario(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_agregar_beneficiario(uuid, jsonb) TO authenticated;
