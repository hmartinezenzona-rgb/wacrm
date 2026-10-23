-- ROLLBACK 289: back to the 243 / 286 bodies.
CREATE OR REPLACE FUNCTION public.cerebro_cotizar(p_conv uuid, p_monto numeric, p_direccion text, p_moneda_destino text, p_via text DEFAULT NULL::text, p_execution_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  -- El cliente SIEMPRE deposita guyaneses: ver la divergencia 2 de la cabecera.
  c_origen  constant text := 'gyd';
  v_dir     text := lower(btrim(coalesce(p_direccion, '')));
  v_dest    text := lower(btrim(coalesce(p_moneda_destino, '')));
  v_via     text := lower(btrim(coalesce(p_via, '')));
  v_unica   boolean;
  v_tasa_u  numeric;   -- la tasa unica de usd (Clasica, Tropical, Mexico, USDT)
  v_tasa    numeric;   -- la tasa que se aplica de verdad a esta cotizacion
  v_gyd     numeric;   -- lo que deposita el cliente
  v_destino numeric;   -- lo que recibe el beneficiario
  v_usd     numeric;
  v_exacto  numeric;   -- solo gyd->usd: los GYD exactos de esos dolares enteros
  v_aplica  text;
  v_herr    text;      -- la etiqueta por direccion, preservada para la auditoria
BEGIN
  IF p_conv IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'sin_conversacion');
  END IF;
  IF p_monto IS NULL OR p_monto <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'monto_invalido');
  END IF;

  -- Direccion. 'desde_deposito' = el cliente dice lo que DEPOSITA y quiere saber que llega;
  -- 'hacia_destino' = dice lo que quiere que LLEGUE y quiere saber cuanto depositar.
  IF v_dir IN ('desde_deposito', 'deposito', 'desde') THEN
    v_dir := 'desde_deposito';
  ELSIF v_dir IN ('hacia_destino', 'destino', 'hacia') THEN
    v_dir := 'hacia_destino';
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'direccion_desconocida',
                              'direccion', p_direccion,
                              'validas', jsonb_build_array('desde_deposito', 'hacia_destino'));
  END IF;

  IF v_dest IN ('cup', 'pesos', 'pesos_cubanos') THEN
    v_dest := 'cup';
  ELSIF v_dest IN ('usd', 'dolares', 'dolar') THEN
    v_dest := 'usd';
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'moneda_destino_desconocida',
                              'moneda_destino', p_moneda_destino,
                              'validas', jsonb_build_array('cup', 'usd'));
  END IF;

  -- Divergencia 1: el efectivo tiene su propia tasa y su propia tool. Antes se colaba como Zelle.
  IF v_via ~ '^efectivo' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'efectivo_tiene_tasa_propia',
                              'usa', 'consultar_servicio(''efectivo_usd'')');
  END IF;

  IF v_dest = 'cup' THEN
    -- ---------------------------------------------------------------- CUP
    SELECT t.tasa_cup INTO v_tasa
      FROM tasas t
     WHERE t.moneda = c_origen
     ORDER BY t.fecha DESC, t.actualizada_at DESC
     LIMIT 1;
    IF v_tasa IS NULL OR v_tasa <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', c_origen);
    END IF;

    IF v_dir = 'desde_deposito' THEN           -- era calcular_envio
      v_herr    := 'calcular_envio';
      v_gyd     := p_monto;
      v_destino := round(p_monto * v_tasa);
    ELSE                                        -- era calcular_inverso
      v_herr    := 'calcular_inverso';
      v_destino := p_monto;
      -- ceil al multiplo de 20 superior, igual que calcular_inverso con moneda='gyd'
      v_gyd     := ceil((p_monto / v_tasa) / 20) * 20;
    END IF;
    v_aplica := 'Tarjeta en CUP';

    PERFORM cerebro_registrar_cotizacion(p_conv, v_gyd, v_destino, 'CUP', v_herr);
    PERFORM cerebro_registrar_via_cotizada(p_conv, v_herr, 'cuban_card', p_execution_id, NULL);

    RETURN jsonb_build_object(
      'ok', true, 'herramienta', v_herr, 'direccion', v_dir,
      'deposita_gyd', v_gyd, 'recibe_monto', v_destino, 'recibe_moneda', 'CUP',
      'tasa', v_tasa, 'aplica_a', v_aplica);
  END IF;

  -- ------------------------------------------------------------------ USD
  -- Zelle va por TRAMOS de USD; Clasica, Tropical, Mexico y USDT tienen tasa unica. Vacio = Zelle,
  -- igual que hoy.
  v_unica := (coalesce(nullif(v_via, ''), 'zelle') ~ '^(cl[aá]sica|tropical|m[eé]xico|usdt)');
  SELECT t.tasa_cup INTO v_tasa_u
    FROM tasas t
   WHERE t.moneda = 'usd'
   ORDER BY t.fecha DESC, t.actualizada_at DESC
   LIMIT 1;
  v_aplica := CASE WHEN v_unica THEN 'Clasica/Tropical/Mexico (tasa unica)'
                   ELSE 'Zelle (por tramos)' END;

  IF v_dir = 'hacia_destino' THEN               -- era calcular_usd
    v_herr := 'calcular_usd';
    -- floor y no round: los dolares SIEMPRE se entregan enteros, y redondear hacia arriba
    -- prometeria un dolar mas de lo que cubre el deposito.
    v_usd  := floor(p_monto);
    IF v_usd <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'monto_invalido');
    END IF;
    v_tasa := CASE WHEN v_unica THEN v_tasa_u
                   ELSE coalesce(cerebro_tasa_zelle(v_usd), v_tasa_u) END;
    IF v_tasa IS NULL OR v_tasa <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', 'usd');
    END IF;
    v_gyd     := round(v_usd * v_tasa);
    v_destino := v_usd;
    -- Apunta el objetivo del envio (072/075) para que un deposito que no lo cubra no se de por
    -- bueno. Va aqui y no en una tool aparte porque el modelo no llama a la tool aparte: se monto
    -- `fijar_objetivo`, se le ordeno en dos sitios del prompt, y fue 0 de 2 con mensajes reales.
    PERFORM * FROM cerebro_fijar_objetivo(p_conv, v_usd, 'USD');
  ELSE                                           -- era calcular_usd_desde_gyd
    v_herr := 'calcular_usd_desde_gyd';
    v_gyd  := p_monto;
    IF v_unica THEN
      IF v_tasa_u IS NULL OR v_tasa_u <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', 'usd');
      END IF;
      v_tasa := v_tasa_u;
      v_usd  := floor(p_monto / v_tasa_u);
    ELSE
      SELECT z.usd, z.tasa INTO v_usd, v_tasa
        FROM cerebro_zelle_cotizar_gyd(p_monto) z;
      -- el COALESCE a la tasa unica es el de calcular_usd_desde_gyd, no una invencion
      IF v_tasa IS NULL OR v_tasa <= 0 THEN
        IF v_tasa_u IS NULL OR v_tasa_u <= 0 THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', 'usd');
        END IF;
        v_tasa := v_tasa_u;
      END IF;
      v_usd := coalesce(v_usd, floor(p_monto / v_tasa_u));
    END IF;
    v_destino := v_usd;
    v_exacto  := round(v_usd * v_tasa);
  END IF;

  PERFORM cerebro_registrar_cotizacion(p_conv, v_gyd, v_destino, 'USD', v_herr);
  PERFORM cerebro_registrar_via_cotizada(p_conv, v_herr, nullif(v_via, ''), p_execution_id, v_gyd);

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'ok', true, 'herramienta', v_herr, 'direccion', v_dir,
    'deposita_gyd', v_gyd, 'recibe_monto', v_destino, 'recibe_moneda', 'USD',
    'tasa', v_tasa, 'aplica_a', v_aplica,
    'via', nullif(v_via, ''),
    'deposita_gyd_exacto', v_exacto));
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_registrar_numeros_recarga(p_conv uuid, p_texto text, p_abrir boolean DEFAULT false, p_actor text DEFAULT NULL::text, p_accion text DEFAULT 'agregar'::text)
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
  v_accion text := lower(btrim(coalesce(p_accion, 'agregar')));
  v_removed int := 0;
  v_missing text[] := ARRAY[]::text[];
  v_nid    uuid;
  -- (268) the real actor of the write (the agent's tool passes its own name); the default is the bot's automation
  v_actor  text := coalesce(nullif(btrim(p_actor), ''), 'automation:registrar_numeros_recarga');
  v_source text := CASE WHEN coalesce(nullif(btrim(p_actor), ''), 'automation:registrar_numeros_recarga') LIKE 'automation:%'
                        THEN 'reparto_auto' ELSE 'agente' END;
BEGIN
  IF v_accion NOT IN ('agregar', 'quitar') THEN
    RETURN 'ERROR: la accion debe ser agregar o quitar. No se cambio nada.';
  END IF;

  -- (282) 'quitar': the numbers named in p_texto leave the open recharge (they are retired, not deleted: status 'reemplazado').
  IF v_accion = 'quitar' THEN
    SELECT o.id, o.account_id, o.quoted_source_amount, o.admin_locked_fields, o.status INTO v_op
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
     ORDER BY o.created_at DESC LIMIT 1
     FOR UPDATE;
    IF v_op.id IS NULL THEN
      RETURN 'sin recarga en curso: no hay ningun numero de recarga que quitar';
    END IF;
    IF v_op.status = 'transferring' THEN
      RETURN 'la recarga ya esta en transferencia: no quito numeros, una persona lo revisa';
    END IF;
    IF coalesce(v_op.admin_locked_fields, '{}'::jsonb) ? 'beneficiaries' THEN
      RETURN 'los numeros de esta recarga los gestiona una persona desde el panel: no se cambian';
    END IF;
    FOR v_m IN SELECT regexp_matches(coalesce(p_texto, ''),
                                     '(?<![0-9])(?:\+?53[ -]?([56])[ .-]?([0-9]{3})|([56])([0-9]{3}))[ .-]?([0-9]{4})(?![0-9])', 'g') LOOP
      v_num := coalesce(v_m[1] || v_m[2], v_m[3] || v_m[4]) || v_m[5];
      v_nid := NULL;
      UPDATE remittance_beneficiaries SET status = 'reemplazado', replaced_at = now()
       WHERE operation_id = v_op.id AND status = 'vigente' AND beneficiary_type = 'recarga' AND phone = v_num
      RETURNING id INTO v_nid;
      IF v_nid IS NOT NULL THEN v_removed := v_removed + 1; ELSE v_missing := v_missing || v_num; END IF;
    END LOOP;
    IF v_removed > 0 THEN
      UPDATE remittance_beneficiaries b SET position = r.n
        FROM (SELECT id, row_number() OVER (ORDER BY position, id) AS n FROM remittance_beneficiaries
               WHERE operation_id = v_op.id AND status = 'vigente') r
       WHERE b.id = r.id AND b.position IS DISTINCT FROM r.n;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
      VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'recarga_numbers', 'agent_recharge_number_removed',
              v_actor, NULL, jsonb_build_object('removed', v_removed, 'texto', left(coalesce(p_texto, ''), 300)));
    END IF;
    SELECT count(*) INTO v_have FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente' AND beneficiary_type = 'recarga';
    v_need := cerebro_recarga_unidades(v_op.quoted_source_amount);
    RETURN CASE WHEN v_removed = 0 AND cardinality(v_missing) = 0 THEN 'no vi ningun numero cubano en el texto: no se quito nada; la recarga tiene ' || v_have || '.'
                ELSE 'quitados ' || v_removed || ' numero(s) de recarga; la recarga tiene ' || v_have || '.' END
           || CASE WHEN cardinality(v_missing) > 0 THEN ' No estaban en la recarga: ' || array_to_string(v_missing, ', ') || '.' ELSE '' END
           || CASE WHEN coalesce(v_need, 0) = 0 THEN ''
                   WHEN v_have >= v_need THEN ' Numeros completos (' || v_have || ' de ' || v_need || ').'
                   ELSE ' FALTA ' || (v_need - v_have) || ' numero(s) de recarga (son ' || v_need || ' recargas, un numero por recarga). Pideselo al cliente.' END;
  END IF;

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
    -- (283) only when money is registered: a service change is allowed without money since 283, but opening a recharge must not turn an empty
    -- operation of another service into it (a mixed send before the deposit keeps its parts separate, 276).
    IF EXISTS (SELECT 1 FROM remittance_operations x
                WHERE x.conversation_id = p_conv AND x.status NOT IN ('completed', 'cancelled')
                  AND (EXISTS (SELECT 1 FROM remittance_operation_receipts r WHERE r.operation_id = x.id)
                       OR EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = x.id AND d.anulado_en IS NULL AND d.descartado_en IS NULL))) THEN
      PERFORM cerebro_aplicar_servicio(p_conv, 'recarga', 'cambiar', v_actor, NULL);
    END IF;
    SELECT o.id, o.account_id, o.quoted_source_amount, o.admin_locked_fields INTO v_op
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
     ORDER BY o.created_at DESC LIMIT 1
     FOR UPDATE;
    IF v_op.id IS NULL THEN
      -- (268) Another open operation exists and the resolver did not convert it: no second operation is created.
      -- (276) ... unless every open operation is still EMPTY (collecting, no deposit, no receipt, no money, not in a mixed group): the
      -- recharge is then one more part of a send planned before the deposit and opens as its own empty operation (the split reuses it).
      IF EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
                    AND (o.mixed_group_id IS NOT NULL OR coalesce(o.quoted_source_amount, 0) > 0
                         OR o.status NOT IN ('collecting_information', 'awaiting_deposit')
                         OR EXISTS (SELECT 1 FROM remittance_operation_receipts x WHERE x.operation_id = o.id)
                         OR EXISTS (SELECT 1 FROM depositos_mmg x WHERE x.operation_id = o.id AND x.anulado_en IS NULL AND x.descartado_en IS NULL))) THEN
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

DROP FUNCTION IF EXISTS public._cerebro_declarar_implicito(uuid, text, text);
