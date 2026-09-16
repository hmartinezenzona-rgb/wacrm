-- =====================================================================
-- ROLLBACK-108 — reverts 108_delivery_evidence_before_status.sql
--
-- Restores crm_entregar_operacion exactly as it stood after 102 (CREATE OR
-- REPLACE, signature unchanged): the evidence UPDATE moves back to after
-- the stage-move status check, with its `RETURNING completed_at`, and the
-- post-stage-move SELECT goes back to reading status only. The Rule B
-- beneficiary-completeness gate (102) is untouched either way — 108 never
-- moved it.
-- =====================================================================

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

  -- Rule B: deliverable only once every vigente beneficiary is complete,
  -- and there is at least one. See crm_beneficiarios_completos above.
  IF NOT crm_beneficiarios_completos(p_operation_id) THEN
    RAISE EXCEPTION 'beneficiary data is incomplete' USING ERRCODE = '22023';
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

REVOKE ALL ON FUNCTION crm_entregar_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_entregar_operacion(uuid, jsonb) TO authenticated;
