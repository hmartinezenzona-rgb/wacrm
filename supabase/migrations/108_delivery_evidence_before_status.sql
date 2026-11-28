-- =====================================================================
-- 108 — Delivery evidence stamped before the status flip, not after
--
-- BUG: remittance_calculator_entries.delivery_mode and .actor_user_id are
-- always NULL on ledger entries fed through crm_entregar_operacion.
--
-- WHY: crm_entregar_operacion wrote the delivery evidence
-- (delivery_mode, delivery_proof_wamid, delivery_proof_path,
-- delivered_by) onto remittance_operations AFTER
-- `UPDATE deals SET stage_id = Entregada`. That deals UPDATE is what
-- fires the legacy status sync (trg_sync_operacion_desde_deal, 041),
-- which flips the operation to status = 'completed', which in the SAME
-- statement fires the calculator ledger auto-feed
-- (zzz_remittance_operations_calculator_feed, 104:421-423 — a plain,
-- non-deferred AFTER UPDATE OF status trigger). Its
-- calculator_feed_operation (104:256) re-reads the operation row right
-- then and copies delivery_mode/delivered_by (104:316) into the ledger
-- entry — two statements before the evidence UPDATE ever runs. So the
-- columns the feed captured were always the pre-evidence NULLs.
--
-- THE FIX: reorder — stamp the evidence UPDATE on remittance_operations
-- BEFORE the `UPDATE deals SET stage_id` that triggers completion, so the
-- feed reads the real values. completed_at is not set yet at that
-- earlier point (the legacy sync is what sets it), so the evidence
-- UPDATE's `RETURNING completed_at` is dropped; the function now reads
-- completed_at off the same post-stage-move SELECT that already reads
-- status.
--
-- THE FUNCTION BELOW IS 102'S, VERBATIM, WITH EXACTLY TWO CHANGES. 102 —
-- not 101 — is the live definition: it CREATE OR REPLACEd 101's version
-- to add the beneficiary-completeness gate (Rule B), and no migration
-- between 102 and 107 touches crm_entregar_operacion again. Building this
-- fix off 101 instead would have silently dropped that gate.
--   (a) the delivery_mode / delivery_proof_wamid / delivery_proof_path /
--       delivered_by UPDATE moved from after the post-stage-move status
--       check to right after the Rule B beneficiary check, immediately
--       before `UPDATE deals SET stage_id = v_entregada`, and its
--       `RETURNING completed_at INTO v_completed_at` dropped (completed_at
--       isn't set yet at that point).
--   (b) the post-stage-move `SELECT status INTO v_status_after` now also
--       selects completed_at: `SELECT status, completed_at INTO
--       v_status_after, v_completed_at`.
-- Nothing else about it moves: authorization, evidence validation, the
-- lock order, the readiness guard, the Rule B beneficiary-completeness
-- gate (102), and the human_delivery audit row are all exactly as before.
--
-- ROLLBACK: see ROLLBACK-108-delivery-evidence-before-status.sql, which
-- restores 102's crm_entregar_operacion verbatim (the version this
-- migration supersedes).
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

  UPDATE remittance_operations
     SET delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid()
   WHERE id = p_operation_id;

  -- Reuse the legacy stage path: this is exactly the UPDATE the old
  -- Kanban board performs by hand when a card is dragged into Entregada.
  UPDATE deals SET stage_id = v_entregada, updated_at = now() WHERE id = v_deal_id;

  SELECT status, completed_at INTO v_status_after, v_completed_at FROM remittance_operations WHERE id = p_operation_id;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer', 'deal_stage', v_lista),
          jsonb_build_object('status', 'completed', 'deal_stage', v_entregada, 'evidence', p_evidence));

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $$;

REVOKE ALL ON FUNCTION crm_entregar_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_entregar_operacion(uuid, jsonb) TO authenticated;


-- ---------------------------------------------------------------------
-- Deliberately NOT backfilled here
--
-- Entries fed before this reorder kept the NULLs the feed captured. They
-- are NOT repaired by this migration, on purpose.
--
-- 095's append-only trigger (as amended by 104) permits exactly one change
-- to a completed entry: voiding it, and even then every figure must survive
-- untouched. So the only way to refill delivery_mode on an existing entry
-- is to void it and let calculator_feed_operation revive it — which
-- recomputes every figure from the rate version current AT THAT MOMENT, not
-- the one the entry recorded. Where rates have moved since, that silently
-- rewrites money.
--
-- delivery_mode is informational; it records which channel delivered the
-- remittance, never an amount. Rewriting a financial record to recover an
-- informational field is the exact trade the append-only guard exists to
-- refuse, and a migration cannot check the rate drift of an environment it
-- has not seen yet.
--
-- Repairing old rows is therefore a deliberate, per-environment operation:
-- see supabase/staging/repair-delivery-evidence.sql, which refuses to
-- proceed unless every recomputed figure is byte-identical.
