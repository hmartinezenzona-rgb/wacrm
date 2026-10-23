-- Rollback of 276: previous bodies of cerebro_resolver_para_guardar, cerebro_marcar_destino_usd and crm_registrar_numeros_recarga;
-- drops _cerebro_ops_para_datos. Data written meanwhile stays.

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

CREATE OR REPLACE FUNCTION public.cerebro_marcar_destino_usd(p_conversation_id uuid, p_tipo text, p_execution_id text)
 RETURNS TABLE(id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Procedural, not a single CTE chain, for one concrete reason: the
-- `ins` branch must set delivery_method on the operation it has JUST
-- created, and every statement in one WITH chain shares one snapshot, so
-- an UPDATE cannot see the row inserted by cerebro_crear_operacion() in
-- the same statement. Two statements are needed, so the branches are
-- sequenced explicitly. The branch order and the emitted rows are exactly
-- the node's union order: falta, upd, ins, sin_cambio, ambiguo — with the
-- one multi-row case the node has (an invalid tipo AND two open
-- operations emits falta + ambiguo) preserved.
DECLARE
  v_resultado text;
  v_op        uuid;
  v_k         text;
  v_reg       integer;
  v_t         text;
  v_marker    text;
  v_actual    text;
  v_ben       text;
  v_nuevo     uuid;
  v_pend      text;
  v_lock_by   text;
  v_dm_nuevo  text;
BEGIN
  -- Inlined cerebro_resolver_operacion(uuid, text[]): see the header.
  SELECT CASE WHEN count(*) = 0 THEN 'ninguna'
              WHEN count(*) = 1 THEN 'unica'
              ELSE 'ambigua' END,
         CASE WHEN count(*) = 1
              THEN (SELECT o.id FROM remittance_operations o
                     WHERE o.conversation_id = p_conversation_id
                       AND o.status NOT IN ('completed','cancelled')
                       AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])
                     LIMIT 1)
         END
    INTO v_resultado, v_op
    FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.status NOT IN ('completed','cancelled')
     AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);

  v_k := p_execution_id || ':marcar_destino_usd:' || md5(coalesce(p_tipo,''));
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT v_k, 'marcar_destino_usd', p_execution_id, p_conversation_id, v_op,
         jsonb_build_array(to_jsonb(p_tipo::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING 1 INTO v_reg;

  v_t := CASE WHEN lower(p_tipo) LIKE 'trop%' THEN 'Tropical'
              WHEN lower(p_tipo) LIKE 'cl%'   THEN 'Clasica'
              WHEN lower(p_tipo) LIKE 'efec%' THEN 'Efectivo' END;
  -- 151 line 77: the notes marker the trigger turns into delivery_method is
  -- lower(t) for Clasica/Tropical and the literal 'efectivo_usd' for
  -- Efectivo. Same expression the old trigger's UPDATE used.
  v_marker := CASE WHEN v_t = 'Efectivo'      THEN 'efectivo_usd'
                   WHEN v_t IS NOT NULL       THEN lower(v_t) END;

  -- falta
  IF v_t IS NULL THEN
    UPDATE tool_execution_log SET outcome = 'tipo_invalido' WHERE idempotency_key = v_k;
    RETURN QUERY SELECT NULL::uuid AS id,
      'ERROR: el tipo debe ser clasica, tropical o efectivo. No se marco nada.'::text AS accion;
  END IF;

  IF v_t IS NOT NULL THEN
    -- (231) Stale-write guard 1. The agent declared another service in the last 5 minutes (cerebro_cambiar_servicio with no operation
    -- yet): a model that marks a rail from chat memory is older than that decision. Write nothing, say which one stands.
    SELECT p.tipo INTO v_pend
      FROM cerebro_destino_pendiente p
     WHERE p.conversation_id = p_conversation_id
       AND p.origen = 'agente'
       AND p.actualizado > now() - interval '5 minutes';
    IF v_pend IS NOT NULL AND v_pend IS DISTINCT FROM v_marker THEN
      UPDATE tool_execution_log SET outcome = 'rechazado' WHERE idempotency_key = v_k;
      RETURN QUERY SELECT NULL::uuid AS id,
        ('ERROR: ya elegiste ' ||
         CASE v_pend WHEN 'zelle' THEN 'Zelle' WHEN 'cuban_card' THEN 'CUP (tarjeta en pesos)' WHEN 'clasica' THEN 'Clasica' WHEN 'efectivo_usd' THEN 'Efectivo' ELSE 'Tropical' END ||
         ' para este cliente con cambiar_servicio y ahora intentas marcar ' || v_t ||
         '. No se marco nada. La via vigente es la que elegiste; si el cliente pide otra, usa cambiar_servicio.')::text AS accion;
      RETURN;
    END IF;

    -- (231) Stale-write guard 2. The open operation's rail was set by cerebro_cambiar_servicio (the lock stamped automation:) and this is a
    -- different rail. The 096 lock would suppress the write anyway, but this tool used to answer "destino marcado" -- the opposite of the truth.
    IF v_op IS NOT NULL THEN
      SELECT o.admin_locked_fields #>> '{delivery_method,by}', coalesce(nullif(o.delivery_method, ''), cerebro_riel_op(o.id))
        INTO v_lock_by, v_actual
        FROM remittance_operations o WHERE o.id = v_op;
      IF coalesce(v_lock_by, '') LIKE 'automation:%' AND v_actual IS DISTINCT FROM v_marker THEN
        UPDATE tool_execution_log SET outcome = 'rechazado' WHERE idempotency_key = v_k;
        RETURN QUERY SELECT NULL::uuid AS id,
          ('ERROR: la via vigente de la operacion es ' ||
           CASE v_actual WHEN 'zelle' THEN 'Zelle' WHEN 'cuban_card' THEN 'CUP (tarjeta en pesos)' WHEN 'clasica' THEN 'Clasica' WHEN 'efectivo_usd' THEN 'Efectivo' WHEN 'tropical' THEN 'Tropical' ELSE coalesce(v_actual, 'otra') END ||
           ' (la cambiaste con cambiar_servicio) y ahora intentas marcar ' || v_t ||
           '. No se marco nada. Si el cliente pide otra via, usa cambiar_servicio.')::text AS accion;
        RETURN;
      END IF;
    END IF;
  END IF;

  -- abierto: upd / sin_cambio (both need an operation, and a rail)
  IF v_op IS NOT NULL THEN
    IF v_t IS NOT NULL THEN
      SELECT o.delivery_method,
             (SELECT b.beneficiary_type FROM remittance_beneficiaries b
               WHERE b.operation_id = o.id AND b.status = 'vigente'
               LIMIT 1)
        INTO v_actual, v_ben
        FROM remittance_operations o WHERE o.id = v_op;

      -- 'ENTREGA EN USD: <t>' in deals.notes becomes delivery_method = marker(t).
      IF coalesce(v_actual = v_marker, false) THEN
        -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
        IF v_t IN ('Clasica', 'Tropical') THEN
          PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
        END IF;
        UPDATE tool_execution_log SET outcome = 'sin_cambios' WHERE idempotency_key = v_k;
        RETURN QUERY SELECT v_op AS id,
          'sin cambios: ese destino ya estaba marcado'::text AS accion;
      ELSE
        UPDATE remittance_operations o
           SET delivery_method = coalesce(v_marker, v_ben, o.delivery_method)
         WHERE o.id = v_op
           AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, v_ben, o.delivery_method);
        -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
        IF v_t IN ('Clasica', 'Tropical') THEN
          PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
        END IF;
        UPDATE tool_execution_log SET outcome = 'marcado' WHERE idempotency_key = v_k;
        RETURN QUERY SELECT v_op AS id,
          ('destino marcado: entrega en USD por ' || v_t)::text AS accion;
      END IF;
    END IF;
    RETURN;
  END IF;

  -- no operation: ambiguo, or the node's `ins`
  IF v_resultado = 'ambigua' THEN
    UPDATE tool_execution_log SET outcome = 'operacion_ambigua' WHERE idempotency_key = v_k;
    RETURN QUERY
    SELECT NULL::uuid AS id,
           'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text AS accion
      FROM cerebro_registrar_derivacion(
             p_conversation_id,
             'Hay varias operaciones abiertas y el caso requiere revisión humana.',
             'operacion_ambigua',
             true) d;
  ELSIF v_t IS NOT NULL THEN
    v_nuevo := cerebro_crear_operacion(p_conversation_id);
    -- (231) The new operation may already have a rail: the agent's pending service is applied by the creation trigger. Do not write a
    -- different one over it, and do not claim it.
    SELECT o.delivery_method INTO v_dm_nuevo FROM remittance_operations o WHERE o.id = v_nuevo;
    IF v_dm_nuevo IS NOT NULL AND v_dm_nuevo IS DISTINCT FROM v_marker THEN
      UPDATE tool_execution_log SET outcome = 'rechazado' WHERE idempotency_key = v_k;
      RETURN QUERY SELECT v_nuevo AS id,
        ('ERROR: se creo el envio pero su via ya es ' ||
         CASE v_dm_nuevo WHEN 'zelle' THEN 'Zelle' WHEN 'cuban_card' THEN 'CUP (tarjeta en pesos)' WHEN 'clasica' THEN 'Clasica' WHEN 'efectivo_usd' THEN 'Efectivo' ELSE 'Tropical' END ||
         ' (la elegiste con cambiar_servicio) y no se marco ' || v_t || '. Si el cliente pide otra via, usa cambiar_servicio.')::text AS accion;
      RETURN;
    END IF;
    UPDATE remittance_operations o
       SET delivery_method = coalesce(v_marker, o.delivery_method)
     WHERE o.id = v_nuevo
       AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, o.delivery_method);
    -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
    IF v_t IN ('Clasica', 'Tropical') THEN
      PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
    END IF;
    UPDATE tool_execution_log SET outcome = 'marcado' WHERE idempotency_key = v_k;
    RETURN QUERY SELECT v_nuevo AS id,
      ('envio nuevo creado, entrega en USD por ' || v_t)::text AS accion;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_registrar_numeros_recarga(p_conv uuid, p_texto text, p_abrir boolean DEFAULT false, p_actor text DEFAULT NULL::text)
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

DROP FUNCTION IF EXISTS public._cerebro_ops_para_datos(uuid, text);
