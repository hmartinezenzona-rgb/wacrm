-- =====================================================================
-- 099 — Deposit review RPCs for the operations panel
--
-- Gives agents (and above) a way to review and verify a remittance
-- deposit from the CRM panel instead of only through the automated
-- email-cross-reference pipeline, plus an admin-only escape hatch for
-- when the automated match can never succeed (e.g. the client paid by a
-- method that leaves no MMG email trail):
--
--   crm_comprobantes_de_operacion(operation_id)              -- read model
--   crm_verificar_deposito(operation_id, items)               -- panel verify
--   crm_forzar_verificacion(operation_id, reason)              -- forced verify
--
-- Receipts are DERIVED, not stored: there is no receipts table. A
-- "receipt" is reconstructed on every read by parsing the deal's notes
-- (n8n writes one block per WhatsApp deposit screenshot, blocks
-- separated by E'\n---\n', each carrying a `DEPOSITO: <amount> <ccy>`
-- line, a `Ref: <digits>` line and a `COMP-<20 hex>` id) and joining that
-- id back to comprobantes_hashes / messages for the underlying image, and
-- to depositos_mmg for whatever MMG deposit (if any) has already been
-- matched to this deal for that reference.
--
-- crm_verificar_deposito is a thin, audited wrapper around the existing
-- cross-reference engine. That engine — cerebro_cruzar_depositos /
-- cerebro_cruzar_deposito / cerebro_saldo_envio — is LIVE on staging and
-- production but is NOT versioned in this repository's migrations (it
-- predates this migration history); this file only depends on its
-- existing signature and behavior, it does not (re)create it. The wrapper
-- calls it with p_stage_ok = p_stage_incidencia = p_stage_esperado = the
-- deal's CURRENT stage, so the cross-reference itself never moves the
-- deal and therefore never fires deals_stage_notify (that trigger only
-- fires AFTER UPDATE OF stage_id WHEN old IS DISTINCT FROM new) — only
-- our own explicit stage UPDATE (when the cross-reference says
-- "verified") does, and only that UPDATE also carries the client-visible
-- note rewrite below.
--
-- Skip-string rationale: the n8n notify workflow skips the client
-- "deposit verified" WhatsApp message when the deal's notes contain the
-- exact substring 'VERIFICADO: casa con el correo de MMG' — that string
-- means "the automated pipeline already told the client". A verification
-- done from this panel (whether the underlying cross-reference matched or
-- was forced by an admin) has NOT told the client anything yet, so both
-- RPCs below rewrite any pre-existing occurrence of that exact substring
-- to 'VERIFICADO EN PANEL: casa con el correo de MMG' (same TransID
-- suffix, so the audit trail is unchanged) before appending their own
-- panel note, and do this in the SAME UPDATE that moves the stage so the
-- notify trigger's payload (built from NEW at trigger time) already
-- carries the rewritten notes.
--
-- ROLLBACK: see ROLLBACK-099-deposit-review-rpcs.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Audit action vocabulary: add the two new human-initiated actions.
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
    'human_forced_verification'
  ));


