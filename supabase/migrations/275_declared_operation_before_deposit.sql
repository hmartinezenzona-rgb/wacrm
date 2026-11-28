-- 275 (pre-deposit operations from the declared intent). Gap 2 of the S5b measurement (odd/notes/db-tools-progress.md):
-- the agent declares the service ("mexico", "efectivo_usd", ...) before the customer pays and then saves recipient data; the
-- recipient writers refused ("No hay un envio a Mexico abierto", cash 22023) or filed a rail-less remesa. Now:
--   * _cerebro_operacion_declarada(conv, service, actor): the writers' new-operation rule. It finds the open operation of the
--     service or, only when that service IS the declared one (cerebro_servicio_declarado), opens it: collecting_information,
--     0 GYD, the conversation's account/contact, the deposit data of the newest open operation, MXN for mexico, audit
--     'agent_service_change'. Words never open a service. service_role only.
--   * cerebro_guardar_beneficiario_mexico and crm_registrar_datos_entrega_efectivo call it when nothing is open (otherwise
--     unchanged: same messages / 22023 when the service was not declared).
--   * cerebro_resolver_para_guardar (card, reparto and Zelle writers): with nothing open and a declared rail that fits the data
--     (card data <- cuban_card|clasica|tropical, Zelle account <- zelle) the operation opens typed with that rail. Declared
--     recarga needed no change (crm_registrar_numeros_recarga already opens it). A later deposit joins the operation
--     (cerebro_registrar_deposito 'movido'); the assertion proves it for mexico, cash, zelle, clasica and recarga.
-- Rollback restores the three previous bodies and drops the helper.

