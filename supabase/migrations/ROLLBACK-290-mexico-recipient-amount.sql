-- ROLLBACK 290: back to the 271 bodies and signature (no amount on México recipients).
DROP FUNCTION IF EXISTS public.cerebro_guardar_beneficiario_mexico(uuid, text, text, text, text, text, text, integer, boolean, numeric);

CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario_mexico(p_conv uuid, p_tipo text, p_clabe text, p_banco text, p_nombre text, p_telefono text, p_exec text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tipo   text := lower(btrim(coalesce(p_tipo, '')));
  v_exec   text := nullif(btrim(coalesce(p_exec, '')), '');
  -- The tool passes its own name and the execution in p_exec: 'agent:<tool> n8n:<execution>'. No prefix = the default tool.
  v_actor  text;
  v_op     record;
  v_nombre text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_banco  text := nullif(btrim(coalesce(p_banco, '')), '');
  v_clabe  text;
  v_tel    text := nullif(regexp_replace(coalesce(p_telefono, ''), '[^0-9]', '', 'g'), '');
  v_ex     remittance_beneficiaries%ROWTYPE;
  v_id     uuid;
  v_pos    int;
  v_block  int;
  v_lock   jsonb;
BEGIN
  v_actor := CASE WHEN v_exec LIKE 'agent:%' THEN split_part(v_exec, ' ', 1) ELSE 'agent:registrar_destinatario_mexico' END;

  IF v_tipo NOT IN ('mexico_cuenta', 'mexico_retiro') THEN
    RETURN jsonb_build_object('ok', false, 'beneficiary_id', NULL,
      'mensaje', 'El tipo de destinatario debe ser mexico_cuenta (cuenta bancaria) o mexico_retiro (retiro sin tarjeta en Coppel o BBVA).');
  END IF;

  SELECT o.id, o.account_id, o.delivery_method, o.admin_locked_fields INTO v_op
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv AND o.service_type = 'mexico' AND o.status NOT IN ('completed', 'cancelled')
   ORDER BY o.created_at DESC LIMIT 1
   FOR UPDATE;
  IF v_op.id IS NULL THEN
    -- (275) The agent declared mexico and nothing is open yet: the declared operation opens now (0 GYD, awaiting its deposit).
    IF _cerebro_operacion_declarada(p_conv, 'mexico', v_actor) IS NOT NULL THEN
      SELECT o.id, o.account_id, o.delivery_method, o.admin_locked_fields INTO v_op
        FROM remittance_operations o
       WHERE o.conversation_id = p_conv AND o.service_type = 'mexico' AND o.status NOT IN ('completed', 'cancelled')
       ORDER BY o.created_at DESC LIMIT 1
       FOR UPDATE;
    END IF;
  END IF;
  IF v_op.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'beneficiary_id', NULL,
      'mensaje', 'No hay un envio a Mexico abierto en esta conversacion: no se guardo el destinatario. Primero hay que declarar el servicio mexico o registrar el deposito.');
  END IF;

  IF v_nombre IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'beneficiary_id', NULL,
      'mensaje', CASE WHEN v_tipo = 'mexico_cuenta' THEN 'Falta el nombre completo del titular de la cuenta.' ELSE 'Falta el nombre completo de quien retira.' END);
  END IF;
  IF v_tel IS NOT NULL AND v_tel !~ '^[0-9]{8,15}$' THEN
    RETURN jsonb_build_object('ok', false, 'beneficiary_id', NULL, 'mensaje', 'El telefono no es valido: debe tener entre 8 y 15 digitos.');
  END IF;

  IF v_tipo = 'mexico_cuenta' THEN
    v_clabe := regexp_replace(coalesce(p_clabe, ''), '[ -]', '', 'g');
    IF v_clabe !~ '^[0-9]{18}$' THEN
      RETURN jsonb_build_object('ok', false, 'beneficiary_id', NULL,
        'mensaje', 'La CLABE debe tener exactamente 18 digitos (tiene ' || length(v_clabe) || '). Pidesela de nuevo al cliente, no la adivines.');
    END IF;
    IF v_banco IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'beneficiary_id', NULL, 'mensaje', 'Falta el banco de la cuenta (por ejemplo Banco Azteca o Mercado Pago).');
    END IF;
  ELSE
    v_clabe := NULL;
    v_banco := CASE lower(coalesce(v_banco, '')) WHEN 'coppel' THEN 'Coppel' WHEN 'bbva' THEN 'BBVA' END;
    IF v_banco IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'beneficiary_id', NULL, 'mensaje', 'El retiro sin tarjeta solo se hace en Coppel o BBVA: pregunta cual prefiere el cliente.');
    END IF;
    IF v_tel IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'beneficiary_id', NULL, 'mensaje', 'Falta el telefono de quien retira (a ese numero llega el codigo de retiro).');
    END IF;
  END IF;

  -- Same CLABE (or the same withdrawal receiver and phone) already current: it is updated, never duplicated.
  IF v_tipo = 'mexico_cuenta' THEN
    SELECT * INTO v_ex FROM remittance_beneficiaries b
     WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.clabe = v_clabe LIMIT 1;
  ELSE
    SELECT * INTO v_ex FROM remittance_beneficiaries b
     WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.beneficiary_type = 'mexico_retiro'
       AND b.phone = v_tel AND b.bank_name = v_banco LIMIT 1;
  END IF;

  IF v_ex.id IS NOT NULL THEN
    UPDATE remittance_beneficiaries SET name = v_nombre, bank_name = v_banco, phone = coalesce(v_tel, phone) WHERE id = v_ex.id;
    v_id := v_ex.id;
  ELSE
    SELECT coalesce(max(position), 0) + 1 INTO v_pos FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_block FROM remittance_beneficiaries WHERE operation_id = v_op.id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, clabe, bank_name, position, block_index, source, status)
    VALUES (v_op.id, v_tipo, v_nombre, v_tel, v_clabe, v_banco, v_pos, v_block, 'agente', 'vigente')
    RETURNING id INTO v_id;
  END IF;

  -- The rail of the operation: where the money goes (a lock a person put on it stays). Automation (the notes parser)
  -- must not replace what the agent saved, so the recipients are locked like any recipient written on purpose.
  v_lock := coalesce(v_op.admin_locked_fields, '{}'::jsonb);
  IF NOT (v_lock ? 'delivery_method') OR coalesce(v_lock #>> '{delivery_method,by}', '') LIKE 'automation:%'
     OR coalesce(v_lock #>> '{delivery_method,by}', '') LIKE 'agent:%' THEN
    UPDATE remittance_operations
       SET admin_locked_fields = coalesce(admin_locked_fields, '{}'::jsonb) - 'delivery_method'
     WHERE id = v_op.id AND admin_locked_fields ? 'delivery_method';
    UPDATE remittance_operations SET delivery_method = v_tipo WHERE id = v_op.id AND delivery_method IS DISTINCT FROM v_tipo;
  END IF;
  UPDATE remittance_operations
     SET admin_locked_fields = coalesce(admin_locked_fields, '{}'::jsonb)
         || jsonb_build_object('beneficiaries', jsonb_build_object('by', v_actor, 'at', now()))
   WHERE id = v_op.id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_op.account_id, 'remittance_beneficiaries', v_id, 'beneficiary_type,name,phone,clabe,bank_name',
          'agent_mexico_recipient_registered', v_actor,
          CASE WHEN v_exec IS NOT NULL THEN left(v_exec, 200) END, NULL,
          jsonb_build_object('tipo', v_tipo, 'banco', v_banco, 'deduplicado', v_ex.id IS NOT NULL));

  RETURN jsonb_build_object('ok', true, 'beneficiary_id', v_id,
    'mensaje', CASE WHEN v_ex.id IS NOT NULL THEN 'Ese destinatario ya estaba guardado; se actualizaron sus datos.' ELSE 'Destinatario guardado.' END
      || CASE WHEN crm_beneficiarios_completos(v_op.id) THEN ' Los datos del destinatario estan completos.'
              ELSE ' Aun faltan datos de algun destinatario.' END);
END $function$;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario_mexico(uuid, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_beneficiario_mexico(uuid, text, text, text, text, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.crm_agregar_beneficiario(p_operation_id uuid, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id        uuid;
  v_op_status          text;
  v_service_type       text;
  v_key                text;
  v_new_id             uuid;
  v_next_position      integer;
  v_next_block_index   integer;

  v_beneficiary_type   text;
  v_name               text;
  v_card_number        text;
  v_phone              text;
  v_zelle_account      text;
  v_delivery_method    text;
  v_amount             numeric;
  v_currency           text;
  v_address            text;
  v_reference          text;
  v_contact            text;
  v_op_rail            text;
  v_op                 remittance_operations%ROWTYPE;
  v_cash               remittance_beneficiaries%ROWTYPE;
  v_clabe              text;
  v_bank               text;
BEGIN
  SELECT account_id, status, service_type
    INTO v_account_id, v_op_status, v_service_type
    FROM remittance_operations
   WHERE id = p_operation_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to add a beneficiary to this operation' USING ERRCODE = '42501';
  END IF;

  IF v_op_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF v_service_type IS NULL OR v_service_type NOT IN ('remesa', 'recarga', 'combo', 'saldo', 'mexico') THEN
    RAISE EXCEPTION 'beneficiaries can only be added to remesa, recarga, saldo, combo or mexico operations' USING ERRCODE = '22023';
  END IF;

  IF p_datos IS NULL OR jsonb_typeof(p_datos) <> 'object' THEN
    RAISE EXCEPTION 'datos must be a JSON object' USING ERRCODE = '22023';
  END IF;

  -- Reject unknown keys up front, same posture as crm_corregir_beneficiario.
  FOR v_key IN SELECT jsonb_object_keys(p_datos) LOOP
    IF v_key NOT IN ('beneficiary_type', 'name', 'card_number', 'phone', 'zelle_account',
                      'delivery_method', 'amount', 'currency', 'address', 'reference', 'contact_phone', 'id_photo_wamid', 'clabe', 'bank_name') THEN
      RAISE EXCEPTION 'unknown field: %', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_beneficiary_type := p_datos ->> 'beneficiary_type';
  IF v_beneficiary_type IS NULL
     OR v_beneficiary_type NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution', 'recarga', 'combo', 'efectivo_usd', 'mexico_cuenta', 'mexico_retiro') THEN
    RAISE EXCEPTION 'invalid beneficiary_type: %', v_beneficiary_type USING ERRCODE = '22023';
  END IF;

  -- (233) The ID photo belongs to a cash recipient alone and must be an image of this conversation (null = none).
  IF p_datos ? 'id_photo_wamid' THEN
    IF v_beneficiary_type <> 'efectivo_usd' THEN
      RAISE EXCEPTION 'field id_photo_wamid is for cash recipients' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_datos->'id_photo_wamid') NOT IN ('string', 'null')
       OR (jsonb_typeof(p_datos->'id_photo_wamid') = 'string' AND NOT EXISTS (
             SELECT 1 FROM messages m
              WHERE m.message_id = p_datos->>'id_photo_wamid'
                AND m.content_type = 'image'
                AND m.conversation_id = (SELECT ro.conversation_id FROM remittance_operations ro WHERE ro.id = p_operation_id))) THEN
      RAISE EXCEPTION 'id_photo_wamid must be the message id of an image of this conversation' USING ERRCODE = '22023';
    END IF;
  END IF;
  -- (208) A combo takes combo recipients only, and only a combo does. Address, reference and contact_phone belong to
  -- a combo recipient alone.
  IF (v_service_type = 'combo') <> (v_beneficiary_type = 'combo') THEN
    RAISE EXCEPTION 'a combo takes combo recipients only, and no other operation does' USING ERRCODE = '22023';
  END IF;
  -- (225) The address is also a cash recipient's.
  IF v_beneficiary_type <> 'combo'
     AND (p_datos ? 'reference' OR p_datos ? 'contact_phone' OR (p_datos ? 'address' AND v_beneficiary_type <> 'efectivo_usd')) THEN
    RAISE EXCEPTION 'unknown field: address, reference and contact_phone are for combo recipients' USING ERRCODE = '22023';
  END IF;
  IF v_beneficiary_type = 'combo' THEN
    v_name := nullif(btrim(coalesce(p_datos ->> 'name', '')), '');
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'name is required for a combo recipient' USING ERRCODE = '22023';
    END IF;
    v_phone := regexp_replace(coalesce(p_datos ->> 'phone', ''), '[^0-9]', '', 'g');
    IF length(v_phone) = 10 AND left(v_phone, 2) = '53' THEN v_phone := substr(v_phone, 3); END IF;
    IF v_phone !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_contact := nullif(regexp_replace(coalesce(p_datos ->> 'contact_phone', ''), '[^0-9]', '', 'g'), '');
    IF v_contact IS NOT NULL AND length(v_contact) = 10 AND left(v_contact, 2) = '53' THEN v_contact := substr(v_contact, 3); END IF;
    IF v_contact IS NOT NULL AND v_contact !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'contact_phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_address := nullif(btrim(coalesce(p_datos ->> 'address', '')), '');
    v_reference := nullif(btrim(coalesce(p_datos ->> 'reference', '')), '');
    IF NOT (p_datos ? 'amount') OR p_datos ->> 'amount' IS NULL OR (p_datos ->> 'amount')::numeric <= 0 THEN
      RAISE EXCEPTION 'amount is required and must be greater than 0' USING ERRCODE = '22023';
    END IF;
    v_amount := (p_datos ->> 'amount')::numeric;
    IF coalesce(p_datos ->> 'currency', 'GYD') <> 'GYD' THEN
      RAISE EXCEPTION 'a combo amount is in GYD' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(max(position), 0) + 1 INTO v_next_position
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, address, reference, contact_phone,
                                          amount, currency, position, status, source, block_index)
    VALUES (p_operation_id, 'combo', v_name, v_phone, v_address, v_reference, v_contact,
            v_amount, 'GYD', v_next_position, 'vigente', 'admin_addition', v_next_block_index)
    RETURNING id INTO v_new_id;
    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields ||
           jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now())),
           quoted_source_amount = (SELECT coalesce(sum(b.amount), 0) FROM remittance_beneficiaries b
                                    WHERE b.operation_id = p_operation_id AND b.status = 'vigente' AND b.beneficiary_type = 'combo')
     WHERE id = p_operation_id;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,name,phone,address,reference,contact_phone,amount,currency',
            'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);
    RETURN jsonb_build_object('id', v_new_id, 'complete', crm_beneficiarios_completos(p_operation_id));
  END IF;

  -- (271) A México send takes México recipients only, and only a México send does. CLABE and bank belong to them alone.
  IF (v_service_type = 'mexico') <> (v_beneficiary_type IN ('mexico_cuenta', 'mexico_retiro')) THEN
    RAISE EXCEPTION 'a mexico send takes mexico recipients only, and no other operation does' USING ERRCODE = '22023';
  END IF;
  IF v_beneficiary_type NOT IN ('mexico_cuenta', 'mexico_retiro') AND (p_datos ? 'clabe' OR p_datos ? 'bank_name') THEN
    RAISE EXCEPTION 'unknown field: clabe and bank_name are for mexico recipients' USING ERRCODE = '22023';
  END IF;
  IF v_beneficiary_type IN ('mexico_cuenta', 'mexico_retiro') THEN
    -- (271) Holder / receiver in name, the phone in phone, no amount, currency, card or delivery method: the existing
    -- pricing is the operation's (the deposit), and the payout is in MXN at the operator's daily rate (not stored).
    FOR v_key IN SELECT jsonb_object_keys(p_datos) LOOP
      IF v_key NOT IN ('beneficiary_type', 'name', 'clabe', 'bank_name', 'phone') THEN
        RAISE EXCEPTION 'unknown field: % does not apply to a mexico recipient', v_key USING ERRCODE = '22023';
      END IF;
    END LOOP;
    v_name := nullif(btrim(coalesce(p_datos ->> 'name', '')), '');
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'name is required for a mexico recipient' USING ERRCODE = '22023';
    END IF;
    v_phone := nullif(regexp_replace(coalesce(p_datos ->> 'phone', ''), '[^0-9]', '', 'g'), '');
    IF v_phone IS NOT NULL AND v_phone !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_bank := nullif(btrim(coalesce(p_datos ->> 'bank_name', '')), '');
    IF v_beneficiary_type = 'mexico_cuenta' THEN
      v_clabe := regexp_replace(coalesce(p_datos ->> 'clabe', ''), '[ -]', '', 'g');
      IF v_clabe !~ '^[0-9]{18}$' THEN
        RAISE EXCEPTION 'clabe must be exactly 18 digits' USING ERRCODE = '22023';
      END IF;
      IF v_bank IS NULL THEN
        RAISE EXCEPTION 'bank_name is required for a mexico bank account' USING ERRCODE = '22023';
      END IF;
      IF EXISTS (SELECT 1 FROM remittance_beneficiaries b
                  WHERE b.operation_id = p_operation_id AND b.status = 'vigente' AND b.clabe = v_clabe) THEN
        RAISE EXCEPTION 'this clabe is already on the operation: correct it instead of adding another' USING ERRCODE = '22023';
      END IF;
    ELSE
      IF p_datos ->> 'clabe' IS NOT NULL THEN
        RAISE EXCEPTION 'unknown field: clabe does not apply to a cardless withdrawal' USING ERRCODE = '22023';
      END IF;
      v_bank := CASE lower(coalesce(v_bank, '')) WHEN 'coppel' THEN 'Coppel' WHEN 'bbva' THEN 'BBVA' END;
      IF v_bank IS NULL THEN
        RAISE EXCEPTION 'bank_name must be Coppel or BBVA for a cardless withdrawal' USING ERRCODE = '22023';
      END IF;
      IF v_phone IS NULL THEN
        RAISE EXCEPTION 'phone is required for a cardless withdrawal' USING ERRCODE = '22023';
      END IF;
    END IF;
    SELECT coalesce(max(position), 0) + 1 INTO v_next_position
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, clabe, bank_name, position, status, source, block_index)
    VALUES (p_operation_id, v_beneficiary_type, v_name, v_phone, v_clabe, v_bank, v_next_position, 'vigente', 'admin_addition', v_next_block_index)
    RETURNING id INTO v_new_id;
    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields ||
           jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now())),
           delivery_method = coalesce(delivery_method, v_beneficiary_type)
     WHERE id = p_operation_id;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,name,phone,clabe,bank_name',
            'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);
    RETURN jsonb_build_object('id', v_new_id, 'complete', crm_beneficiarios_completos(p_operation_id));
  END IF;

  -- (200) A recharge takes recharge numbers only (one Cuban mobile per recharge), and a remesa none: no card, no
  -- amount. Same lock and audit as below.
  -- (223) A mobile balance takes one phone-only recipient, the same row type as a recharge.
  IF (v_service_type IN ('recarga', 'saldo')) <> (v_beneficiary_type = 'recarga') THEN
    RAISE EXCEPTION 'a recharge or a mobile balance takes recharge numbers only, and a remesa none' USING ERRCODE = '22023';
  END IF;
  IF v_beneficiary_type = 'recarga' THEN
    v_phone := cerebro_norm_celular_cu(p_datos ->> 'phone');
    IF coalesce(v_phone, '') !~ '^[0-9]{8}$' THEN
      RAISE EXCEPTION 'phone must be a Cuban mobile number' USING ERRCODE = '22023';
    END IF;
    IF v_service_type = 'saldo' AND EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente') THEN
      RAISE EXCEPTION 'a mobile balance has one number: correct it instead of adding another' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(max(position), 0) + 1 INTO v_next_position
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, status, source, block_index)
    VALUES (p_operation_id, 'recarga', v_phone, v_next_position, 'vigente', 'admin_addition', v_next_block_index)
    RETURNING id INTO v_new_id;
    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields ||
           jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
     WHERE id = p_operation_id;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,phone',
            'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);
    RETURN jsonb_build_object('id', v_new_id, 'complete', crm_beneficiarios_completos(p_operation_id));
  END IF;

  -- (225) A cash USD recipient, the row the bot writes with crm_registrar_datos_entrega_efectivo (150/191): name
  -- (optional), phone and address. The ID-card photo comes from the chat, so the recipient stays incomplete
  -- (crm_beneficiarios_completos, 188) until it arrives. No amount, currency, card or delivery method is taken: the
  -- existing calculation prices a lone recipient (floor(deposit / cash rate) USD, 188). One cash recipient per
  -- operation, on a cash operation or one with no rail yet. Same lock and audit as the other added recipients.
  IF v_beneficiary_type = 'efectivo_usd' THEN
    FOR v_key IN SELECT jsonb_object_keys(p_datos) LOOP
      IF v_key NOT IN ('beneficiary_type', 'name', 'phone', 'address', 'id_photo_wamid') THEN
        RAISE EXCEPTION 'unknown field: % does not apply to a cash recipient', v_key USING ERRCODE = '22023';
      END IF;
    END LOOP;
    SELECT delivery_method INTO v_op_rail FROM remittance_operations WHERE id = p_operation_id;
    IF v_op_rail IS NOT NULL AND v_op_rail <> 'efectivo_usd' THEN
      RAISE EXCEPTION 'a cash recipient needs a cash operation: change the service first' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM remittance_beneficiaries b
                WHERE b.operation_id = p_operation_id AND b.status = 'vigente' AND b.beneficiary_type = 'efectivo_usd') THEN
      RAISE EXCEPTION 'a cash delivery has one recipient: correct it instead of adding another' USING ERRCODE = '22023';
    END IF;
    v_name := nullif(btrim(coalesce(p_datos ->> 'name', '')), '');
    v_phone := regexp_replace(coalesce(p_datos ->> 'phone', ''), '[^0-9]', '', 'g');
    IF length(v_phone) = 10 AND left(v_phone, 2) = '53' THEN v_phone := substr(v_phone, 3); END IF;
    IF v_phone !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_address := nullif(btrim(coalesce(p_datos ->> 'address', '')), '');
    IF v_address IS NULL THEN
      RAISE EXCEPTION 'address is required for a cash recipient' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(max(position), 0) + 1 INTO v_next_position
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
      FROM remittance_beneficiaries WHERE operation_id = p_operation_id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, address, id_photo_wamid, position, status, source, block_index)
    VALUES (p_operation_id, 'efectivo_usd', v_name, v_phone, v_address, p_datos ->> 'id_photo_wamid', v_next_position, 'vigente', 'admin_addition', v_next_block_index)
    RETURNING id INTO v_new_id;
    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields ||
           jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
     WHERE id = p_operation_id;
    -- The recipient triggers have priced the operation and its lone recipient. An operation whose recipients were
    -- locked by an earlier correction does not price the recipient there: it takes the calculated quote here (as
    -- crm_cambiar_servicio does). The calculation's own writes were locked by the 096 guard (the writer is a human):
    -- release them again, a calculated quote is not a manual one.
    SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
    IF v_op.quoted_destination_origin = 'calculated' THEN
      SELECT * INTO v_cash FROM remittance_beneficiaries WHERE id = v_new_id;
      IF v_cash.amount IS DISTINCT FROM v_op.quoted_destination_amount OR v_cash.currency IS DISTINCT FROM v_op.destination_currency THEN
        UPDATE remittance_beneficiaries
           SET amount = v_op.quoted_destination_amount, currency = v_op.destination_currency, amount_origin = 'calculated'
         WHERE id = v_new_id;
      END IF;
      UPDATE remittance_operations
         SET admin_locked_fields = admin_locked_fields - 'quoted_destination_amount' - 'destination_currency'
       WHERE id = p_operation_id
         AND admin_locked_fields ?| ARRAY['quoted_destination_amount', 'destination_currency'];
    END IF;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,name,phone,address,id_photo_wamid',
            'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);
    RETURN jsonb_build_object('id', v_new_id, 'complete', crm_beneficiarios_completos(p_operation_id));
  END IF;

  -- amount and currency are required: unlike a correction, a newly added
  -- beneficiary has no prior row to fall back on for its destination amount.
  IF NOT (p_datos ? 'amount') OR p_datos ->> 'amount' IS NULL
     OR (p_datos ->> 'amount')::numeric <= 0 THEN
    RAISE EXCEPTION 'amount is required and must be greater than 0' USING ERRCODE = '22023';
  END IF;
  v_amount := (p_datos ->> 'amount')::numeric;

  IF NOT (p_datos ? 'currency') OR p_datos ->> 'currency' IS NULL
     OR p_datos ->> 'currency' !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'currency is required and must be a 3-letter uppercase code' USING ERRCODE = '22023';
  END IF;
  v_currency := p_datos ->> 'currency';

  v_delivery_method := p_datos ->> 'delivery_method';
  IF p_datos ? 'delivery_method' AND btrim(coalesce(v_delivery_method, '')) = '' THEN
    RAISE EXCEPTION 'delivery_method must not be empty' USING ERRCODE = '22023';
  END IF;

  IF v_beneficiary_type = 'zelle' THEN
    v_name := p_datos ->> 'name';
    v_zelle_account := p_datos ->> 'zelle_account';
    IF btrim(coalesce(v_name, '')) = '' THEN
      RAISE EXCEPTION 'name is required for a zelle beneficiary' USING ERRCODE = '22023';
    END IF;
    IF btrim(coalesce(v_zelle_account, '')) = '' THEN
      RAISE EXCEPTION 'zelle_account is required for a zelle beneficiary' USING ERRCODE = '22023';
    END IF;
    v_card_number := NULL;
    v_phone := NULL;
  ELSE
    v_card_number := p_datos ->> 'card_number';
    v_phone := p_datos ->> 'phone';
    IF v_card_number IS NULL OR v_card_number !~ '^[0-9]{16}$' THEN
      RAISE EXCEPTION 'card_number must be exactly 16 digits' USING ERRCODE = '22023';
    END IF;
    -- (190) The phone is optional: the owner records a card the customer gave without its phone, and closes the
    -- remesa manually (crm_cerrar_operacion_manual). A given phone is still validated; the remesa stays incomplete
    -- (crm_beneficiarios_completos) so a normal delivery still needs it.
    v_phone := nullif(btrim(coalesce(v_phone, '')), '');
    IF v_phone IS NOT NULL AND v_phone !~ '^[0-9]{8,15}$' THEN
      RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
    END IF;
    v_name := p_datos ->> 'name';
    v_zelle_account := NULL;
  END IF;

  SELECT coalesce(max(position), 0) + 1 INTO v_next_position
    FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente';

  SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
    FROM remittance_beneficiaries WHERE operation_id = p_operation_id;

  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone, zelle_account,
    delivery_method, amount, currency, position, status, source, block_index
  ) VALUES (
    p_operation_id, v_beneficiary_type, v_name, v_card_number, v_phone, v_zelle_account,
    v_delivery_method, v_amount, v_currency, v_next_position, 'vigente', 'admin_addition', v_next_block_index
  ) RETURNING id INTO v_new_id;

  -- Lock beneficiaries on this operation so automation cannot overwrite or
  -- delete the row a human just added — same lock crm_corregir_beneficiario
  -- and crm_reasignar_beneficiario place (098), honored by
  -- cerebro_sync_beneficiarios' early return (also 098).
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields ||
         jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, 'beneficiary_type,name,card_number,phone,zelle_account,delivery_method,amount,currency',
          'human_beneficiary_added', wacrm_current_actor(), NULL, p_datos);

  RETURN jsonb_build_object(
    'id', v_new_id,
    'complete', crm_beneficiarios_completos(p_operation_id)
  );
