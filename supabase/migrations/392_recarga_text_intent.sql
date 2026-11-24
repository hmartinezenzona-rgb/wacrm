-- 392 -- A typed recarga with Cuban mobiles is registered as a recarga; several bare mobiles never become a cuban_card.
--
-- Production incident (2026-11-24, capture mode, bot paused): the customer wrote "recarga" plus two 8-digit Cuban mobiles. Nothing
-- registered recharge numbers deterministically (crm_registrar_numeros_recarga was reachable only through the agent tool or after a
-- declaration, and customer words never opened a service), and the n8n node passes only the first mobile: one cuban_card recipient
-- with that mobile on an open remesa, the second number lost.
--   * cerebro_guardar_beneficiario_auto gets a 7th argument, the written text of the batch (DEFAULT NULL: the 6-argument call of the
--     current n8n node keeps its behavior). The old six-argument function is dropped (a second overload would make 6-argument calls ambiguous).
--   * batch asks for a recarga (cerebro_texto_pide_recarga, negations honoured) + Cuban mobiles + no card + a promo + no open recarga:
--     declare recarga and register ALL mobiles through crm_registrar_numeros_recarga; an unfunded remesa with phone-only recipients
--     becomes the recarga (_cambiar_servicio_core) instead of a second operation; with nothing open and the bot paused only the
--     declaration is kept (no operation is opened while paused, 390).
--   * more than one distinct mobile and no card: no cuban_card is written from a bare mobile.
--   * the existing 268 branch (open or declared recarga) also reads the batch text.
-- Body redefined from the live staging body; ACL preserved (postgres only). Rollback: ROLLBACK-392-recarga-text-intent.sql.