-- Opens (or finds) the open operation of a service for a conversation. It is the writers' "new-operation rule": the service
-- must be the one the agent DECLARED (cerebro_servicio_declarado); words never open a service. A new operation has no money
-- (0 GYD, collecting_information), the account/contact of the conversation and the deposit data of the newest open
-- operation (as cerebro_aplicar_servicio's 'aparte' does), so the deposit that comes later joins it (cerebro_registrar_deposito).
-- Returns the operation id or NULL (nothing open and the service is not the declared one, or an error: fail open).
CREATE OR REPLACE FUNCTION public._cerebro_operacion_declarada(p_conv uuid, p_servicio text, p_actor text DEFAULT 'agent:declarar_servicio')
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_srv     text := lower(btrim(coalesce(p_servicio, '')));
  v_actor   text := coalesce(nullif(btrim(p_actor), ''), 'agent:declarar_servicio');
  v_op      uuid;
  v_type    text;
  v_dm      text;
  v_account uuid;
  v_contact uuid;
BEGIN
  IF p_conv IS NULL OR v_srv NOT IN ('cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd', 'recarga', 'saldo', 'combo', 'visa', 'mexico') THEN
    RETURN NULL;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_servicio:' || p_conv::text, 0));
  v_type := CASE WHEN v_srv IN ('recarga', 'combo', 'visa', 'saldo', 'mexico') THEN v_srv ELSE 'remesa' END;
  v_dm   := CASE WHEN v_type = 'remesa' THEN v_srv END;

  SELECT o.id INTO v_op FROM remittance_operations o
   WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
     AND (CASE WHEN v_type = 'remesa' THEN o.service_type = 'remesa' AND cerebro_riel_op(o.id) = v_srv ELSE o.service_type = v_type END)
   ORDER BY o.created_at DESC, o.id LIMIT 1;
  IF v_op IS NOT NULL THEN RETURN v_op; END IF;

  IF NOT EXISTS (SELECT 1 FROM cerebro_servicio_declarado d WHERE d.conversation_id = p_conv AND d.servicio = v_srv) THEN
    RETURN NULL;
  END IF;
  SELECT c.account_id, c.contact_id INTO v_account, v_contact FROM conversations c WHERE c.id = p_conv;
  IF v_account IS NULL THEN RETURN NULL; END IF;

  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     deposit_method, source_country, source_currency, quoted_source_amount, destination_currency)
  SELECT v_account, p_conv, coalesce(h.contact_id, v_contact), 'collecting_information', v_type, v_dm,
         h.deposit_method, h.source_country, coalesce(h.source_currency, 'GYD'), 0,
         CASE WHEN v_type = 'mexico' THEN 'MXN' END
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (SELECT x.* FROM remittance_operations x
                        WHERE x.conversation_id = p_conv AND x.status NOT IN ('completed', 'cancelled')
                        ORDER BY x.created_at DESC, x.id LIMIT 1) h ON true
  RETURNING id INTO v_op;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account, 'remittance_operations', v_op, 'service_type', 'agent_service_change', v_actor,
          'declared service opened before the deposit: ' || v_srv, '{}'::jsonb,
          jsonb_build_object('service', v_srv, 'status', 'collecting_information', 'quoted_source_amount', 0));
  RETURN v_op;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[wacrm] _cerebro_operacion_declarada failed for % (%): %', p_conv, SQLSTATE, SQLERRM;
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public._cerebro_operacion_declarada(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._cerebro_operacion_declarada(uuid, text, text) TO service_role;

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

CREATE OR REPLACE FUNCTION public.crm_registrar_datos_entrega_efectivo(p_conv uuid, p_phone text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_id_photo_wamid text DEFAULT NULL::text, p_name text DEFAULT NULL::text)
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
  v_new_name    text;
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
    -- (275) The agent declared efectivo_usd and no operation exists yet: it opens now (0 GYD, awaiting its deposit).
    IF _cerebro_operacion_declarada(p_conv, 'efectivo_usd', 'agent:registrar_datos_entrega_efectivo') IS NOT NULL THEN
      SELECT o.id, o.account_id INTO v_op_id, v_account_id
        FROM remittance_operations o
       WHERE o.conversation_id = p_conv AND o.service_type = 'remesa' AND o.delivery_method = 'efectivo_usd'
         AND o.status NOT IN ('completed', 'cancelled')
       ORDER BY o.created_at DESC LIMIT 1
       FOR UPDATE;
    END IF;
  END IF;

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
  -- (191) The recipient's name: optional, never required for completeness, kept once given.
  v_new_name    := coalesce(nullif(btrim(p_name), ''), v_existing.name);

  IF v_existing.id IS NOT NULL THEN
    v_changed := v_new_phone   IS DISTINCT FROM v_existing.phone
              OR v_new_address IS DISTINCT FROM v_existing.address
              OR v_new_photo   IS DISTINCT FROM v_existing.id_photo_wamid
              OR v_new_name    IS DISTINCT FROM v_existing.name;
  ELSE
    v_changed := p_phone IS NOT NULL OR p_address IS NOT NULL OR p_id_photo_wamid IS NOT NULL OR v_new_name IS NOT NULL;
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
      operation_id, beneficiary_type, name, phone, address, id_photo_wamid,
      position, status, source, block_index
    ) VALUES (
      v_op_id, 'efectivo_usd', v_new_name, v_new_phone, v_new_address, v_new_photo,
      1, 'vigente', 'reparto_auto', v_next_block
    ) RETURNING * INTO v_row;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_row.id, 'name,phone,address,id_photo_wamid',
            'automation_cash_delivery_data_registered', wacrm_current_actor(),
            CASE WHEN v_existing.id IS NULL THEN NULL ELSE
              jsonb_build_object('name', v_existing.name, 'phone', v_existing.phone, 'address', v_existing.address, 'id_photo_wamid', v_existing.id_photo_wamid)
            END,
            jsonb_build_object('name', v_row.name, 'phone', v_row.phone, 'address', v_row.address, 'id_photo_wamid', v_row.id_photo_wamid));
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
           || coalesce('Nombre: ' || v_row.name || chr(10), '')
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
    'name', v_row.name,
    'phone', v_row.phone,
    'address', v_row.address,
    'id_photo_wamid', v_row.id_photo_wamid,
    'complete', v_is_complete,
    'changed', v_changed
  );
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_resolver_para_guardar(p_conv uuid, p_tool text, p_exec text, p_args jsonb, p_op uuid DEFAULT NULL::uuid, OUT o_op uuid, OUT o_ambigua boolean)
 RETURNS record
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_res record; v_decl text;
BEGIN
  -- (180) The deterministic nodes resolve the operation themselves (by card / account) and pass it.
  IF p_op IS NOT NULL THEN
    o_op := p_op; o_ambigua := false;
  ELSE
    SELECT * INTO v_res FROM cerebro_resolver_operacion(p_conv, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);
    o_op := v_res.operation_id;
    o_ambigua := v_res.resultado = 'ambigua';
    -- (275) Nothing open and the agent declared the rail this data belongs to (card data: cuban_card / clasica / tropical;
    -- a Zelle account: zelle): the declared operation opens typed with that rail, awaiting its deposit.
    IF o_op IS NULL AND NOT o_ambigua THEN
      SELECT d.servicio INTO v_decl FROM cerebro_servicio_declarado d WHERE d.conversation_id = p_conv;
      IF v_decl IS NOT NULL
         AND ((v_decl IN ('cuban_card', 'clasica', 'tropical') AND p_tool IN ('gestionar_beneficiario', 'registrar_reparto_multiple', 'Registrar beneficiario auto'))
              OR (v_decl = 'zelle' AND p_tool IN ('registrar_beneficiario_zelle', 'Registrar zelle auto'))) THEN
        o_op := _cerebro_operacion_declarada(p_conv, v_decl, 'agent:' || p_tool);
      END IF;
    END IF;
  END IF;
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments)
  VALUES (coalesce(p_exec, '') || ':' || p_tool || ':' || md5(p_args::text), p_tool, p_exec, p_conv, o_op, p_args)
  ON CONFLICT (idempotency_key) DO NOTHING;
  IF o_ambigua THEN
    PERFORM cerebro_registrar_derivacion(p_conv, 'Hay varias operaciones abiertas y el caso requiere revisión humana.',
                                         'operacion_ambigua', true);
  END IF;
END $function$;