-- ---------------------------------------------------------------------
-- 2. crm_comprobantes_de_operacion — derived read model for the panel.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_comprobantes_de_operacion(p_operation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_por_verificar CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_incidencia    CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';

  v_account_id  uuid;
  v_status      text;
  v_deal_id     uuid;
  v_stage_id    uuid;
  v_notes       text;
  v_can_verify  boolean;

  v_objetivo    numeric;
  v_depositado  numeric;
  v_saldo       numeric;
  v_moneda      text;

  v_blocks      text[];
  v_blk         text;
  v_i           integer;
  v_comp        text;
  v_seen_comp   text[] := ARRAY[]::text[];
  v_amount_raw  text;
  v_amount      numeric;
  v_currency    text;
  v_ref         text;

  v_m_trans_id       text;
  v_m_amount         numeric;
  v_m_currency       text;
  v_m_received_at    timestamptz;
  v_m_consumed_at    timestamptz;
  v_matched_deposit  jsonb;

  v_msg_id          uuid;
  v_msg_media_url   text;
  v_msg_created_at  timestamptz;
  v_ch_received_at  timestamptz;

  v_receipts    jsonb := '[]'::jsonb;
  v_consumed    jsonb := '[]'::jsonb;
BEGIN
  SELECT account_id, status, deal_id
    INTO v_account_id, v_status, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'viewer'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to view this operation' USING ERRCODE = '42501';
  END IF;

  IF v_deal_id IS NOT NULL THEN
    SELECT stage_id, notes INTO v_stage_id, v_notes FROM deals WHERE id = v_deal_id;

    SELECT objetivo, depositado, saldo, moneda
      INTO v_objetivo, v_depositado, v_saldo, v_moneda
      FROM cerebro_saldo_envio(v_deal_id);

    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'trans_id', trans_id, 'amount', monto, 'currency', moneda,
             'received_at', recibido_en, 'consumed_at', consumido_en
           ) ORDER BY consumido_en), '[]'::jsonb)
      INTO v_consumed
      FROM depositos_mmg
     WHERE deal_id = v_deal_id AND consumido_en IS NOT NULL AND anulado_en IS NULL;
  END IF;

  v_can_verify := v_status IN ('deposit_verification', 'incident')
                  AND v_deal_id IS NOT NULL
                  AND v_stage_id IN (v_por_verificar, v_incidencia);

  IF v_notes IS NOT NULL THEN
    v_blocks := string_to_array(v_notes, E'\n---\n');

    FOR v_i IN 1 .. coalesce(array_length(v_blocks, 1), 0) LOOP
      v_blk := v_blocks[v_i];
      v_comp := (regexp_match(v_blk, 'COMP-[0-9a-f]{20}'))[1];

      IF v_comp IS NOT NULL AND NOT (v_comp = ANY (v_seen_comp)) THEN
        v_seen_comp := v_seen_comp || v_comp;

        v_amount_raw := (regexp_match(v_blk, 'DEPOSITO: ([0-9][0-9,]*(\.[0-9]+)?) ([A-Z]{3})'))[1];
        v_currency   := (regexp_match(v_blk, 'DEPOSITO: ([0-9][0-9,]*(\.[0-9]+)?) ([A-Z]{3})'))[3];
        v_amount     := NULLIF(replace(coalesce(v_amount_raw, ''), ',', ''), '')::numeric;
        v_ref        := (regexp_match(v_blk, 'Ref: ([0-9]+)'))[1];

        v_m_trans_id := NULL; v_m_amount := NULL; v_m_currency := NULL;
        v_m_received_at := NULL; v_m_consumed_at := NULL;
        IF v_deal_id IS NOT NULL AND v_ref IS NOT NULL THEN
          SELECT trans_id, monto, moneda, recibido_en, consumido_en
            INTO v_m_trans_id, v_m_amount, v_m_currency, v_m_received_at, v_m_consumed_at
            FROM depositos_mmg
           WHERE deal_id = v_deal_id AND trans_id = v_ref AND anulado_en IS NULL;
        END IF;

        v_matched_deposit := CASE WHEN v_m_trans_id IS NOT NULL THEN
          jsonb_build_object(
            'trans_id', v_m_trans_id, 'amount', v_m_amount, 'currency', v_m_currency,
            'received_at', v_m_received_at, 'consumed_at', v_m_consumed_at)
          ELSE NULL END;

        v_msg_id := NULL; v_msg_media_url := NULL; v_msg_created_at := NULL; v_ch_received_at := NULL;
        SELECT m.id, m.media_url, m.created_at, ch.fecha_recibido
          INTO v_msg_id, v_msg_media_url, v_msg_created_at, v_ch_received_at
          FROM comprobantes_hashes ch
          LEFT JOIN messages m ON m.message_id = ch.whatsapp_message_id
         WHERE ch.comp_id = v_comp
         ORDER BY m.created_at DESC NULLS LAST
         LIMIT 1;

        v_receipts := v_receipts || jsonb_build_object(
          'comp_id', v_comp,
          'message_id', v_msg_id,
          'media_url', v_msg_media_url,
          'received_at', coalesce(v_msg_created_at, v_ch_received_at),
          'declared_amount', v_amount,
          'declared_currency', v_currency,
          'declared_ref', v_ref,
          'matched_deposit', v_matched_deposit
        );
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'operation_id', p_operation_id,
    'status', v_status,
    'deal_id', v_deal_id,
    'can_verify', v_can_verify,
    'objetivo', v_objetivo,
    'depositado', v_depositado,
    'saldo', v_saldo,
    'moneda', v_moneda,
    'receipts', v_receipts,
    'consumed_deposits', v_consumed
  );
