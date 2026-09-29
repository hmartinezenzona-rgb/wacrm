-- =====================================================================
-- 143 — Delivery proof per beneficiary (image + caption)
--
-- WHY
--   The user asked on 2026-09-28 that a remesa paid to several beneficiaries
--   (e.g. two Zelle accounts from one deposit) gets one proof image, with
--   its own caption, per beneficiary. Until now an operation held a single
--   proof (delivery_proof_wamid/path, 101/108/114) and delivered on it.
--
-- WHAT
--   1. remittance_beneficiary_proofs: one row per proof sent for a
--      beneficiary (wamid, storage path, caption, who, when). Read by
--      account members; written only through the RPC below.
--   2. crm_registrar_prueba_beneficiario(op, beneficiary, evidence): records
--      one beneficiary's proof. The beneficiary must be current and belong
--      to the operation, and the operation must be ready_to_transfer. It does
--      NOT change the status; it returns how many current beneficiaries
--      still lack a proof. A retry with the same wamid is idempotent.
--   3. crm_pruebas_faltantes(op): current beneficiaries without a proof,
--      0 when the operation has fewer than 2 current beneficiaries.
--   4. crm_entregar_operacion (114, verbatim otherwise): in mode proof_sent
--      it refuses while crm_pruebas_faltantes > 0. One beneficiary, and
--      the no_proof / skip_proof modes, behave exactly as before. The
--      operation-level delivery_proof_* keep the evidence passed in (the
--      last proof), so the ledger feed and history are unchanged.
--
-- ROLLBACK: ROLLBACK-143-beneficiary-delivery-proofs.sql
-- =====================================================================

CREATE TABLE IF NOT EXISTS remittance_beneficiary_proofs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_id   uuid NOT NULL REFERENCES remittance_operations(id) ON DELETE CASCADE,
  beneficiary_id uuid NOT NULL REFERENCES remittance_beneficiaries(id) ON DELETE CASCADE,
  wamid          text NOT NULL CHECK (char_length(wamid) BETWEEN 1 AND 500),
  path           text CHECK (path IS NULL OR char_length(path) BETWEEN 1 AND 500),
  caption        text CHECK (caption IS NULL OR char_length(caption) <= 1024),
  sent_by        uuid DEFAULT auth.uid(),
  sent_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT remittance_beneficiary_proofs_beneficiary_wamid_uk UNIQUE (beneficiary_id, wamid)
);

CREATE INDEX IF NOT EXISTS remittance_beneficiary_proofs_operation_idx
  ON remittance_beneficiary_proofs (operation_id);

ALTER TABLE remittance_beneficiary_proofs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS remittance_beneficiary_proofs_select ON remittance_beneficiary_proofs;
CREATE POLICY remittance_beneficiary_proofs_select ON remittance_beneficiary_proofs
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM remittance_operations o
     WHERE o.id = remittance_beneficiary_proofs.operation_id
       AND is_account_member(o.account_id)));

REVOKE ALL ON remittance_beneficiary_proofs FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON remittance_beneficiary_proofs FROM authenticated;
GRANT SELECT ON remittance_beneficiary_proofs TO authenticated;

