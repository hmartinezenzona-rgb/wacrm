-- =====================================================================
-- 101 — Operation delivery RPC for the operations panel
--
-- Lets an agent (or above) complete a remittance straight from the
-- operations panel, once the delivery proof has been sent to the client
-- on WhatsApp or the operator has explicitly said no proof will be sent:
--
--   crm_entregar_operacion(operation_id, evidence)
--
-- This does NOT introduce a new completion path: it reuses the exact
-- legacy stage transition the old Kanban board already performs by hand
-- (move the deal to Entregada), so every downstream effect — 052's
-- auto-won status flip, trg_sync_operacion_desde_deal mirroring the
-- operation to status='completed', and deals_stage_notify firing the
-- net.http_post that makes n8n send the client the "remesa completada"
-- WhatsApp template — stays byte-for-byte identical to what the legacy
-- board already does. The RPC's only original work is: validating the
-- operation is actually ready to hand off, doing the stage UPDATE under
-- a human actor context (so the 096 automation guards get out of the
-- way), confirming the sync trigger really completed the operation, and
-- recording what evidence the operator had for the handoff.
--
-- Evidence columns (added below) capture what proof backs the delivery:
--   delivery_mode        — 'proof_sent' | 'no_proof' | 'skip_proof' |
--                           'legacy_pipeline' (the last value is reserved
--                           for operations completed the old way, outside
--                           this RPC entirely — this migration never
--                           writes it, it only makes room for a future
--                           backfill to tell the two paths apart)
--   delivery_proof_wamid — WhatsApp message id of the sent proof, if any
--   delivery_proof_path  — storage path of the sent proof, if any
--   delivered_by         — auth.uid() of the operator who delivered it
--
-- Checked against the live catalog before writing this migration: the
-- 096 remittance_operations_lock_guard trigger (trg_admin_field_locks_operations)
-- only inspects contact_id, destination_currency, delivery_method,
-- deposit_method, quoted_source_amount and quoted_destination_amount —
-- it does not reference any of the four new columns, so it does not
-- interfere with the evidence UPDATE below and needed no changes.
--
-- ROLLBACK: see ROLLBACK-101-operation-delivery-rpc.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Evidence columns on remittance_operations.
-- ---------------------------------------------------------------------

ALTER TABLE remittance_operations
  ADD COLUMN IF NOT EXISTS delivery_mode text
    CHECK (delivery_mode IN ('proof_sent', 'no_proof', 'skip_proof', 'legacy_pipeline')),
  ADD COLUMN IF NOT EXISTS delivery_proof_wamid text,
  ADD COLUMN IF NOT EXISTS delivery_proof_path text,
  ADD COLUMN IF NOT EXISTS delivered_by uuid;


-- ---------------------------------------------------------------------
-- 2. Audit action vocabulary: add the new human-initiated action.
-- ---------------------------------------------------------------------

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
    'human_delivery'
  ));


-- ---------------------------------------------------------------------
-- 3. crm_entregar_operacion — panel-driven delivery completion.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lista         CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_entregada     CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';

  v_account_id    uuid;
  v_deal_id       uuid;
  v_conversation  uuid;

  v_stage         uuid;
  v_locked_deal   uuid;

  v_status_before text;
  v_status_after  text;
  v_completed_at  timestamptz;

  v_mode          text;
  v_wamid         text;
  v_path          text;
BEGIN
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to deliver this operation' USING ERRCODE = '42501';
  END IF;

  IF v_deal_id IS NULL THEN
    RAISE EXCEPTION 'operation has no linked deal' USING ERRCODE = '22023';
  END IF;

  -- Evidence validation happens before any locking, so a bad payload
  -- never touches deal/operation state regardless of their current status.
  IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'evidence must be a JSON object' USING ERRCODE = '22023';
  END IF;

  v_mode := p_evidence ->> 'mode';
  IF v_mode IS NULL OR v_mode NOT IN ('proof_sent', 'no_proof', 'skip_proof') THEN
    RAISE EXCEPTION 'evidence mode must be proof_sent, no_proof or skip_proof' USING ERRCODE = '22023';
  END IF;

  IF p_evidence ? 'wamid' AND (p_evidence -> 'wamid') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'wamid') <> 'string' THEN
      RAISE EXCEPTION 'evidence wamid must be a string' USING ERRCODE = '22023';
    END IF;
    v_wamid := p_evidence ->> 'wamid';
    IF v_wamid = '' OR length(v_wamid) > 500 THEN
      RAISE EXCEPTION 'evidence wamid must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_evidence ? 'path' AND (p_evidence -> 'path') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'path') <> 'string' THEN
      RAISE EXCEPTION 'evidence path must be a string' USING ERRCODE = '22023';
    END IF;
    v_path := p_evidence ->> 'path';
    IF v_path = '' OR length(v_path) > 500 THEN
      RAISE EXCEPTION 'evidence path must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Lock order deal -> operation, the same order automation uses (see 099).
  SELECT stage_id, conversation_id INTO v_stage, v_conversation FROM deals WHERE id = v_deal_id FOR UPDATE;

  SELECT status, deal_id
    INTO v_status_before, v_locked_deal
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_locked_deal IS DISTINCT FROM v_deal_id THEN
    RAISE EXCEPTION 'operation changed concurrently, retry' USING ERRCODE = '40001';
  END IF;

  IF v_status_before IS DISTINCT FROM 'ready_to_transfer' OR v_stage IS DISTINCT FROM v_lista THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  -- Reuse the legacy stage path: this is exactly the UPDATE the old
  -- Kanban board performs by hand when a card is dragged into Entregada.
  UPDATE deals SET stage_id = v_entregada, updated_at = now() WHERE id = v_deal_id;

  SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  UPDATE remittance_operations
     SET delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid()
   WHERE id = p_operation_id
  RETURNING completed_at INTO v_completed_at;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer', 'deal_stage', v_lista),
          jsonb_build_object('status', 'completed', 'deal_stage', v_entregada, 'evidence', p_evidence));

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $$;


-- ---------------------------------------------------------------------
-- 4. Grants.
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION crm_entregar_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_entregar_operacion(uuid, jsonb) TO authenticated;
