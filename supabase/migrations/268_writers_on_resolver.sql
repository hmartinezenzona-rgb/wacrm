-- =====================================================================
-- 268 -- the recharge-number writers take their service from facts and the agent's declaration, never from words
--
-- odd/tasks/service-resolution.md (REDESIGN 2026-10-22: intent = the agent, rules = the database). Changes against the
-- LIVE bodies on staging (exact text in ROLLBACK-268-writers-on-resolver.sql); nothing else moves.
--
--   crm_registrar_numeros_recarga (live: 3 arguments, the open recharge or a new one when the live text rule said so):
--     - number regex: a Cuban mobile (starts with 5 or 6) as 8 digits, written 55599180, 5559 9180, 5559-9180,
--       +53 55599180, +5355599180, +53 5 5599180, 53 5 5599180, +53 5 559 9180. The separator after the leading 5/6 is
--       accepted only after the country prefix. 7-digit, 9-digit and runs not starting with 5/6 register nothing.
--     - new parameter p_actor text DEFAULT NULL (4th, last). The audit actor is coalesce(p_actor,
--       'automation:registrar_numeros_recarga') (live: wacrm_current_actor()). remittance_beneficiaries.source is
--       'reparto_auto' for an 'automation:' actor and 'agente' otherwise (source has no CHECK).
--     - no open recharge: the recharge opens only when p_abrir (the agent declared it) or the agent DECLARED a recharge
--       (cerebro_servicio_declarado). The live text rule (cerebro_recarga_en_curso) is gone. The live promo guards stay.
--       Then cerebro_aplicar_servicio(conv, 'recarga', 'cambiar', actor) runs under the conversation lock and is read
--       again: a holder it converts is the recharge (no INSERT). Otherwise a new recharge is inserted ONLY when the
--       conversation has no other open operation; if it has one, nothing is inserted and the resolver's mensaje
--       (or 'no se abre otra recarga' when it has none) is returned, so no second operation is ever created.
--     - the 3-argument live signature is dropped (an overload with defaults would make a 3-argument call ambiguous).
--       Callers with 2 or 3 arguments keep working. ACL: service_role only (as live).
--
--   cerebro_guardar_beneficiario_auto (live body; signature and ACL unchanged):
--     - the live recharge branches that opened a recharge from the customer's words (cerebro_recarga_en_curso) are
--       replaced by one branch: a Cuban number with no card goes to the recharge tool when a recharge is OPEN or the
--       agent DECLARED one. Nothing else opens an operation from words. Otherwise the live remesa routing runs.
--
-- Guarded by supabase/staging/assertions/writers-resolver.sql. ROLLBACK: ROLLBACK-268-writers-on-resolver.sql
-- =====================================================================

DROP FUNCTION IF EXISTS public.crm_registrar_numeros_recarga(uuid, text, boolean);

CREATE OR REPLACE FUNCTION public.crm_registrar_numeros_recarga(p_conv uuid, p_texto text, p_abrir boolean DEFAULT false, p_actor text DEFAULT NULL)
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
  -- (268) the real actor of the write (the agent's tool passes its own name); the default is the bot's automation
  v_actor  text := coalesce(nullif(btrim(p_actor), ''), 'automation:registrar_numeros_recarga');
  v_source text := CASE WHEN coalesce(nullif(btrim(p_actor), ''), 'automation:registrar_numeros_recarga') LIKE 'automation:%'
                        THEN 'reparto_auto' ELSE 'agente' END;
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
    -- (268) or the agent declared a recharge (cerebro_servicio_declarado). Words never open it.
    IF NOT (p_abrir OR EXISTS (SELECT 1 FROM cerebro_servicio_declarado d
                                WHERE d.conversation_id = p_conv AND d.servicio = 'recarga')) THEN
      RETURN 'sin recarga en curso: no se guarda ningun numero de recarga';
    END IF;
    -- (207) A new recharge opens only with a promo running or a confirmed one ahead (booked for its start date): with
    -- neither, the bot was asking for a number for a recharge nobody could do. Nothing is saved then.
    IF NOT EXISTS (SELECT 1 FROM cerebro_promo_vigente()) AND NOT EXISTS (SELECT 1 FROM cerebro_promo_proxima()) THEN
      RETURN 'NO HAY PROMOCION DE ETECSA, ni vigente ni anunciada: no se abre ninguna recarga y no se guarda ningun numero. '
             || 'PROHIBIDO pedir el numero de Cuba. Ofrece pasar con un operador.';
    END IF;
    -- (268) The resolver decides the service under the conversation lock (the one cerebro_aplicar_servicio takes). A
    -- remesa holder that the deposit covers becomes the recharge; the operation is then read again (no second one).
    PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_servicio:' || p_conv::text, 0));
    PERFORM cerebro_aplicar_servicio(p_conv, 'recarga', 'cambiar', v_actor, NULL);
    SELECT o.id, o.account_id, o.quoted_source_amount, o.admin_locked_fields INTO v_op
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
     ORDER BY o.created_at DESC LIMIT 1
     FOR UPDATE;
    IF v_op.id IS NULL THEN
      -- (268) Another open operation exists and the resolver did not convert it: no second operation is created.
      IF EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')) THEN
        RETURN coalesce(cerebro_resolver_servicio(p_conv, 'recarga', 'cambiar') ->> 'mensaje',
                        'no se abre otra recarga: la conversacion ya tiene una operacion abierta.');
      END IF;
      INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
      SELECT v.account_id, v.id, v.contact_id, 'collecting_information', 'recarga', 'GYD', 0
        FROM conversations v WHERE v.id = p_conv
      RETURNING id, account_id, quoted_source_amount, admin_locked_fields INTO v_op;
    END IF;
  END IF;
  IF coalesce(v_op.admin_locked_fields, '{}'::jsonb) ? 'beneficiaries' THEN
    RETURN 'los numeros de esta recarga los gestiona una persona desde el panel: no se cambian';
  END IF;

  -- (268) Cuban mobiles: 8 digits written 55599180, 5559 9180, 5559-9180, or after the prefix 53 with the separators
  -- of the WhatsApp format (+53 5 5599180, +53 5 559 9180). m[1..2] = after the prefix, m[3..4] = without prefix,
  -- m[5] = the last four digits. The separator after the leading 5/6 exists only after the prefix.
  FOR v_m IN SELECT regexp_matches(coalesce(p_texto, ''),
                                   '(?<![0-9])(?:\+?53[ -]?([56])[ .-]?([0-9]{3})|([56])([0-9]{3}))[ .-]?([0-9]{4})(?![0-9])', 'g') LOOP
    v_num := coalesce(v_m[1] || v_m[2], v_m[3] || v_m[4]) || v_m[5];
    CONTINUE WHEN EXISTS (SELECT 1 FROM remittance_beneficiaries b
                           WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.phone = v_num);
    SELECT coalesce(max(position), 0) + 1 INTO v_pos FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_block FROM remittance_beneficiaries WHERE operation_id = v_op.id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
    VALUES (v_op.id, 'recarga', v_num, v_pos, v_block, v_source, 'vigente');
    v_added := v_added + 1;
  END LOOP;

  IF v_added > 0 THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'recarga_numbers', 'automation_recharge_numbers_registered',
            v_actor, NULL, jsonb_build_object('added', v_added, 'texto', left(coalesce(p_texto, ''), 300)));
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

REVOKE ALL ON FUNCTION public.crm_registrar_numeros_recarga(uuid, text, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crm_registrar_numeros_recarga(uuid, text, boolean, text) TO service_role;

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