DROP FUNCTION IF EXISTS public.cerebro_guardar_beneficiario_auto(uuid, text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario_auto(p_conv uuid, p_tarjeta text, p_celular text, p_tarjeta_acum text, p_celular_acum text, p_exec text, p_texto_lote text DEFAULT NULL::text)
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
  -- (392) the written text of the batch (voice-note lines never register data), the Cuban mobiles it carries and the open operations
  v_txt text := nullif(btrim(regexp_replace(coalesce(p_texto_lote, ''), '^[ \t]*\[(Nota de voz|El cliente mand)[^\n]*$', '', 'gn')), '');
  v_movs text[];
  v_n_open int;
  v_ph uuid;
  v_msg text;
  v_prev_origin text;
  v_prev_actor text;
  c_actor constant text := 'automation:guardar_beneficiario_auto';
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
  -- (392) The batch text, not the agent, asks for a recarga: it names a recarga (negations honoured), carries Cuban mobiles and no card, a
  -- promo runs and no recarga is open yet. The recarga is declared and ALL the mobiles go through crm_registrar_numeros_recarga:
  --   * nothing open and the bot paused: only the declaration is kept (no operation is opened while a person handles the chat, 390);
  --   * nothing open: the registration opens the recarga;
  --   * exactly one open operation, an unfunded remesa whose recipients are phone-only (the bare-mobile cuban_card of a recarga
  --     typed in capture mode): it BECOMES the recarga (_cambiar_servicio_core keeps its phone-only recipients as recarga numbers),
  --     never a second operation (2026-10-22);
  --   * any other open operation: nothing here, the usual rules below apply.
  IF v_txt IS NOT NULL THEN
    SELECT array_agg(DISTINCT coalesce(m[1] || m[2], m[3] || m[4]) || m[5]) INTO v_movs
      FROM regexp_matches(v_txt, '(?<![0-9])(?:\+?53[ -]?([56])[ .-]?([0-9]{3})|([56])([0-9]{3}))[ .-]?([0-9]{4})(?![0-9])', 'g') AS m;
  END IF;
  IF v_txt IS NOT NULL AND coalesce(cardinality(v_movs), 0) >= 1
     AND coalesce(NULLIF(v_t, '!'), '') = '' AND coalesce(NULLIF(v_ta, '!'), '') = ''
     AND cerebro_texto_pide_recarga(v_txt) AND v_txt !~* 'zelle'
     AND (EXISTS (SELECT 1 FROM cerebro_promo_vigente()) OR EXISTS (SELECT 1 FROM cerebro_promo_proxima()))
     AND NOT EXISTS (SELECT 1 FROM remittance_operations o
                      WHERE o.conversation_id = p_conv AND o.service_type IN ('recarga', 'saldo') AND o.status NOT IN ('completed', 'cancelled')) THEN
    SELECT count(*) INTO v_n_open FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
    IF v_n_open = 0 THEN
      PERFORM cerebro_declarar_servicio(p_conv, 'recarga', c_actor);
      IF _cerebro_conversacion_pausada(p_conv) THEN
        RETURN QUERY SELECT NULL::uuid,
          'recarga anotada con ' || cardinality(v_movs) || ' numero(s), pero el bot esta pausado: no se abre ninguna operacion; los numeros se guardan cuando haya una'::text;
        RETURN;
      END IF;
    ELSIF v_n_open = 1 THEN
      PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_servicio:' || p_conv::text, 0));
      SELECT o.id INTO v_ph FROM remittance_operations o
       WHERE o.conversation_id = p_conv AND o.status IN ('collecting_information', 'awaiting_deposit') AND o.service_type = 'remesa'
         AND o.mixed_group_id IS NULL AND NOT _cerebro_op_tiene_dinero(o.id)
         AND NOT (coalesce(o.quoted_source_amount, 0) > 0 AND NOT _cerebro_op_monto_acordado(o.id))
         AND NOT EXISTS (SELECT 1 FROM unnest(ARRAY['delivery_method', 'service_type', 'beneficiaries']) k
                          WHERE coalesce(o.admin_locked_fields, '{}'::jsonb) ? k
                            AND coalesce(o.admin_locked_fields -> k ->> 'by', '') NOT LIKE 'automation:%')
         AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b
                          WHERE b.operation_id = o.id AND b.status = 'vigente'
                            AND (nullif(btrim(coalesce(b.card_number, '')), '') IS NOT NULL
                                 OR nullif(btrim(coalesce(b.zelle_account, '')), '') IS NOT NULL
                                 OR nullif(btrim(coalesce(b.address, '')), '') IS NOT NULL
                                 OR b.beneficiary_type NOT IN ('cuban_card', 'recarga')));
      IF v_ph IS NULL THEN v_n_open := -1; END IF;
    ELSE
      v_n_open := -1;
    END IF;
    IF v_n_open >= 0 THEN
      BEGIN
        PERFORM cerebro_declarar_servicio(p_conv, 'recarga', c_actor);
        IF v_ph IS NOT NULL THEN
          v_prev_origin := coalesce(current_setting('wacrm.origin', true), '');
          v_prev_actor := coalesce(current_setting('wacrm.actor', true), '');
          PERFORM set_config('wacrm.origin', 'admin', true);
          PERFORM set_config('wacrm.actor', c_actor, true);
          PERFORM _cambiar_servicio_core(v_ph, 'recarga', 'automation_service_change', c_actor, 'recarga typed in the batch: ' || c_actor);
          PERFORM set_config('wacrm.origin', v_prev_origin, true);
          PERFORM set_config('wacrm.actor', v_prev_actor, true);
        END IF;
        v_msg := crm_registrar_numeros_recarga(p_conv, v_txt, false, c_actor);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[wacrm] guardar_beneficiario_auto recarga by text failed for %: %', p_conv, SQLERRM;
        RETURN QUERY SELECT NULL::uuid, 'no se pudo registrar la recarga: una persona lo revisa'::text;
        RETURN;
      END;
      RETURN QUERY SELECT (SELECT o.id FROM remittance_operations o
                            WHERE o.conversation_id = p_conv AND o.service_type IN ('recarga', 'saldo') AND o.status NOT IN ('completed', 'cancelled')
                            ORDER BY o.created_at DESC LIMIT 1), v_msg;
      RETURN;
    END IF;
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
      crm_registrar_numeros_recarga(p_conv, coalesce(cerebro_textos_cliente_recientes(p_conv), '') || ' ' || coalesce(p_celular, '') || ' ' || coalesce(v_txt, ''),
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
  -- (392) More than one Cuban mobile and no card: a bare mobile is never written as a cuban_card recipient (which of them is the
  -- recipient, and for what, is the customer's to say). A cash delivery above already took its phone.
  IF v_txt IS NOT NULL AND coalesce(NULLIF(v_t, '!'), '') = '' AND coalesce(NULLIF(v_ta, '!'), '') = '' AND coalesce(cardinality(v_movs), 0) > 1 THEN
    RETURN QUERY SELECT v_res.operation_id,
      'llegaron ' || cardinality(v_movs) || ' celulares sin tarjeta: no se guarda ningun destinatario; preguntale al cliente para que es cada numero'::text;
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

REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario_auto(uuid, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