END $function$;
REVOKE ALL ON FUNCTION public.crm_agregar_beneficiario(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_agregar_beneficiario(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.crm_corregir_beneficiario(p_beneficiary_id uuid, p_cambios jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_old               remittance_beneficiaries%ROWTYPE;
  v_op_id              uuid;
  v_account_id         uuid;
  v_op_status          text;
  v_key                text;
  v_new_id             uuid;
  v_next_block_index   integer;
  v_before             jsonb := '{}'::jsonb;
  v_after              jsonb := '{}'::jsonb;
  v_field_names        text;
  v_name               text;
  v_card_number        text;
  v_phone              text;
  v_zelle_account      text;
  v_delivery_method    text;
  v_amount             numeric;
  v_currency           text;
  v_beneficiary_type   text;
  v_clabe              text;
  v_bank               text;
BEGIN
  SELECT * INTO v_old FROM remittance_beneficiaries WHERE id = p_beneficiary_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'beneficiary not found' USING ERRCODE = 'P0002';
  END IF;
  v_op_id := v_old.operation_id;

  IF v_old.status <> 'vigente' THEN
    RAISE EXCEPTION 'beneficiary is not current' USING ERRCODE = '22023';
  END IF;

  SELECT account_id, status INTO v_account_id, v_op_status
    FROM remittance_operations
   WHERE id = v_op_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to correct this beneficiary' USING ERRCODE = '42501';
  END IF;

  IF v_op_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF p_cambios IS NULL OR p_cambios = '{}'::jsonb THEN
    RAISE EXCEPTION 'no changes provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_cambios) LOOP
    IF v_key NOT IN ('name', 'card_number', 'phone', 'zelle_account', 'delivery_method',
                      'amount', 'currency', 'beneficiary_type', 'address', 'reference', 'contact_phone', 'id_photo_wamid', 'clabe', 'bank_name') THEN
      RAISE EXCEPTION 'unknown field: %', v_key USING ERRCODE = '22023';
    END IF;
    -- (212) A combo recipient takes its own fields only: no card, Zelle, delivery method, currency or type change
    -- (a combo is GYD). Reference and contact phone belong to combo recipients; the address also to cash ones.
    IF v_old.beneficiary_type = 'combo'
       AND v_key IN ('card_number', 'zelle_account', 'delivery_method', 'currency', 'beneficiary_type') THEN
      RAISE EXCEPTION 'field % does not apply to a combo recipient', v_key USING ERRCODE = '22023';
    END IF;
    IF v_old.beneficiary_type <> 'combo' AND v_key IN ('reference', 'contact_phone') THEN
      RAISE EXCEPTION 'field % is for combo recipients', v_key USING ERRCODE = '22023';
    END IF;
    IF v_old.beneficiary_type NOT IN ('combo', 'efectivo_usd') AND v_key = 'address' THEN
      RAISE EXCEPTION 'field address is for combo and cash recipients' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- (271) México recipients: only name, clabe, bank_name and phone can be corrected, with the validations of adding one.
  -- CLABE and bank belong to México recipients alone.
  IF v_old.beneficiary_type IN ('mexico_cuenta', 'mexico_retiro') THEN
    FOR v_key IN SELECT jsonb_object_keys(p_cambios) LOOP
      IF v_key NOT IN ('name', 'clabe', 'bank_name', 'phone') THEN
        RAISE EXCEPTION 'field % does not apply to a mexico recipient', v_key USING ERRCODE = '22023';
      END IF;
    END LOOP;
    IF p_cambios ? 'name' AND nullif(btrim(coalesce(p_cambios->>'name', '')), '') IS NULL THEN
      RAISE EXCEPTION 'name is required for a mexico recipient' USING ERRCODE = '22023';
    END IF;
    IF v_old.beneficiary_type = 'mexico_cuenta' THEN
      IF p_cambios ? 'clabe' THEN
        v_clabe := regexp_replace(coalesce(p_cambios->>'clabe', ''), '[ -]', '', 'g');
        IF v_clabe !~ '^[0-9]{18}$' THEN
          RAISE EXCEPTION 'clabe must be exactly 18 digits' USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM remittance_beneficiaries b
                    WHERE b.operation_id = v_op_id AND b.status = 'vigente' AND b.clabe = v_clabe AND b.id <> p_beneficiary_id) THEN
          RAISE EXCEPTION 'this clabe is already on the operation' USING ERRCODE = '22023';
        END IF;
      ELSE
        v_clabe := v_old.clabe;
      END IF;
      IF p_cambios ? 'bank_name' THEN
        v_bank := nullif(btrim(coalesce(p_cambios->>'bank_name', '')), '');
        IF v_bank IS NULL THEN
          RAISE EXCEPTION 'bank_name is required for a mexico bank account' USING ERRCODE = '22023';
        END IF;
      ELSE
        v_bank := v_old.bank_name;
      END IF;
    ELSE
      IF p_cambios ? 'clabe' THEN
        RAISE EXCEPTION 'field clabe does not apply to a cardless withdrawal' USING ERRCODE = '22023';
      END IF;
      v_clabe := NULL;
      IF p_cambios ? 'bank_name' THEN
        v_bank := CASE lower(btrim(coalesce(p_cambios->>'bank_name', ''))) WHEN 'coppel' THEN 'Coppel' WHEN 'bbva' THEN 'BBVA' END;
        IF v_bank IS NULL THEN
          RAISE EXCEPTION 'bank_name must be Coppel or BBVA for a cardless withdrawal' USING ERRCODE = '22023';
        END IF;
      ELSE
        v_bank := v_old.bank_name;
      END IF;
      IF p_cambios ? 'phone' AND p_cambios->>'phone' IS NULL THEN
        RAISE EXCEPTION 'phone is required for a cardless withdrawal' USING ERRCODE = '22023';
      END IF;
    END IF;
  ELSIF p_cambios ? 'clabe' OR p_cambios ? 'bank_name' THEN
    RAISE EXCEPTION 'fields clabe and bank_name are for mexico recipients' USING ERRCODE = '22023';
  END IF;

  -- (233) The ID photo of a cash recipient is an image the customer sent in THIS conversation (its message_id); null clears it.
  IF p_cambios ? 'id_photo_wamid' THEN
    IF v_old.beneficiary_type <> 'efectivo_usd' THEN
      RAISE EXCEPTION 'field id_photo_wamid is for cash recipients' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_cambios->'id_photo_wamid') NOT IN ('string', 'null')
       OR (jsonb_typeof(p_cambios->'id_photo_wamid') = 'string' AND NOT EXISTS (
             SELECT 1 FROM messages m
              WHERE m.message_id = p_cambios->>'id_photo_wamid'
                AND m.content_type = 'image'
                AND m.conversation_id = (SELECT ro.conversation_id FROM remittance_operations ro WHERE ro.id = v_op_id))) THEN
      RAISE EXCEPTION 'id_photo_wamid must be the message id of an image of this conversation' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_cambios ? 'contact_phone' AND p_cambios->>'contact_phone' IS NOT NULL
     AND p_cambios->>'contact_phone' !~ '^[0-9]{8,15}$' THEN
    RAISE EXCEPTION 'contact_phone must be 8 to 15 digits' USING ERRCODE = '22023';
  END IF;

  -- card_number / phone / amount / currency may be explicitly cleared to
  -- null; when present they must be well-formed. beneficiary_type may not
  -- be null and must be one of the known types.
  IF p_cambios ? 'card_number' AND p_cambios->>'card_number' IS NOT NULL
     AND p_cambios->>'card_number' !~ '^[0-9]{16}$' THEN
    RAISE EXCEPTION 'card_number must be exactly 16 digits' USING ERRCODE = '22023';
  END IF;

  IF p_cambios ? 'phone' AND p_cambios->>'phone' IS NOT NULL
     AND p_cambios->>'phone' !~ '^[0-9]{8,15}$' THEN
    RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
  END IF;

  IF p_cambios ? 'amount' AND p_cambios->>'amount' IS NOT NULL
     AND (p_cambios->>'amount')::numeric <= 0 THEN
    RAISE EXCEPTION 'amount must be greater than 0' USING ERRCODE = '22023';
  END IF;

  IF p_cambios ? 'currency' AND p_cambios->>'currency' IS NOT NULL
     AND p_cambios->>'currency' !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'currency must be a 3-letter uppercase code' USING ERRCODE = '22023';
  END IF;

  IF p_cambios ? 'beneficiary_type' THEN
    IF p_cambios->>'beneficiary_type' IS NULL
       OR p_cambios->>'beneficiary_type' NOT IN
          ('cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution') THEN
      RAISE EXCEPTION 'invalid beneficiary_type: %', p_cambios->>'beneficiary_type' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Resolve the new row's values: overridden by p_cambios, falling back to the old row.
  v_name             := CASE WHEN p_cambios ? 'name' THEN p_cambios->>'name' ELSE v_old.name END;
  v_card_number      := CASE WHEN p_cambios ? 'card_number' THEN p_cambios->>'card_number' ELSE v_old.card_number END;
  v_phone            := CASE WHEN p_cambios ? 'phone' THEN p_cambios->>'phone' ELSE v_old.phone END;
  v_zelle_account    := CASE WHEN p_cambios ? 'zelle_account' THEN p_cambios->>'zelle_account' ELSE v_old.zelle_account END;
  v_delivery_method  := CASE WHEN p_cambios ? 'delivery_method' THEN p_cambios->>'delivery_method' ELSE v_old.delivery_method END;
  v_amount           := CASE WHEN p_cambios ? 'amount' THEN (p_cambios->>'amount')::numeric ELSE v_old.amount END;
  v_currency         := CASE WHEN p_cambios ? 'currency' THEN p_cambios->>'currency' ELSE v_old.currency END;
  v_beneficiary_type := CASE WHEN p_cambios ? 'beneficiary_type' THEN p_cambios->>'beneficiary_type' ELSE v_old.beneficiary_type END;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = now()
   WHERE id = p_beneficiary_id;

  SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
    FROM remittance_beneficiaries WHERE operation_id = v_op_id;

  -- (212) Every column the correction does not touch is carried over: the combo's address, reference and contact
  -- phone, the cash recipient's address and ID photo, and the amount's origin when the amount is kept.
  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone, zelle_account,
    delivery_method, amount, currency, position, status, source, block_index,
    address, reference, contact_phone, id_photo_wamid, amount_origin, clabe, bank_name
  ) VALUES (
    v_op_id, v_beneficiary_type, v_name, v_card_number, v_phone, v_zelle_account,
    v_delivery_method, v_amount, v_currency, v_old.position, 'vigente', 'admin_correction', v_next_block_index,
    CASE WHEN p_cambios ? 'address' THEN nullif(btrim(p_cambios->>'address'), '') ELSE v_old.address END,
    CASE WHEN p_cambios ? 'reference' THEN nullif(btrim(p_cambios->>'reference'), '') ELSE v_old.reference END,
    CASE WHEN p_cambios ? 'contact_phone' THEN p_cambios->>'contact_phone' ELSE v_old.contact_phone END,
    CASE WHEN p_cambios ? 'id_photo_wamid' THEN p_cambios->>'id_photo_wamid' ELSE v_old.id_photo_wamid END,
    CASE WHEN p_cambios ? 'amount' THEN 'manual' ELSE v_old.amount_origin END,
    CASE WHEN v_old.beneficiary_type IN ('mexico_cuenta', 'mexico_retiro') THEN v_clabe END,
    CASE WHEN v_old.beneficiary_type IN ('mexico_cuenta', 'mexico_retiro') THEN v_bank END
  ) RETURNING id INTO v_new_id;

  -- (212) A combo's total is the sum of its recipients' amounts.
  UPDATE remittance_operations o
     SET quoted_source_amount = (SELECT coalesce(sum(b.amount), 0) FROM remittance_beneficiaries b
                                  WHERE b.operation_id = o.id AND b.status = 'vigente' AND b.beneficiary_type = 'combo')
   WHERE o.id = v_op_id AND o.service_type = 'combo';

  -- Lock beneficiaries on this operation so automation stops overwriting them.
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields ||
         jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = v_op_id;

  SELECT string_agg(k, ',' ORDER BY k) INTO v_field_names FROM jsonb_object_keys(p_cambios) AS k;

  FOR v_key IN SELECT jsonb_object_keys(p_cambios) LOOP
    v_before := v_before || jsonb_build_object(v_key,
      CASE v_key
        WHEN 'name' THEN to_jsonb(v_old.name)
        WHEN 'card_number' THEN to_jsonb(v_old.card_number)
        WHEN 'phone' THEN to_jsonb(v_old.phone)
        WHEN 'zelle_account' THEN to_jsonb(v_old.zelle_account)
        WHEN 'delivery_method' THEN to_jsonb(v_old.delivery_method)
        WHEN 'amount' THEN to_jsonb(v_old.amount)
        WHEN 'currency' THEN to_jsonb(v_old.currency)
        WHEN 'beneficiary_type' THEN to_jsonb(v_old.beneficiary_type)
        WHEN 'address' THEN to_jsonb(v_old.address)
        WHEN 'reference' THEN to_jsonb(v_old.reference)
        WHEN 'contact_phone' THEN to_jsonb(v_old.contact_phone)
        WHEN 'id_photo_wamid' THEN to_jsonb(v_old.id_photo_wamid)
        WHEN 'clabe' THEN to_jsonb(v_old.clabe)
        WHEN 'bank_name' THEN to_jsonb(v_old.bank_name)
      END);
    v_after := v_after || jsonb_build_object(v_key, p_cambios -> v_key);
  END LOOP;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, v_field_names, 'human_correction',
          wacrm_current_actor(), v_before, v_after);

  RETURN v_new_id;
END $function$;
REVOKE ALL ON FUNCTION public.crm_corregir_beneficiario(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_corregir_beneficiario(uuid, jsonb) TO authenticated;

DROP FUNCTION IF EXISTS public._cerebro_mexico_tope_usd(uuid, uuid, numeric);
