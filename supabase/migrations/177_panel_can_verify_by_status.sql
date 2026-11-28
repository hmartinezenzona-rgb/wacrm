-- =====================================================================
-- 177 — the panel can verify or force any operation awaiting verification
--
-- Real case: Onelsi 5927570987 (2026-09-29) sent the same receipt twice; the
-- burst was refused ("la misma referencia viene repetida") and the operation
-- went to incident. The admin could neither verify nor force it from the panel:
-- crm_comprobantes_de_operacion's can_verify also required deals.stage_id to be
-- "Por verificar" or "Incidencia", and since 114 nothing writes deals.stage_id.
-- A deal opened by "Registrar beneficiario auto" stays in stage "Nueva" forever,
-- so the buttons were hidden. On 2026-10-01 all 4 open operations awaiting
-- verification were affected. crm_verificar_deposito / crm_forzar_verificacion
-- already gate on the operation status only.
--
-- Only that condition changes; the rest is 099's body (prosrc md5 f82030e6...).
-- The deal-free reader (159/165, not in production) already has this rule.
-- ROLLBACK: ROLLBACK-177-panel-can-verify-by-status.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.crm_comprobantes_de_operacion(p_operation_id uuid)
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

  -- (177) The panel's Verify / Force buttons follow the OPERATION status only. The deal
  -- stage gate hid them on every operation whose deal was opened by a beneficiary (stage
  -- "Nueva") and later got its deposit: 114 stopped writing deals.stage_id, so the stage
  -- never moved (Onelsi c31c8b3a, 2026-09-29, and 3 more open operations on 2026-10-01).
  v_can_verify := v_status IN ('deposit_verification', 'incident')
                  AND v_deal_id IS NOT NULL;

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
