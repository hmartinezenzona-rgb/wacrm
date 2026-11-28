-- ROLLBACK 178: restore 170's cerebro_registrar_deposito and 114's cerebro_cruzar_depositos.

CREATE OR REPLACE FUNCTION public.cerebro_registrar_deposito(p_conv uuid, p_monto numeric, p_moneda text, p_stage uuid, p_nota text, p_comp_id text)
 RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
-- (114) The creado path's `ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL`
-- collides with this function's `deal_id` OUT parameter and raised
-- `column reference \"deal_id\" is ambiguous` on every new receipt (staging
-- smoke 2026-09-26). use_column only affects references that were
-- ambiguous, i.e. that raised; every other reference resolves as before.
-- Guarded by supabase/staging/assertions/registrar-deposito-creado.sql.
DECLARE
  v_rev     boolean;
  v_recarga boolean := false;
  v_ya      uuid;
  v_ex      uuid;
  v_suma    uuid;
  v_id      uuid;
  v_phone   text;
  v_ref     text;
  v_nota    text;
  v_contact uuid;
  v_total   numeric;
  v_ventana integer := COALESCE(NULLIF(cerebro_config_get('completar_ventana_horas'), '')::int, 6);
  v_min_cup numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
BEGIN
  v_rev := cerebro_es_revendedor(p_conv);

  v_nota := COALESCE(p_nota,'');
  IF NULLIF(p_comp_id,'') IS NOT NULL AND v_nota NOT LIKE '%'||p_comp_id||'%' THEN
    v_nota := v_nota || chr(10) || p_comp_id;
  END IF;

  IF NOT cerebro_transid_plausible(NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '')) THEN
    p_stage := 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid;
    v_nota := v_nota || chr(10)
      || 'REFERENCIA IMPOSIBLE: ese numero no puede ser un TransID de MMG. El contador '
      || 'solo crece y este queda por debajo de todos los recibidos, asi que casi seguro '
      || 'lo leyo la vision de una CAPTURA o de una foto de otra pantalla, no de un '
      || 'comprobante directo. NO se ha registrado como deposito normal: mire la imagen y '
      || 'pidale al cliente el comprobante original antes de dar nada por recibido.';
  END IF;
  v_ref := NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '');

  IF NULLIF(p_comp_id,'') IS NOT NULL THEN
    SELECT d.id INTO v_ya FROM deals d
     WHERE d.conversation_id = p_conv
       AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND COALESCE(d.notes,'') LIKE '%'||p_comp_id||'%'
     LIMIT 1;
    IF v_ya IS NOT NULL THEN
      RETURN QUERY SELECT v_ya, 'ya registrado (idempotente)'::text, v_rev, false; RETURN;
    END IF;
  END IF;

  IF NOT v_rev THEN
    SELECT d.id INTO v_ex
      FROM deals d
     WHERE d.conversation_id = p_conv
       AND d.status = 'open'
       AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND d.stage_id IN ('96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109',
                          '3cf01654-cd27-47c1-ac92-62abf5435751',
                          'f5cf87f8-b570-4d71-b6ea-a3cafd458c63')
       AND COALESCE(d.notes,'') NOT LIKE '%DEPOSITO%'
       AND NOT (d.value > 0 AND COALESCE(d.notes,'') LIKE '%BENEFICIARIO%')
     ORDER BY d.created_at DESC LIMIT 1;
  END IF;

  -- (170) The open WAITING remesa this deposit completes. Read from the operation
  -- (114 stopped writing deals.stage_id, so the old stage filter never matched): a
  -- remesa of this chat still being verified or in incident, opened in the window,
  -- that is below its service minimum, still owes saldo, or this deposit alone is
  -- below the smallest minimum and so cannot be a remesa of its own. A remesa that is
  -- ready to transfer is never touched.
  IF NOT v_rev AND v_ex IS NULL THEN
    SELECT d.id INTO v_suma
      FROM remittance_operations o
      JOIN deals d ON d.id = o.deal_id
     WHERE o.conversation_id = p_conv
       AND d.status = 'open'
       AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND o.service_type = 'remesa'
       AND o.status IN ('deposit_verification', 'incident')
       AND o.created_at > now() - make_interval(hours => v_ventana)
       AND COALESCE(d.notes,'') LIKE '%DEPOSITO%'
       AND COALESCE(d.notes,'') NOT LIKE '%REFERENCIA IMPOSIBLE%'
       AND (COALESCE((SELECT s.saldo FROM cerebro_saldo_envio(d.id) s), 0) > 0
            OR o.quoted_source_amount < cerebro_minimo_gyd(o.id)
            OR p_monto < v_min_cup)
     ORDER BY o.created_at DESC LIMIT 1;
  END IF;

  IF v_ex IS NOT NULL THEN
    UPDATE deals
       SET value = p_monto, currency = p_moneda,
           notes = COALESCE(notes,'') || E'\n---\n' || v_nota, updated_at = now()
     WHERE id = v_ex
    RETURNING contact_id INTO v_contact;
    -- (114) Direct, self-sufficient write: replaces both halves of the
    -- retired bridge trigger for this branch (status derivation AND
    -- quoted_source_amount/contact_id mirroring). `deals.stage_id` is no
    -- longer written by this function; `p_stage` still decides the
    -- operation's status.
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           quoted_source_amount = p_monto,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.deal_id = v_ex;
    PERFORM cerebro_objetivo_atar(p_conv, v_ex);
    -- (170) Below the minimum of its service: wait for the rest.
    PERFORM cerebro_objetivo_minimo(p_conv, v_ex);
    RETURN QUERY SELECT v_ex, 'movido'::text, false, false; RETURN;
  END IF;

  IF v_suma IS NOT NULL THEN
    SELECT o.quoted_source_amount + p_monto INTO v_total FROM remittance_operations o WHERE o.deal_id = v_suma;
    UPDATE deals
       SET value    = v_total,
           currency = p_moneda,
           notes    = COALESCE(notes,'') || E'\n---\n' || v_nota || chr(10)
                      || 'SUMADO AL MISMO ENVIO (170): completa la remesa abierta, total '
                      || rtrim(trim(to_char(v_total, 'FM999,999,999,990.99')), '.') || ' ' || p_moneda || '.',
           updated_at = now()
     WHERE id = v_suma
    RETURNING contact_id INTO v_contact;
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           quoted_source_amount = v_total,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.deal_id = v_suma;
    PERFORM cerebro_objetivo_atar(p_conv, v_suma);
    -- (170) The objetivo covers the whole remesa, so the cross waits until EVERY receipt
    -- of it is verified; then the earlier receipts that were never crossed are crossed
    -- now. This one is crossed by the Cerebro's own node right after this call.
    PERFORM cerebro_objetivo_minimo(p_conv, v_suma, true);
    PERFORM cerebro_cruzar_pendientes(v_suma, v_ref);
    RETURN QUERY SELECT v_suma, 'sumado al envio abierto'::text, false, true; RETURN;
  END IF;

  IF NOT v_rev THEN
    SELECT EXISTS (
             SELECT 1 FROM messages m
              WHERE m.conversation_id = p_conv
                AND m.sender_type = 'customer'
                AND m.created_at > GREATEST(
                      now() - interval '24 hours',
                      COALESCE((SELECT max(d9.updated_at) FROM deals d9
                                 WHERE d9.conversation_id = p_conv
                                   AND (d9.status <> 'open'
                                        OR d9.stage_id = '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b')),
                               now() - interval '24 hours'))
                AND (m.content_text ILIKE '%recarga%'
                     OR m.content_text ILIKE '%etecsa%'
                     OR m.content_text ILIKE '%cubacel%'))
       AND NOT EXISTS (
             SELECT 1 FROM cerebro_beneficiario_parcial bp
              WHERE bp.conversation_id = p_conv
                AND COALESCE(bp.tarjeta,'') <> '')
      INTO v_recarga;
  END IF;

  SELECT c.phone, v.contact_id INTO v_phone, v_contact
    FROM conversations v JOIN contacts c ON c.id = v.contact_id WHERE v.id = p_conv;

  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                     stage_id, title, value, currency, notes, status)
  SELECT v.user_id, v.account_id, v.contact_id, v.id,
         '78220927-0745-45a8-ba08-a1b33734dbf1', p_stage,
         CASE WHEN v_rev
              THEN 'Remesa REVENDEDOR - Ref ' || COALESCE(v_ref, to_char(now(),'DDMM-HH24MI'))
              WHEN v_recarga
              THEN 'Recarga +' || COALESCE(v_phone,'?')
              ELSE 'Remesa +' || COALESCE(v_phone,'?') END,
         p_monto, p_moneda, v_nota, 'open'
    FROM conversations v WHERE v.id = p_conv
  RETURNING id INTO v_id;

  IF NOT v_rev THEN PERFORM cerebro_objetivo_atar(p_conv, v_id); END IF;

  -- (114) Explicit creation, replacing the row-creation half of the
  -- retired bridge trigger. Same columns/values that trigger's INSERT
  -- branch used (041/043/060): status derived from p_stage,
  -- completed_at/cancelled_at seeded consistently even though p_stage
  -- is never Entregada/cancelled-mapped from this call site in practice
  -- (kept for parity with the mapping function's full range).
  INSERT INTO remittance_operations (
    account_id, conversation_id, contact_id, deal_id, status,
    service_type, quoted_source_amount, source_currency, created_at,
    completed_at, cancelled_at
  )
  SELECT v.account_id, v.id, v_contact, v_id,
         cerebro_estado_desde_etapa(p_stage),
         CASE WHEN v_recarga THEN 'recarga' ELSE 'remesa' END,
         p_monto, coalesce(p_moneda, 'GYD'), now(),
         CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'completed' THEN now() END,
         CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'cancelled' THEN now() END
    FROM conversations v WHERE v.id = p_conv
  -- (125) The deal INSERT above now creates this row through
  -- trg_sync_operacion_al_crear_deal, always as 'remesa'. Keep the recarga
  -- classification this function decides: only service_type is corrected,
  -- and only when it differs, so a plain remesa writes nothing twice.
  ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL DO UPDATE
    SET service_type = EXCLUDED.service_type
    WHERE remittance_operations.service_type IS DISTINCT FROM EXCLUDED.service_type;

  -- (170) Below the minimum of its service: wait for the rest.
  IF NOT v_rev THEN PERFORM cerebro_objetivo_minimo(p_conv, v_id); END IF;

  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_cruzar_depositos(p_deal uuid, p_refs text[], p_montos numeric[], p_stage_ok uuid, p_stage_incidencia uuid, p_stage_esperado uuid, p_simular boolean DEFAULT false)
 RETURNS TABLE(resultado text, trans_id text, deal_actualizado integer, metodo text, todos_verificados boolean, total_verificado numeric, n_comprobantes integer, detalle jsonb, objetivo numeric, depositado numeric, saldo numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n int; v_i int; v_c record;
  v_det jsonb := '[]'::jsonb; v_todos boolean := true; v_total numeric := 0;
  v_trans1 text := NULL; v_fallo text := NULL; v_metodo text := 'exacto';
  v_nota text; v_tocados int := 0; v_refs_ok int;
  v_obj numeric; v_dep numeric; v_saldo numeric; v_mon text;
  v_stage_final uuid;
BEGIN
  v_n := COALESCE(array_length(p_refs, 1), 0);

  SELECT s.objetivo, s.moneda INTO v_obj, v_mon FROM cerebro_saldo_envio(p_deal) s;

  IF v_n <= 1 AND v_obj IS NULL THEN
    RETURN QUERY
      SELECT c.resultado, c.trans_id, c.deal_actualizado, c.metodo,
             (c.resultado = 'verificado'),
             CASE WHEN c.resultado = 'verificado' THEN COALESCE(p_montos[1], 0) ELSE 0 END,
             v_n,
             jsonb_build_array(jsonb_build_object(
               'ref', p_refs[1], 'monto', p_montos[1],
               'resultado', c.resultado, 'trans_id', c.trans_id, 'metodo', c.metodo)),
             NULL::numeric, NULL::numeric, NULL::numeric
        FROM cerebro_cruzar_deposito(p_deal, p_refs[1], p_montos[1],
                                     p_stage_ok, p_stage_incidencia,
                                     p_stage_esperado, p_simular) c;
    RETURN;
  END IF;

  IF v_n > 1 THEN
    IF COALESCE(array_length(p_montos, 1), 0) <> v_n THEN
      v_todos := false;
      v_fallo := 'las referencias y los importes no vienen emparejados';
    END IF;
    IF v_todos THEN
      SELECT count(DISTINCT regexp_replace(COALESCE(r, ''), '[^0-9]', '', 'g'))
        INTO v_refs_ok FROM unnest(p_refs) AS r;
      IF v_refs_ok <> v_n THEN
        v_todos := false;
        v_fallo := 'la misma referencia viene repetida dentro de la rafaga';
      END IF;
    END IF;
  END IF;

  IF v_todos THEN
    FOR v_i IN 1 .. GREATEST(v_n, 1) LOOP
      SELECT * INTO v_c
        FROM cerebro_cruzar_deposito(p_deal, p_refs[v_i], p_montos[v_i],
                                     p_stage_esperado, p_stage_esperado,
                                     p_stage_esperado, true);
      v_det := v_det || jsonb_build_object(
                 'ref', p_refs[v_i], 'monto', p_montos[v_i],
                 'resultado', v_c.resultado, 'trans_id', v_c.trans_id, 'metodo', v_c.metodo);
      IF v_c.resultado = 'verificado' THEN
        v_total := v_total + COALESCE(p_montos[v_i], 0);
        IF v_trans1 IS NULL THEN v_trans1 := v_c.trans_id; END IF;
        IF v_c.metodo = 'aproximado' THEN v_metodo := 'aproximado'; END IF;
      ELSE
        v_todos := false;
        IF v_fallo IS NULL THEN v_fallo := v_c.resultado; END IF;
      END IF;
    END LOOP;
  END IF;

  IF v_todos AND NOT p_simular THEN
    BEGIN
      v_det := '[]'::jsonb; v_total := 0; v_trans1 := NULL;
      FOR v_i IN 1 .. GREATEST(v_n, 1) LOOP
        SELECT * INTO v_c
          FROM cerebro_cruzar_deposito(p_deal, p_refs[v_i], p_montos[v_i],
                                       p_stage_esperado, p_stage_esperado,
                                       p_stage_esperado, false);
        v_det := v_det || jsonb_build_object(
                   'ref', p_refs[v_i], 'monto', p_montos[v_i],
                   'resultado', v_c.resultado, 'trans_id', v_c.trans_id, 'metodo', v_c.metodo);
        IF v_c.resultado <> 'verificado' THEN
          RAISE EXCEPTION 'cruce parcial: % en %', v_c.resultado, p_refs[v_i]
            USING ERRCODE = 'data_exception';
        END IF;
        v_total := v_total + COALESCE(p_montos[v_i], 0);
        IF v_trans1 IS NULL THEN v_trans1 := v_c.trans_id; END IF;
        IF v_c.metodo = 'aproximado' THEN v_metodo := 'aproximado'; END IF;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      v_todos := false; v_total := 0; v_trans1 := NULL;
      v_fallo := COALESCE(v_fallo, 'cruce parcial revertido: ' || SQLERRM);
    END;
  END IF;

  SELECT s.objetivo, s.depositado, s.saldo INTO v_obj, v_dep, v_saldo
    FROM cerebro_saldo_envio(p_deal) s;
  IF p_simular AND v_obj IS NOT NULL THEN
    v_dep := v_dep + CASE WHEN v_todos THEN v_total ELSE 0 END;
    v_saldo := v_obj - v_dep;
  END IF;

  v_stage_final := CASE
    WHEN NOT v_todos           THEN p_stage_incidencia
    WHEN v_saldo IS NULL       THEN p_stage_ok
    WHEN v_saldo > 0           THEN p_stage_esperado
    WHEN v_saldo < 0           THEN p_stage_incidencia
    ELSE                            p_stage_ok
  END;

  v_nota := CASE
    WHEN NOT v_todos THEN
      'SIN VERIFICAR - RAFAGA DE ' || v_n || ' COMPROBANTES QUE NO CUADRA ('
      || COALESCE(v_fallo, 'motivo desconocido') || ').'
      || ' NO se ha consumido NINGUNO de los ' || v_n || ' depositos: o cruzan todos'
      || ' o no cruza ninguno. Revisar a mano antes de transferir. Detalle: ' || v_det::text
    ELSE
      CASE WHEN v_n > 1 THEN
        'TOTAL VERIFICADO: ' || v_n || ' comprobantes de la misma rafaga suman '
        || rtrim(trim(to_char(v_total, 'FM999,999,999,990.99')), '.')
        || ' y los ' || v_n || ' casan con el libro de MMG.'
        || CASE WHEN v_metodo = 'aproximado'
                THEN ' OJO: alguno cruzo por COINCIDENCIA APROXIMADA - confirmar visualmente.'
                ELSE '' END
      ELSE '' END
      ||
      CASE
        WHEN v_saldo IS NULL THEN ''
        WHEN v_saldo > 0 THEN
          CASE WHEN v_n > 1 THEN chr(10) ELSE '' END
          || 'SALDO: lleva ' || rtrim(trim(to_char(v_dep,'FM999,999,999,990.99')),'.')
          || ' de ' || rtrim(trim(to_char(v_obj,'FM999,999,999,990.99')),'.')
          || ' ' || v_mon || ', FALTAN ' || rtrim(trim(to_char(v_saldo,'FM999,999,999,990.99')),'.')
          || '. El envio SIGUE ESPERANDO el resto y NO se transfiere todavia.'
        WHEN v_saldo < 0 THEN
          CASE WHEN v_n > 1 THEN chr(10) ELSE '' END
          || 'DEPOSITO DE MAS: el objetivo eran '
          || rtrim(trim(to_char(v_obj,'FM999,999,999,990.99')),'.')
          || ' ' || v_mon || ' y lleva depositados '
          || rtrim(trim(to_char(v_dep,'FM999,999,999,990.99')),'.')
          || ' — sobran ' || rtrim(trim(to_char(-v_saldo,'FM999,999,999,990.99')),'.')
          || '. NO hay politica para el dinero de mas: lo decide una persona.'
        ELSE
          CASE WHEN v_n > 1 THEN chr(10) ELSE '' END
          || 'OBJETIVO CUBIERTO: ' || rtrim(trim(to_char(v_dep,'FM999,999,999,990.99')),'.')
          || ' ' || v_mon || ' de ' || rtrim(trim(to_char(v_obj,'FM999,999,999,990.99')),'.')
          || '. El envio queda listo para transferir.'
      END
  END;

  IF NOT p_simular THEN
    UPDATE deals
       SET notes = COALESCE(notes, '') || CASE WHEN v_nota = '' THEN '' ELSE chr(10) || v_nota END,
           updated_at = now()
     WHERE id = p_deal;
    GET DIAGNOSTICS v_tocados = ROW_COUNT;
    -- (114) deals.stage_id is no longer written here.
    UPDATE remittance_operations
       SET status = cerebro_estado_desde_etapa(v_stage_final)
     WHERE deal_id = p_deal;
    IF v_todos AND v_saldo IS NOT NULL AND v_saldo = 0 THEN
      PERFORM cerebro_objetivo_cerrar(p_deal);
    END IF;
  ELSE
    v_tocados := 1;
  END IF;

  RETURN QUERY SELECT
    CASE WHEN NOT v_todos THEN COALESCE(v_fallo, 'sin_cruce')
         WHEN v_saldo IS NOT NULL AND v_saldo > 0 THEN 'verificado_incompleto'
         WHEN v_saldo IS NOT NULL AND v_saldo < 0 THEN 'verificado_de_mas'
         ELSE 'verificado' END,
    v_trans1, v_tocados, v_metodo, v_todos, v_total, v_n, v_det,
    v_obj, v_dep, v_saldo;
END;
$function$;
