-- =====================================================================
-- 159 — remittance_operation_receipts gets block_index; panel reads it
--
-- PROBLEM (task deals-phase1 item 4): crm_comprobantes_de_operacion (099)
-- reads receipts from deals.notes with a regex loop. Since migration 156
-- every receipt already lives as a row in remittance_operation_receipts
-- (columns: operation_id, conversation_id, comp_id, amount numeric,
-- currency, receipt_status, recipient, via, reference, receipt_date,
-- correct_destination, source, created_at), but there is no ordering
-- column yet and the panel still parses notes.
--
-- FIX
--   1. Add block_index int to remittance_operation_receipts and backfill
--      it from cerebro_parsear_comprobantes (156) so receipts are
--      ordered the same way the notes parser had them.
--   2. Rewrite crm_comprobantes_de_operacion to read from the new table
--      instead of deals.notes, so an operation without a deal (deal_id
--      IS NULL) can still be read by the panel. The function body is the
--      099 definition with ONLY the changes listed below; everything
--      else — signature, RETURNS, LANGUAGE, STABLE, SECURITY DEFINER,
--      search_path, comments, output keys, grants — stays byte-identical.
--
-- CHANGES TO THE 099 FUNCTION BODY
--   a. v_stage_id / v_notes: keep the variables so the function still
--      compiles, but drop the SELECT … FROM deals that reads them
--      (lines 138-139) and remove v_notes from the can_verify predicate.
--   b. The dePOSITO/COMP/Ref loop (lines 157-208) becomes a loop over
--      SELECT comp_id, amount, currency, reference
--        FROM remittance_operation_receipts
--       WHERE operation_id = p_operation_id
--         AND comp_id IS NOT NULL
--       ORDER BY block_index NULLS LAST, created_at, id;
--      the per-row local vars stay the same names; v_amount_raw is gone
--      because the amount is already numeric (old text-with-commas →
--      new numeric value is IDENTICAL, e.g. '40,000' → 40000).
--   c. The depositos_mmg lookup (old line 178) changes WHERE deal_id =
--      v_deal_id AND trans_id = v_ref to WHERE operation_id =
--      p_operation_id AND trans_id = v_ref (rest identical).
--   d. The cerebro_saldo_envio call (old line 142) stays where it is
--      for deal-linked operations; when deal_id IS NULL the objetivo/
--      depositado/saldo/moneda remain NULL, same as before.
--
-- ROLLBACK: ROLLBACK-159-receipts-block-index-and-panel-reader.sql
-- Guarded by supabase/staging/assertions/panel-reader-receipts.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- a. Add block_index + backfill
-- ---------------------------------------------------------------------

ALTER TABLE public.remittance_operation_receipts
  ADD COLUMN IF NOT EXISTS block_index int;

-- Backfill from every deal's notes that has a matching operation.
UPDATE remittance_operation_receipts r
   SET block_index = p.block_index
  FROM remittance_operations o
  JOIN deals d ON d.id = o.deal_id
 CROSS JOIN LATERAL cerebro_parsear_comprobantes(d.notes) p
 WHERE r.operation_id = o.id
   AND r.comp_id IS NOT NULL
   AND p.comp_id = r.comp_id
   AND r.block_index IS NULL;

-- ---------------------------------------------------------------------
-- b. Rewrite crm_comprobantes_de_operacion (099 body, panel-reader)
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

  -- New per-receipt variables for the structured-reader loop.
  v_r_comp      text;
  v_r_amount    numeric;
  v_r_currency  text;
  v_r_ref       text;
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
    SELECT stage_id INTO v_stage_id FROM deals WHERE id = v_deal_id;

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

  -- (159) Test on the operation's own status, not on deals.stage_id.
  v_can_verify := v_status IN ('deposit_verification', 'incident')
                  AND v_deal_id IS NOT NULL;

  -- (159) Read receipts from the structured table instead of deals.notes.
  FOR v_r_comp, v_r_amount, v_r_currency, v_r_ref IN
    SELECT comp_id, amount, currency, reference
      FROM remittance_operation_receipts
     WHERE operation_id = p_operation_id
       AND comp_id IS NOT NULL
     ORDER BY block_index NULLS LAST, created_at, id
  LOOP
    IF v_r_comp = ANY (v_seen_comp) THEN
      CONTINUE;
    END IF;
    v_seen_comp := v_seen_comp || v_r_comp;

    v_amount     := v_r_amount;
    v_currency   := v_r_currency;
    v_ref        := v_r_ref;

    v_m_trans_id := NULL; v_m_amount := NULL; v_m_currency := NULL;
    v_m_received_at := NULL; v_m_consumed_at := NULL;
    IF v_ref IS NOT NULL THEN
      SELECT trans_id, monto, moneda, recibido_en, consumido_en
        INTO v_m_trans_id, v_m_amount, v_m_currency, v_m_received_at, v_m_consumed_at
        FROM depositos_mmg
       WHERE operation_id = p_operation_id AND trans_id = v_ref AND anulado_en IS NULL;
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
     WHERE ch.comp_id = v_r_comp
     ORDER BY m.created_at DESC NULLS LAST
     LIMIT 1;

    v_receipts := v_receipts || jsonb_build_object(
      'comp_id', v_r_comp,
      'message_id', v_msg_id,
      'media_url', v_msg_media_url,
      'received_at', coalesce(v_msg_created_at, v_ch_received_at),
      'declared_amount', v_amount,
      'declared_currency', v_currency,
      'declared_ref', v_ref,
      'matched_deposit', v_matched_deposit
    );
  END LOOP;

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
-- c. Grants (same as 099)
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION crm_comprobantes_de_operacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_comprobantes_de_operacion(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';