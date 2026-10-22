-- =====================================================================
-- ROLLBACK 268 -- restores the LIVE bodies, signatures and ACLs of crm_registrar_numeros_recarga (3-argument
-- signature, service_role only) and cerebro_guardar_beneficiario_auto, as they were on staging before 268 (exact
-- pg_get_functiondef text captured 2026-10-22). The 4-argument crm_registrar_numeros_recarga is dropped first.
-- No BEGIN/COMMIT (the caller wraps it).
-- =====================================================================

DROP FUNCTION IF EXISTS public.crm_registrar_numeros_recarga(uuid, text, boolean, text);

CREATE OR REPLACE FUNCTION public.crm_registrar_numeros_recarga(p_conv uuid, p_texto text, p_abrir boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- (201) The Cuban mobile numbers found in p_texto go to the conversation's open recharge, one row per number
-- (beneficiary_type 'recarga'), without repeats; the panel's beneficiary lock wins. Returns what was saved and how many
-- numbers the recharge still needs (cerebro_recarga_unidades of its deposit).
DECLARE
  v_op     record;
  v_m      text[];
  v_num    text;
  v_added  int := 0;
  v_have   int;
  v_need   int;
  v_pos    int;
  v_block  int;
BEGIN
  SELECT o.id, o.account_id, o.quoted_source_amount, o.admin_locked_fields INTO v_op
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
   ORDER BY o.created_at DESC LIMIT 1
   FOR UPDATE;
  IF v_op.id IS NULL THEN
    -- (202) The customer asked for a recharge: it opens now (collecting its numbers), so the panel shows it before
    -- the deposit; the deposit lands on it (cerebro_registrar_deposito).
    -- (204) p_abrir: the agent understood a recharge (e.g. asked for by AUDIO, which the typed-text rule cannot see).
    IF NOT (p_abrir OR cerebro_recarga_en_curso(p_conv)) THEN
      RETURN 'sin recarga en curso: no se guarda ningun numero de recarga';
    END IF;
    -- (207) A new recharge opens only with a promo running or a confirmed one ahead (booked for its start date): with
    -- neither, the bot was asking for a number for a recharge nobody could do. Nothing is saved then.
    IF NOT EXISTS (SELECT 1 FROM cerebro_promo_vigente()) AND NOT EXISTS (SELECT 1 FROM cerebro_promo_proxima()) THEN
      RETURN 'NO HAY PROMOCION DE ETECSA, ni vigente ni anunciada: no se abre ninguna recarga y no se guarda ningun numero. '
             || 'PROHIBIDO pedir el numero de Cuba. Ofrece pasar con un operador.';
    END IF;
    INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
    SELECT v.account_id, v.id, v.contact_id, 'collecting_information', 'recarga', 'GYD', 0
      FROM conversations v WHERE v.id = p_conv
    RETURNING id, account_id, quoted_source_amount, admin_locked_fields INTO v_op;
  END IF;
  IF coalesce(v_op.admin_locked_fields, '{}'::jsonb) ? 'beneficiaries' THEN
    RETURN 'los numeros de esta recarga los gestiona una persona desde el panel: no se cambian';
  END IF;

  FOR v_m IN SELECT regexp_matches(coalesce(p_texto, ''),
                                   '(?<![0-9])(?:\+?53[ -]?)?([56][0-9]{3})[ .-]?([0-9]{4})(?![0-9])', 'g') LOOP
    v_num := v_m[1] || v_m[2];
    CONTINUE WHEN EXISTS (SELECT 1 FROM remittance_beneficiaries b
                           WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.phone = v_num);
    SELECT coalesce(max(position), 0) + 1 INTO v_pos FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_block FROM remittance_beneficiaries WHERE operation_id = v_op.id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
    VALUES (v_op.id, 'recarga', v_num, v_pos, v_block, 'reparto_auto', 'vigente');
    v_added := v_added + 1;
  END LOOP;

  IF v_added > 0 THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'recarga_numbers', 'automation_recharge_numbers_registered',
            wacrm_current_actor(), NULL, jsonb_build_object('added', v_added, 'texto', left(coalesce(p_texto, ''), 300)));
  END IF;

  SELECT count(*) INTO v_have FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente' AND beneficiary_type = 'recarga';
  v_need := cerebro_recarga_unidades(v_op.quoted_source_amount);
  RETURN 'guardados ' || v_added || ' numero(s) de recarga nuevos; la recarga tiene ' || v_have || '.'
         || CASE WHEN coalesce(v_need, 0) = 0 THEN ''
                 WHEN v_have >= v_need THEN ' Numeros completos (' || v_have || ' de ' || v_need || ').'
                 ELSE ' FALTA ' || (v_need - v_have) || ' numero(s) de recarga (son ' || v_need || ' recargas, un numero por recarga). Pideselo al cliente.' END
         -- (207) Booked ahead of a confirmed promo: what to tell the customer about when it is done and paid.
         || CASE WHEN EXISTS (SELECT 1 FROM cerebro_promo_vigente()) THEN ''
                 ELSE COALESCE((SELECT format(' LA PROMOCION AUN NO EMPIEZA: la recarga queda ANOTADA PARA EL %s y se hace ese dia. '
                                              || 'Si el cliente quiere pagar ya, puede; si no, paga ese dia: no le exijas el pago ahora. '
                                              || 'PROHIBIDO decir que se hace hoy o en minutos.', to_char(p.vigente_desde, 'DD/MM'))
                                  FROM cerebro_promo_proxima() p), '') END;
END $function$;