END $$;


-- ---------------------------------------------------------------------
-- 3. crm_verificar_deposito — panel-driven cross-reference verify.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_verificar_deposito(p_operation_id uuid, p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_por_verificar CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista         CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_incidencia    CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';

  v_account_id      uuid;
  v_status_before   text;
  v_status_after    text;
  v_deal_id         uuid;
  v_stage           uuid;
  v_final           uuid;

  v_items_len   integer;
  v_i           integer;
  v_item        jsonb;
  v_ref         text;
  v_amount      numeric;
  v_refs        text[] := ARRAY[]::text[];
  v_montos      numeric[] := ARRAY[]::numeric[];
  v_locked_deal uuid;
BEGIN
  -- Lock order is deal -> operation, the same order automation uses
  -- (UPDATE deals fires trg_sync_operacion_desde_deal, which then updates
  -- remittance_operations). Locking the operation first could deadlock
  -- against a concurrent n8n deposit write and abort it.
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to verify deposits on this operation' USING ERRCODE = '42501';
  END IF;

  IF v_deal_id IS NULL THEN
    RAISE EXCEPTION 'operation has no linked deal' USING ERRCODE = '22023';
  END IF;

  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_id FOR UPDATE;

  SELECT status, deal_id
    INTO v_status_before, v_locked_deal
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_locked_deal IS DISTINCT FROM v_deal_id THEN
    RAISE EXCEPTION 'operation changed concurrently, retry' USING ERRCODE = '40001';
  END IF;

  IF v_status_before NOT IN ('deposit_verification', 'incident') THEN
    RAISE EXCEPTION 'operation is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  IF v_stage IS NULL OR v_stage NOT IN (v_por_verificar, v_incidencia) THEN
    RAISE EXCEPTION 'deal is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'items must be a JSON array' USING ERRCODE = '22023';
  END IF;

  v_items_len := jsonb_array_length(p_items);
  IF v_items_len < 1 OR v_items_len > 5 THEN
    RAISE EXCEPTION 'items must contain between 1 and 5 entries' USING ERRCODE = '22023';
  END IF;

  FOR v_i IN 0 .. v_items_len - 1 LOOP
    v_item := p_items -> v_i;

    v_ref := regexp_replace(coalesce(v_item ->> 'ref', ''), '[^0-9]', '', 'g');
    IF v_ref = '' THEN
      RAISE EXCEPTION 'each item ref must contain at least one digit' USING ERRCODE = '22023';
    END IF;

    BEGIN
      v_amount := (v_item ->> 'amount')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'each item amount must be a positive number' USING ERRCODE = '22023';
    END;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'each item amount must be greater than 0' USING ERRCODE = '22023';
    END IF;

    v_refs := v_refs || v_ref;
    v_montos := v_montos || v_amount;
  END LOOP;

  DECLARE
    v_resultado          text;
    v_metodo             text;
    v_todos_verificados  boolean;
    v_total_verificado   numeric;
    v_n_comprobantes     integer;
    v_detalle            jsonb;
    v_objetivo           numeric;
    v_depositado         numeric;
    v_saldo              numeric;
  BEGIN
    SELECT resultado, metodo, todos_verificados, total_verificado, n_comprobantes,
           detalle, objetivo, depositado, saldo
      INTO v_resultado, v_metodo, v_todos_verificados, v_total_verificado, v_n_comprobantes,
           v_detalle, v_objetivo, v_depositado, v_saldo
      FROM cerebro_cruzar_depositos(v_deal_id, v_refs, v_montos, v_stage, v_stage, v_stage, false);

    v_final := CASE v_resultado
                 WHEN 'verificado' THEN v_lista
                 WHEN 'verificado_de_mas' THEN v_incidencia
                 ELSE v_stage
               END;

    IF v_final = v_lista AND v_stage <> v_lista THEN
      UPDATE deals
         SET stage_id = v_lista,
             notes = replace(coalesce(notes, ''),
                              'VERIFICADO: casa con el correo de MMG',
                              'VERIFICADO EN PANEL: casa con el correo de MMG')
                     || chr(10) || 'VERIFICADO EN PANEL por un operador del CRM',
             updated_at = now()
       WHERE id = v_deal_id;
    ELSIF v_final <> v_stage THEN
      UPDATE deals SET stage_id = v_final, updated_at = now() WHERE id = v_deal_id;
    END IF;

    SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_deposit_verification',
            wacrm_current_actor(),
            jsonb_build_object('status', v_status_before, 'deal_stage', v_stage),
            jsonb_build_object('status', v_status_after, 'deal_stage', v_final,
                                'resultado', v_resultado, 'metodo', v_metodo, 'detalle', v_detalle,
                                'objetivo', v_objetivo, 'depositado', v_depositado, 'saldo', v_saldo));

    RETURN jsonb_build_object(
      'resultado', v_resultado,
      'metodo', v_metodo,
      'todos_verificados', v_todos_verificados,
      'total_verificado', v_total_verificado,
      'n_comprobantes', v_n_comprobantes,
      'detalle', v_detalle,
      'objetivo', v_objetivo,
      'depositado', v_depositado,
      'saldo', v_saldo,
      'stage_changed', (v_final <> v_stage),
      'new_status', v_status_after
    );
  END;