CREATE OR REPLACE FUNCTION crm_pruebas_faltantes(p_operation_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
           WHEN (SELECT count(*) FROM remittance_beneficiaries b
                  WHERE b.operation_id = p_operation_id AND b.status = 'vigente') < 2
             THEN 0
           ELSE (SELECT count(*)::integer FROM remittance_beneficiaries b
                  WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
                    AND NOT EXISTS (SELECT 1 FROM remittance_beneficiary_proofs p
                                     WHERE p.beneficiary_id = b.id))
         END;
$$;

REVOKE ALL ON FUNCTION crm_pruebas_faltantes(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_pruebas_faltantes(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION crm_registrar_prueba_beneficiario(
  p_operation_id   uuid,
  p_beneficiary_id uuid,
  p_evidence       jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id uuid;
  v_status     text;
  v_wamid      text;
  v_path       text;
  v_caption    text;
BEGIN
  SELECT account_id, status INTO v_account_id, v_status
    FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to deliver this operation' USING ERRCODE = '42501';
  END IF;

  IF v_status IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b
                  WHERE b.id = p_beneficiary_id AND b.operation_id = p_operation_id
                    AND b.status = 'vigente') THEN
    RAISE EXCEPTION 'beneficiary is not a current beneficiary of this operation' USING ERRCODE = '22023';
  END IF;

  IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'evidence must be a JSON object' USING ERRCODE = '22023';
  END IF;

  IF jsonb_typeof(p_evidence -> 'wamid') IS DISTINCT FROM 'string' THEN
    RAISE EXCEPTION 'evidence wamid is required and must be a string' USING ERRCODE = '22023';
  END IF;
  v_wamid := p_evidence ->> 'wamid';
  IF v_wamid = '' OR length(v_wamid) > 500 THEN
    RAISE EXCEPTION 'evidence wamid must be non-empty and at most 500 characters' USING ERRCODE = '22023';
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

  IF p_evidence ? 'caption' AND (p_evidence -> 'caption') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'caption') <> 'string' THEN
      RAISE EXCEPTION 'evidence caption must be a string' USING ERRCODE = '22023';
    END IF;
    v_caption := nullif(btrim(p_evidence ->> 'caption'), '');
    IF length(v_caption) > 1024 THEN
      RAISE EXCEPTION 'evidence caption must be at most 1024 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO remittance_beneficiary_proofs (operation_id, beneficiary_id, wamid, path, caption)
  VALUES (p_operation_id, p_beneficiary_id, v_wamid, v_path, v_caption)
  ON CONFLICT ON CONSTRAINT remittance_beneficiary_proofs_beneficiary_wamid_uk DO NOTHING;

  RETURN jsonb_build_object('registered', true, 'missing', crm_pruebas_faltantes(p_operation_id));
END;
$$;

REVOKE ALL ON FUNCTION crm_registrar_prueba_beneficiario(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_registrar_prueba_beneficiario(uuid, uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id    uuid;
  v_deal_id       uuid;

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

  -- Lock the deal too (when there is one) to preserve ordering against
  -- concurrent n8n deals.notes/value writes — deal_id is no longer a
  -- hard requirement for delivery (item 1: remittance_operations is the
  -- sole write target), only a historical linkage.
  IF v_deal_id IS NOT NULL THEN
    PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;
  END IF;

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  IF NOT crm_beneficiarios_completos(p_operation_id) THEN
    RAISE EXCEPTION 'beneficiary data is incomplete' USING ERRCODE = '22023';
  END IF;

  -- (143) With proof and 2+ current beneficiaries, every beneficiary needs
  -- its own proof (crm_registrar_prueba_beneficiario) before delivering.
  IF v_mode = 'proof_sent' AND crm_pruebas_faltantes(p_operation_id) > 0 THEN
    RAISE EXCEPTION 'every beneficiary needs its delivery proof before delivering (% missing)',
      crm_pruebas_faltantes(p_operation_id)
      USING ERRCODE = '22023';
  END IF;

  -- (114) One statement: status, evidence, completed_at (the latter set
  -- automatically by trg_remittance_operations_touch, 040) all land in
  -- the same NEW row image the calculator feed trigger reads.
  UPDATE remittance_operations
     SET status = 'completed',
         delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid()
   WHERE id = p_operation_id
     AND status = 'ready_to_transfer'
  RETURNING status, completed_at INTO v_status_after, v_completed_at;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer'),
          jsonb_build_object('status', 'completed', 'evidence', p_evidence));

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $$;

REVOKE ALL ON FUNCTION crm_entregar_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_entregar_operacion(uuid, jsonb) TO authenticated;
