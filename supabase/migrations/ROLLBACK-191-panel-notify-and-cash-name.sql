-- ROLLBACK of 191_panel_notify_and_cash_name.sql: back to the 190-era signatures (no p_notify, no p_name, a typed
-- reason required). Names already stored on cash recipients stay in remittance_beneficiaries.name.
-- Restore the notifiers' closed_manually rule BEFORE running this (they read customer_notice_muted_for since 191).
DROP FUNCTION public.crm_registrar_datos_entrega_efectivo(uuid, text, text, text, text);
DROP FUNCTION public.crm_forzar_verificacion(uuid, text, boolean);
DROP FUNCTION public.crm_entregar_operacion(uuid, jsonb, boolean);
DROP FUNCTION public.crm_verificar_deposito(uuid, jsonb, boolean);
DROP FUNCTION public.crm_cerrar_operacion_manual(uuid, text, boolean);
DROP FUNCTION public.crm_eliminar_operacion(uuid, text);
ALTER TABLE remittance_operations DROP COLUMN customer_notice_muted_for;

CREATE OR REPLACE FUNCTION public.crm_registrar_datos_entrega_efectivo(p_conv uuid, p_phone text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_id_photo_wamid text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op_id       uuid;
  v_account_id  uuid;
  v_existing    remittance_beneficiaries%ROWTYPE;
  v_row         remittance_beneficiaries%ROWTYPE;
  v_new_phone   text;
  v_new_address text;
  v_new_photo   text;
  v_changed     boolean;
  v_next_block  integer;
  v_was_complete boolean;
  v_is_complete  boolean;
  v_cliente     text;
BEGIN
  IF p_conv IS NULL THEN
    RAISE EXCEPTION 'conversation id is required' USING ERRCODE = '22023';
  END IF;

  SELECT o.id, o.account_id INTO v_op_id, v_account_id
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv
     AND o.service_type = 'remesa'
     AND o.delivery_method = 'efectivo_usd'
     AND o.status NOT IN ('completed', 'cancelled')
   ORDER BY o.created_at DESC
   LIMIT 1
   FOR UPDATE;

  IF v_op_id IS NULL THEN
    RAISE EXCEPTION 'no open cash-delivery (efectivo_usd) operation for this conversation'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing
    FROM remittance_beneficiaries
   WHERE operation_id = v_op_id AND beneficiary_type = 'efectivo_usd' AND status = 'vigente'
   LIMIT 1;

  v_new_phone   := coalesce(p_phone, v_existing.phone);
  v_new_address := coalesce(p_address, v_existing.address);
  v_new_photo   := coalesce(p_id_photo_wamid, v_existing.id_photo_wamid);

  IF v_existing.id IS NOT NULL THEN
    v_changed := v_new_phone   IS DISTINCT FROM v_existing.phone
              OR v_new_address IS DISTINCT FROM v_existing.address
              OR v_new_photo   IS DISTINCT FROM v_existing.id_photo_wamid;
  ELSE
    v_changed := p_phone IS NOT NULL OR p_address IS NOT NULL OR p_id_photo_wamid IS NOT NULL;
  END IF;

  v_was_complete := v_existing.id IS NOT NULL
                AND v_existing.phone IS NOT NULL
                AND v_existing.address IS NOT NULL
                AND v_existing.id_photo_wamid IS NOT NULL;

  IF NOT v_changed THEN
    v_row := v_existing;
  ELSE
    IF v_existing.id IS NOT NULL THEN
      UPDATE remittance_beneficiaries
         SET status = 'reemplazado', replaced_at = now()
       WHERE id = v_existing.id;
    END IF;

    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block
      FROM remittance_beneficiaries WHERE operation_id = v_op_id;

    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, phone, address, id_photo_wamid,
      position, status, source, block_index
    ) VALUES (
      v_op_id, 'efectivo_usd', v_new_phone, v_new_address, v_new_photo,
      1, 'vigente', 'reparto_auto', v_next_block
    ) RETURNING * INTO v_row;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_row.id, 'phone,address,id_photo_wamid',
            'automation_cash_delivery_data_registered', wacrm_current_actor(),
            CASE WHEN v_existing.id IS NULL THEN NULL ELSE
              jsonb_build_object('phone', v_existing.phone, 'address', v_existing.address, 'id_photo_wamid', v_existing.id_photo_wamid)
            END,
            jsonb_build_object('phone', v_row.phone, 'address', v_row.address, 'id_photo_wamid', v_row.id_photo_wamid));
  END IF;

  v_is_complete := v_row.phone IS NOT NULL
               AND v_row.address IS NOT NULL
               AND v_row.id_photo_wamid IS NOT NULL;

  -- (151) Aviso al admin, SOLO en la transicion a completo. El chat NO se
  -- asigna ni se pausa: el bot sigue atendiendo (decision del usuario).
  IF v_is_complete AND NOT v_was_complete THEN
    SELECT coalesce(nullif(c.name, ''), c.phone) || ' (' || c.phone || ')'
      INTO v_cliente
      FROM conversations v JOIN contacts c ON c.id = v.contact_id
     WHERE v.id = p_conv;

    INSERT INTO notifications (account_id, user_id, type, title, body)
    SELECT v_account_id, p.user_id, 'entrega_efectivo_lista',
           'Entrega en efectivo lista para coordinar: ' || coalesce(v_cliente, 'cliente'),
           'El cliente ' || coalesce(v_cliente, '') || ' ya dio los tres datos de quien recibe el efectivo.'
           || chr(10) || chr(10)
           || 'Telefono: ' || v_row.phone || chr(10)
           || 'Direccion: ' || v_row.address || chr(10)
           || 'Foto del carnet: recibida en el chat.'
           || chr(10) || chr(10)
           || 'Falta coordinar zona y horario de la entrega. El bot sigue atendiendo la conversacion.'
      FROM profiles p
     WHERE p.account_id = v_account_id
       AND p.account_role IN ('owner', 'admin')
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'phone', v_row.phone,
    'address', v_row.address,
    'id_photo_wamid', v_row.id_photo_wamid,
    'complete', v_is_complete,
    'changed', v_changed
  );
