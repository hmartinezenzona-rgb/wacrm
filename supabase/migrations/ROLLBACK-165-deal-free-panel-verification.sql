-- =====================================================================
-- ROLLBACK-165 — restore the three panel RPCs to their pre-165 bodies
--
-- 165 changed nothing but these three functions: no table, column,
-- index, trigger or view was touched, and no data was migrated. The
-- rollback therefore re-creates the exact bodies that were live before
-- 165 — crm_comprobantes_de_operacion from 159, crm_verificar_deposito
-- and crm_forzar_verificacion from 114 — taken verbatim from
-- pg_get_functiondef() on staging before the migration was applied.
--
-- Restoring crm_verificar_deposito and crm_forzar_verificacion brings
-- back the `operation has no linked deal` guard, so a deal-free
-- operation once again cannot be verified from the panel. That is the
-- pre-165 behaviour and is the point of a rollback.
--
-- ACL: CREATE OR REPLACE preserves proacl, so the grants
-- {postgres, service_role, authenticated} are untouched by this file.
-- =====================================================================

-- >>> crm_comprobantes_de_operacion p_operation_id uuid
CREATE OR REPLACE FUNCTION public.crm_comprobantes_de_operacion(p_operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
END $function$;


-- >>> crm_forzar_verificacion p_operation_id uuid, p_reason text
CREATE OR REPLACE FUNCTION public.crm_forzar_verificacion(p_operation_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  IF v_deal_id IS NULL THEN
    RAISE EXCEPTION 'operation has no linked deal' USING ERRCODE = '22023';
  END IF;

  PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before NOT IN ('deposit_verification', 'incident') THEN
    RAISE EXCEPTION 'operation is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  UPDATE deals
     SET notes = replace(coalesce(notes, ''),
                          'VERIFICADO: casa con el correo de MMG',
                          'VERIFICADO EN PANEL: casa con el correo de MMG')
                 || chr(10) || 'VERIFICACION FORZADA EN PANEL: ' || v_reason,
         updated_at = now()
   WHERE id = v_deal_id;

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
END $function$;


-- >>> crm_verificar_deposito p_operation_id uuid, p_items jsonb
CREATE OR REPLACE FUNCTION public.crm_verificar_deposito(p_operation_id uuid, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  IF v_deal_id IS NULL THEN
    RAISE EXCEPTION 'operation has no linked deal' USING ERRCODE = '22023';
  END IF;

  PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;

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
         SET notes = replace(coalesce(notes, ''),
                              'VERIFICADO: casa con el correo de MMG',
                              'VERIFICADO EN PANEL: casa con el correo de MMG')
                     || chr(10) || 'VERIFICADO EN PANEL por un operador del CRM',
             updated_at = now()
       WHERE id = v_deal_id;
    ELSIF v_final <> v_stage THEN
      UPDATE deals SET updated_at = now() WHERE id = v_deal_id;
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
END $function$;

-- ---------------------------------------------------------------------
-- ACL — unchanged by the rollback; re-asserted for symmetry with 165.
-- PUBLIC and anon stay revoked, authenticated keeps EXECUTE.
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION crm_comprobantes_de_operacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_comprobantes_de_operacion(uuid) TO authenticated;

REVOKE ALL ON FUNCTION crm_verificar_deposito(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_verificar_deposito(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION crm_forzar_verificacion(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_forzar_verificacion(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
