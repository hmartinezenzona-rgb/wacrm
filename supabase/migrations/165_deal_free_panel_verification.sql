-- =====================================================================
-- 165 — deal-free operations verify from the panel
--
-- PROBLEM
--   Two panel RPCs refuse to run at all for an operation with deal_id
--   IS NULL, which is exactly what the deal-free cutover path
--   (cerebro_crear_operacion, 161) produces:
--
--     crm_verificar_deposito   (114:1153)  IF v_deal_id IS NULL THEN
--     crm_forzar_verificacion  (114:1308)    RAISE EXCEPTION
--                                            'operation has no linked deal'
--
--   A deal-free operation is created by cerebro_crear_operacion /
--   cerebro_registrar_deposito (160/161) with deal_id IS NULL, so the
--   feature's own cutover path is blocked by the feature's own legacy
--   read. This migration unblocks it. A third object,
--   crm_comprobantes_de_operacion (159), already returns instead of
--   raising for a deal-free operation, but its three deal-keyed reads
--   were skipped by an IF v_deal_id IS NOT NULL guard, so the panel saw
--   can_verify = false and empty objetivo / depositado / saldo /
--   consumed_deposits. That guard collapses too.
--
-- WHAT CHANGES (and what deliberately does NOT)
--   * The `operation has no linked deal` guard is removed from both
--     RPCs. That guard is the bug.
--   * The deal lock (`PERFORM ... FOR UPDATE`, 114:1157 / 114:1312)
--     becomes conditional on a deal existing, exactly the shape
--     crm_entregar_operacion already uses (143:222).
--   * crm_verificar_deposito passes the OPERATION id to
--     cerebro_cruzar_depositos. 160 already made that function accept
--     either flavour via cerebro_resolve_op_id, and for a deal-linked
--     operation the resolver returns the same operation id the deal
--     resolved to, so the crossing engine sees the identical input.
--   * crm_comprobantes_de_operacion drops the dead v_stage_id read
--     (159:137) and repoints cerebro_saldo_envio(v_deal_id) ->
--     cerebro_saldo_operacion(p_operation_id) and
--     depositos_mmg.deal_id -> depositos_mmg.operation_id. For a
--     deal-linked operation cerebro_saldo_envio already delegates to
--     cerebro_saldo_operacion (158:276), and 158's trigger/backfill keep
--     operation_id populated on depositos_mmg, so the rows are the same.
--
--   * EVERY UPDATE deals ... writes stays. Those notes are still read
--     today by live n8n workflows (the `Leer secreto` node in
--     `WaCRM - Notificar cliente por etapa del deal`, and `Historial
--     contacto` / `Contexto conversacion` in the production
--     `Cerebro v2`). Deleting the notes write would change what a live
--     workflow sees. Each one therefore stays, wrapped in
--     `IF v_deal_id IS NOT NULL`. For an operation that HAS a deal,
--     byte-for-byte nothing changes.
--
--   CONSEQUENCE: because every notes/updated_at write stays,
--   crm_verificar_deposito and crm_forzar_verificacion still name the
--   deals table after this slice and REMAIN in the set of objects
--   referencing it. That is the correct outcome. Only
--   crm_comprobantes_de_operacion leaves that set here. These two
--   functions become fully deal-free only once the live n8n readers of
--   deals.notes are retired — later work, deliberately sequenced after
--   this slice.
--
-- ROLLBACK: ROLLBACK-165-deal-free-panel-verification.sql
-- Guarded by supabase/staging/assertions/deal-free-panel-verification.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. crm_comprobantes_de_operacion — read a deal-free operation
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_comprobantes_de_operacion(p_operation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_por_verificar CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_incidencia    CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';

  v_account_id  uuid;
  v_status      text;
  v_deal_id     uuid;
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

  -- (165) These three reads used to sit behind IF v_deal_id IS NOT NULL,
  -- which is why a deal-free operation got NULLs and an empty
  -- consumed_deposits. They are operation-keyed now, so they run always.
  SELECT objetivo, depositado, saldo, moneda
    INTO v_objetivo, v_depositado, v_saldo, v_moneda
    FROM cerebro_saldo_operacion(p_operation_id);

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'trans_id', trans_id, 'amount', monto, 'currency', moneda,
           'received_at', recibido_en, 'consumed_at', consumido_en
         ) ORDER BY consumido_en), '[]'::jsonb)
    INTO v_consumed
    FROM depositos_mmg
   WHERE operation_id = p_operation_id AND consumido_en IS NOT NULL AND anulado_en IS NULL;

  -- (159) Test on the operation's own status, not on deals.stage_id.
  -- (165) The deal is no longer a precondition for verifying.
  v_can_verify := v_status IN ('deposit_verification', 'incident');

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
-- 2. crm_verificar_deposito — verify without a deal
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_verificar_deposito(p_operation_id uuid, p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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
BEGIN
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

  -- (165) A deal-free operation is verifiable; the old guard is gone. The
  -- deal lock stays, but only while a deal exists, so lock ordering
  -- against concurrent writers on that row is unchanged.
  IF v_deal_id IS NOT NULL THEN
    PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;
  END IF;

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before NOT IN ('deposit_verification', 'incident') THEN
    RAISE EXCEPTION 'operation is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  -- Equivalent "current stage" for the legacy cross-reference engine's
  -- no-op-stage input contract (p_stage_ok = p_stage_incidencia =
  -- p_stage_esperado below): derived from remittance_operations.status,
  -- not read from deals.stage_id (114).
  v_stage := CASE v_status_before
               WHEN 'deposit_verification' THEN v_por_verificar
               WHEN 'incident'             THEN v_incidencia
             END;

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
    -- (165) The crossing engine takes the operation id (160 made it accept
    -- either flavour). For a deal-linked operation cerebro_resolve_op_id
    -- maps the deal to this same operation, so the input is identical.
    SELECT resultado, metodo, todos_verificados, total_verificado, n_comprobantes,
           detalle, objetivo, depositado, saldo
      INTO v_resultado, v_metodo, v_todos_verificados, v_total_verificado, v_n_comprobantes,
           v_detalle, v_objetivo, v_depositado, v_saldo
      FROM cerebro_cruzar_depositos(p_operation_id, v_refs, v_montos, v_stage, v_stage, v_stage, false);

    v_final := CASE v_resultado
                 WHEN 'verificado' THEN v_lista
                 WHEN 'verificado_de_mas' THEN v_incidencia
                 ELSE v_stage
               END;

    -- (165) The notes and updated_at writes stay, unchanged, for a row
    -- that still has a deal — a live workflow reads those notes. A
    -- deal-free operation has no such row to annotate; its trail is the
    -- remittance_admin_audit row below, written either way.
    IF v_deal_id IS NOT NULL THEN
      IF v_final = v_lista AND v_stage <> v_lista THEN
        UPDATE deals
           SET notes = replace(coalesce(notes, ''),
                                'VERIFICADO: casa con el correo de MMG',
                                'VERIFICADO EN PANEL: casa con el correo de MMG')
                       || chr(10) || 'VERIFICADO EN PANEL por un operador del CRM',
               updated_at = now()
         WHERE id = v_deal_id;
      ELSIF v_final <> v_stage THEN
        UPDATE deals SET updated_at = now() WHERE id = v_deal_id;
      END IF;
    END IF;

    IF v_final <> v_stage THEN
      -- (114) Direct write replacing the retired bridge trigger.
      UPDATE remittance_operations
         SET status = cerebro_estado_desde_etapa(v_final)
       WHERE id = p_operation_id;
    END IF;

    SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_deposit_verification',
            wacrm_current_actor(),
            jsonb_build_object('status', v_status_before),
            jsonb_build_object('status', v_status_after,
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
-- 3. crm_forzar_verificacion — force-verify without a deal
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_forzar_verificacion(p_operation_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_account_id     uuid;
  v_status_before  text;
  v_status_after   text;
  v_deal_id        uuid;
  v_reason         text;
BEGIN
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

  -- (165) A deal-free operation is force-verifiable; the old guard is gone.
  -- The deal lock stays, but only while a deal exists.
  IF v_deal_id IS NOT NULL THEN
    PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;
  END IF;

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before NOT IN ('deposit_verification', 'incident') THEN
    RAISE EXCEPTION 'operation is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  -- (165) The notes write stays, unchanged, for a row that still has a deal.
  -- The status write and the audit row below are the operation-keyed
  -- equivalent and run either way.
  IF v_deal_id IS NOT NULL THEN
    UPDATE deals
       SET notes = replace(coalesce(notes, ''),
                            'VERIFICADO: casa con el correo de MMG',
                            'VERIFICADO EN PANEL: casa con el correo de MMG')
                   || chr(10) || 'VERIFICACION FORZADA EN PANEL: ' || v_reason,
           updated_at = now()
     WHERE id = v_deal_id;
  END IF;

  -- (114) Direct write replacing the retired bridge trigger.
  UPDATE remittance_operations
     SET status = 'ready_to_transfer'
   WHERE id = p_operation_id;

  SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_forced_verification',
          wacrm_current_actor(), v_reason,
          jsonb_build_object('status', v_status_before),
          jsonb_build_object('status', v_status_after));

  RETURN jsonb_build_object('new_status', v_status_after);
END $$;


-- ---------------------------------------------------------------------
-- 4. Grants — the live ACL is preserved exactly.
--
-- CREATE OR REPLACE keeps proacl, and these two statements are the same
-- pair 114/159 already ran, so the effective ACL is unchanged:
--   {postgres=X/postgres, service_role=X/postgres, authenticated=X/postgres}
-- PUBLIC and anon stay revoked; authenticated keeps EXECUTE, because the
-- panel calls all three as authenticated.
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION crm_comprobantes_de_operacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_comprobantes_de_operacion(uuid) TO authenticated;

REVOKE ALL ON FUNCTION crm_verificar_deposito(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_verificar_deposito(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION crm_forzar_verificacion(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_forzar_verificacion(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
