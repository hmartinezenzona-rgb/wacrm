-- ROLLBACK of 210_combo_ignores_remesa_writers.sql: both functions exactly as before 210 (staging pg_get_functiondef,
-- 2026-10-04: cerebro_escribir_bloque_beneficiario md5 35235cb3d5944f734336d7e83c8ab6dc, cerebro_guardar_beneficiario_auto
-- md5 36e289dc76b38491bff264278d40fd96; check production's md5 before applying 210 there).
CREATE OR REPLACE FUNCTION public.cerebro_escribir_bloque_beneficiario(p_conv uuid, p_op uuid, p_bloque text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op      uuid := p_op;
  v_bi      integer;
  v_reparto boolean;
  v_zelle   integer;
  v_locked  boolean;
  v_account uuid;
BEGIN
  IF v_op IS NULL THEN
    v_op := cerebro_crear_operacion(p_conv);
  END IF;

  SELECT admin_locked_fields ? 'beneficiaries', account_id INTO v_locked, v_account
    FROM remittance_operations WHERE id = v_op;
  IF v_locked THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason)
    VALUES (v_account, 'remittance_beneficiaries', v_op, 'beneficiaries', 'automation_write_suppressed',
            wacrm_current_actor(), 'beneficiaries locked by operator correction');
    RETURN v_op;
  END IF;

  SELECT coalesce(max(b.block_index), 0) + 1 INTO v_bi FROM remittance_beneficiaries b WHERE b.operation_id = v_op;

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone,
                                        zelle_account, amount, currency, position, block_index, source, status)
  SELECT v_op, p.tipo, p.nombre, p.tarjeta, p.celular, p.cuenta_zelle, p.monto, p.moneda, p.posicion, v_bi,
         'notes_parse', 'vigente'
    FROM cerebro_parsear_beneficiarios(p_bloque) p;

  -- (175) The newest generation is a reparto between cards: the latest Zelle stays vigente next to it.
  v_reparto := EXISTS (SELECT 1 FROM remittance_beneficiaries
                        WHERE operation_id = v_op AND block_index = v_bi
                          AND beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical'));
  IF v_reparto THEN
    SELECT max(block_index) INTO v_zelle FROM remittance_beneficiaries
     WHERE operation_id = v_op AND beneficiary_type = 'zelle' AND block_index < v_bi;
  END IF;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = v_op AND block_index < v_bi AND status <> 'reemplazado'
     AND block_index IS DISTINCT FROM v_zelle;

  UPDATE remittance_beneficiaries
     SET status = 'vigente', replaced_at = NULL
   WHERE operation_id = v_op AND block_index = v_zelle AND beneficiary_type = 'zelle' AND status <> 'vigente';

  RETURN v_op;
END $function$;

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