END $function$;

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
END $function$;

CREATE OR REPLACE FUNCTION public.crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- (164) The ordering lock that stood here — a `FOR UPDATE` on the legacy
  -- deal row — was removed with the legacy table. It only serialized
  -- against retired n8n notes/value writes and touched no result.

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
END $function$;

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
END $function$;

CREATE OR REPLACE FUNCTION public.crm_cerrar_operacion_manual(p_operation_id uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_status_before text;
  v_completed_at  timestamptz;
  v_motivo        text := btrim(coalesce(p_motivo, ''));
BEGIN
  SELECT account_id, status INTO v_account_id, v_status_before
    FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'only an owner or admin can close an operation manually' USING ERRCODE = '42501';
  END IF;
  IF v_motivo = '' OR length(v_motivo) > 500 THEN
    RAISE EXCEPTION 'a reason (1 to 500 characters) is required' USING ERRCODE = '22023';
  END IF;
  IF v_status_before NOT IN ('ready_to_transfer', 'transferring') THEN
    RAISE EXCEPTION 'only a verified operation can be closed manually (status %)', v_status_before USING ERRCODE = '22023';
  END IF;

  -- One statement, like crm_entregar_operacion: completed_at (040) and the calculator feed read this row image.
  UPDATE remittance_operations
     SET status = 'completed', delivery_mode = 'closed_manually', delivered_by = auth.uid()
   WHERE id = p_operation_id
  RETURNING completed_at INTO v_completed_at;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_manual_close', wacrm_current_actor(),
          v_motivo, jsonb_build_object('status', v_status_before),
          jsonb_build_object('status', 'completed', 'delivery_mode', 'closed_manually'));

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;

CREATE OR REPLACE FUNCTION public.crm_eliminar_operacion(p_operation_id uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_status_before text;
  v_motivo        text := btrim(coalesce(p_motivo, ''));
BEGIN
  SELECT account_id, status INTO v_account_id, v_status_before
    FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'only an owner or admin can delete an operation' USING ERRCODE = '42501';
  END IF;
  IF v_motivo = '' OR length(v_motivo) > 500 THEN
    RAISE EXCEPTION 'a reason (1 to 500 characters) is required' USING ERRCODE = '22023';
  END IF;
  IF v_status_before IN ('completed', 'cancelled', 'ready_to_transfer', 'transferring') THEN
    RAISE EXCEPTION 'an operation that is % cannot be deleted', v_status_before USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM depositos_mmg d
              WHERE d.operation_id = p_operation_id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL) THEN
    RAISE EXCEPTION 'an operation with a verified deposit cannot be deleted' USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_operations SET status = 'cancelled' WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_operation_deleted', wacrm_current_actor(),
          v_motivo, jsonb_build_object('status', v_status_before), jsonb_build_object('status', 'cancelled'));

  RETURN jsonb_build_object('new_status', 'cancelled');
END $function$;


REVOKE ALL ON FUNCTION public.crm_registrar_datos_entrega_efectivo(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crm_registrar_datos_entrega_efectivo(uuid, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.crm_forzar_verificacion(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_forzar_verificacion(uuid, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.crm_entregar_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_entregar_operacion(uuid, jsonb) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.crm_verificar_deposito(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_verificar_deposito(uuid, jsonb) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.crm_cerrar_operacion_manual(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_cerrar_operacion_manual(uuid, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.crm_eliminar_operacion(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_eliminar_operacion(uuid, text) TO authenticated, service_role;