END $$;


-- ---------------------------------------------------------------------
-- 4. crm_forzar_verificacion — admin-only forced verify, no cross-check.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_forzar_verificacion(p_operation_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_por_verificar CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista         CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_incidencia    CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';

  v_account_id     uuid;
  v_status_before  text;
  v_status_after   text;
  v_deal_id        uuid;
  v_stage          uuid;
  v_reason         text;
  v_locked_deal    uuid;
BEGIN
  -- Lock order deal -> operation, matching automation (see crm_verificar_deposito).
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to force-verify this operation' USING ERRCODE = '42501';
  END IF;

  v_reason := btrim(coalesce(p_reason, ''));
  IF length(v_reason) < 5 THEN
    RAISE EXCEPTION 'reason must be at least 5 characters' USING ERRCODE = '22023';
  END IF;

  IF v_deal_id IS NULL THEN
    RAISE EXCEPTION 'operation has no linked deal' USING ERRCODE = '22023';
  END IF;

  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_id FOR UPDATE;

  SELECT status, deal_id
    INTO v_status_before, v_locked_deal
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_locked_deal IS DISTINCT FROM v_deal_id THEN
    RAISE EXCEPTION 'operation changed concurrently, retry' USING ERRCODE = '40001';
  END IF;

  IF v_status_before NOT IN ('deposit_verification', 'incident') THEN
    RAISE EXCEPTION 'operation is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  IF v_stage IS NULL OR v_stage NOT IN (v_por_verificar, v_incidencia) THEN
    RAISE EXCEPTION 'deal is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  UPDATE deals
     SET stage_id = v_lista,
         notes = replace(coalesce(notes, ''),
                          'VERIFICADO: casa con el correo de MMG',
                          'VERIFICADO EN PANEL: casa con el correo de MMG')
                 || chr(10) || 'VERIFICACION FORZADA EN PANEL: ' || v_reason,
         updated_at = now()
   WHERE id = v_deal_id;

  SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_forced_verification',
          wacrm_current_actor(), v_reason,
          jsonb_build_object('status', v_status_before, 'deal_stage', v_stage),
          jsonb_build_object('status', v_status_after, 'deal_stage', v_lista));

  RETURN jsonb_build_object('new_status', v_status_after);
END $$;


-- ---------------------------------------------------------------------
-- 5. Grants.
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION crm_comprobantes_de_operacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_comprobantes_de_operacion(uuid) TO authenticated;

REVOKE ALL ON FUNCTION crm_verificar_deposito(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_verificar_deposito(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION crm_forzar_verificacion(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_forzar_verificacion(uuid, text) TO authenticated;
