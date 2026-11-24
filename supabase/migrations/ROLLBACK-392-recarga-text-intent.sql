-- ROLLBACK 392: back to the 268 six-argument cerebro_guardar_beneficiario_auto (live staging body before 392).
DROP FUNCTION IF EXISTS public.cerebro_guardar_beneficiario_auto(uuid, text, text, text, text, text, text);

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
  -- (268) A Cuban number with no card is a recharge number when a recharge is OPEN, or when the agent DECLARED one
  -- (cerebro_servicio_declarado). Customer words never open a service. The recharge tool owns the write: it converts a
  -- remesa holder only when the resolver allows it, and never opens a second operation.
  IF coalesce(NULLIF(v_t, '!'), '') = ''
     AND (EXISTS (SELECT 1 FROM remittance_operations o
                   WHERE o.conversation_id = p_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled'))
          OR (v_c IS NOT NULL AND v_c <> '!'
              AND EXISTS (SELECT 1 FROM cerebro_servicio_declarado d
                           WHERE d.conversation_id = p_conv AND d.servicio = 'recarga'))) THEN
    RETURN QUERY SELECT (SELECT o.id FROM remittance_operations o
                          WHERE o.conversation_id = p_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
                          ORDER BY o.created_at DESC LIMIT 1),
      crm_registrar_numeros_recarga(p_conv, coalesce(cerebro_textos_cliente_recientes(p_conv), '') || ' ' || coalesce(p_celular, ''),
                                    false, 'automation:guardar_beneficiario_auto');
    RETURN;
  END IF;
  SELECT * INTO v_res FROM cerebro_resolver_operacion_beneficiario(p_conv,
           ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'],
           coalesce(NULLIF(v_t, '!'), NULLIF(v_ta, '!'), ''));
  -- (194) A CASH delivery has no card: a Cuban phone arriving alone is the cash recipient's phone. It used to be
  -- saved as a cuban_card beneficiary without card (a second vigente row: the remesa read incomplete) and the agent
  -- was told to ask for a card. A real card in the burst still goes the card way below.
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

REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario_auto(uuid, text, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