REVOKE ALL ON FUNCTION public.crm_registrar_numeros_recarga(uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crm_registrar_numeros_recarga(uuid, text, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario_auto(p_conv uuid, p_tarjeta text, p_celular text, p_tarjeta_acum text, p_celular_acum text, p_exec text)
 RETURNS TABLE(deal_id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_t text := cerebro_norm_tarjeta(p_tarjeta);
  v_c text := cerebro_norm_celular_cu(p_celular);
  v_ta text := cerebro_norm_tarjeta(p_tarjeta_acum);
  v_ca text := cerebro_norm_celular_cu(p_celular_acum);
  v_res record; v_out record;
  v_cash jsonb;
  v_falta text;
BEGIN
  -- (213) Only while the combo is COLLECTING its recipients: once its deposit arrived a typed card or phone is a new
  -- remesa and goes the normal way below. A visa never blocks (it takes no recipients).
  -- (210) An open COMBO: typed numbers belong to its recipients, which the assistant saves with
  -- registrar_destinatario_combo (by combo number). Nothing is written here.
  IF EXISTS (SELECT 1 FROM remittance_operations o
              WHERE o.conversation_id = p_conv AND o.service_type = 'combo' AND o.status = 'collecting_information') THEN
    RETURN QUERY SELECT (SELECT o.id FROM remittance_operations o
                          WHERE o.conversation_id = p_conv AND o.service_type = 'combo' AND o.status = 'collecting_information'
                          ORDER BY o.created_at DESC LIMIT 1),
      'combo en curso: los datos de los destinatarios los guarda el asistente con registrar_destinatario_combo'::text;
    RETURN;
  END IF;
  SELECT * INTO v_res FROM cerebro_resolver_operacion_beneficiario(p_conv,
           ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'],
           coalesce(NULLIF(v_t, '!'), NULLIF(v_ta, '!'), ''));
  -- (194) A CASH delivery has no card: a Cuban phone arriving alone is the cash recipient's phone. It used to be
  -- saved as a cuban_card beneficiary without card (a second vigente row: the remesa read incomplete) and the agent
  -- was told to ask for a card. A real card in the burst still goes the card way below.
  -- (201) A recharge has no card either: a Cuban number arriving alone is a recharge number.
  IF v_res.operation_id IS NOT NULL
     AND (SELECT o.service_type FROM remittance_operations o WHERE o.id = v_res.operation_id) = 'recarga'
     AND coalesce(NULLIF(v_t, '!'), '') = '' THEN
    RETURN QUERY SELECT v_res.operation_id,
      crm_registrar_numeros_recarga(p_conv, coalesce(cerebro_textos_cliente_recientes(p_conv), '') || ' ' || coalesce(p_celular, ''));
    RETURN;
  END IF;
  -- (202) No open operation but the customer asked for a recharge: the numbers open it (all typed since asking).
  IF v_res.operation_id IS NULL AND v_res.resultado = 'ninguna'
     AND coalesce(NULLIF(v_t, '!'), '') = '' AND cerebro_recarga_en_curso(p_conv) THEN
    RETURN QUERY SELECT (SELECT o.id FROM remittance_operations o WHERE FALSE),
      crm_registrar_numeros_recarga(p_conv, coalesce(cerebro_textos_cliente_recientes(p_conv), '') || ' ' || coalesce(p_celular, ''));
    RETURN;
  END IF;
  IF v_res.operation_id IS NOT NULL
     AND (SELECT o.delivery_method FROM remittance_operations o WHERE o.id = v_res.operation_id) = 'efectivo_usd'
     AND coalesce(NULLIF(v_t, '!'), '') = '' THEN
    IF v_c IS NULL OR v_c = '!' THEN
      RETURN QUERY SELECT v_res.operation_id, 'entrega en efectivo: no llego ningun celular valido de quien recibe'::text; RETURN;
    END IF;
    v_cash := crm_registrar_datos_entrega_efectivo(p_conv, v_c, NULL, NULL);
    v_falta := array_to_string(array_remove(ARRAY[
                 CASE WHEN v_cash ->> 'address' IS NULL THEN 'la direccion' END,
                 CASE WHEN v_cash ->> 'id_photo_wamid' IS NULL THEN 'la foto del carnet' END], NULL), ' y ');
    RETURN QUERY SELECT v_res.operation_id,
      ('guardado: celular ' || v_c || ' de quien recibe la entrega en efectivo.'
       || CASE WHEN v_falta = '' THEN ' Datos de la entrega completos.' ELSE ' FALTA: ' || v_falta || '. Pideselo al cliente.' END)::text;
    RETURN;
  END IF;
  IF v_res.operation_id IS NOT NULL THEN
    -- An open remesa: what arrived in this burst, partial, D1 (179).
    SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', coalesce(p_tarjeta, ''), coalesce(p_celular, ''), p_exec, v_res.operation_id, 'Registrar beneficiario auto');
  ELSIF v_res.resultado = 'ninguna' THEN
    -- No open remesa: only the complete pair opens one (as before).
    IF v_ta IS NOT NULL AND v_ta <> '!' AND v_ca IS NOT NULL AND v_ca <> '!' THEN
      SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', v_ta, v_ca, p_exec, NULL, 'Registrar beneficiario auto');
    ELSE
      RETURN QUERY SELECT NULL::uuid, 'sin envio abierto: se espera el dato que falta para abrirlo'::text; RETURN;
    END IF;
  ELSE
    -- Several open remesas the resolver cannot tell apart: the 179 path derives to a person.
    SELECT * INTO v_out FROM cerebro_guardar_beneficiario(p_conv, '', coalesce(p_tarjeta, ''), coalesce(p_celular, ''), p_exec, NULL, 'Registrar beneficiario auto');
  END IF;
  IF v_out.accion LIKE '%Completo.%' THEN
    DELETE FROM cerebro_beneficiario_parcial WHERE conversation_id = p_conv;
  END IF;
  RETURN QUERY SELECT v_out.deal_id, v_out.accion;
END $function$;
