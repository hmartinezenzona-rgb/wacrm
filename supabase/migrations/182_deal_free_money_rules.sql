-- =====================================================================
-- 182 — production's money rules on the deal-free path (STAGING ONLY for now)
--
-- Part of odd/tasks/align-staging-with-production.md (T2). Production received 168-180 directly
-- (deal path); staging carries the deal-free path (156-167). The two changed the same functions.
-- This migration puts production's rules on the deal-free bodies:
--   cerebro_registrar_deposito  = 167 (deal-free) + 170 (a remesa paid in parts is ONE operation:
--                                 the sum branch reads the operation status, the window, the service
--                                 minimum, and ADDS the deposit; 160 overwrote it) + 178 (a resent
--                                 receipt, same Ref, returns its operation).
--   cerebro_cruzar_depositos    = 167 + 178 (repeated Ref+amount in a burst is one receipt; a Ref
--                                 already consumed by this operation reports its state, no writes).
--   cerebro_objetivo_minimo, cerebro_cruzar_pendientes, cerebro_aplicar_cotizacion,
--   cerebro_recruzar_depositos_tardios = 170/171/173 keyed by OPERATION (receipts table, objetivo
--                                 operation_id); p_deal accepts a deal id or an operation id
--                                 (cerebro_resolve_op_id, 160), so the deal path keeps working.
-- crm_comprobantes_de_operacion and cerebro_cruzar_deposito need no merge: the staging bodies
-- (165, 167) already contain production's behaviour (177's can_verify by status; 144).
--
-- Guarded by supabase/staging/assertions/deal-free-money-rules.sql (RED on staging before: case 1,
-- the second deposit overwrote the amount, 10,000 instead of 13,000).
-- ROLLBACK: ROLLBACK-182-deal-free-money-rules.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_registrar_deposito(p_conv uuid, p_monto numeric, p_moneda text, p_stage uuid, p_nota text, p_comp_id text)
 RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
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
  v_motivo  text;
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
    v_motivo := 'REFERENCIA IMPOSIBLE: ese numero no puede ser un TransID de MMG. El contador '
      || 'solo crece y este queda por debajo de todos los recibidos, asi que casi seguro '
      || 'lo leyo la vision de una CAPTURA o de una foto de otra pantalla, no de un '
      || 'comprobante directo. NO se ha registrado como deposito normal: mire la imagen y '
      || 'pidale al cliente el comprobante original antes de dar nada por recibido.';
    -- v_nota keeps the caller's note plus the appended reason, byte for byte:
    -- cerebro_parsear_comprobantes still consumes it. The reason column is a
    -- separate variable (never v_nota) so the receipt code never leaks into it.
    v_nota := v_nota || chr(10) || v_motivo;
  END IF;

  -- (160) Idempotency: check remittance_operation_receipts.comp_id instead
  -- of deals.notes LIKE %comp_id%. The substring form is load-bearing:
  -- 156 matched `deals.notes LIKE '%'||p_comp_id||'%'`, and the note
  -- carries the receipt code as 'COMP-'||comp, while the caller passes
  -- the bare comp. An equality test alone therefore never matches on the
  -- real flow and silently returns 'creado', creating a second
  -- operation for a deposit that was already registered.
  IF NULLIF(p_comp_id,'') IS NOT NULL THEN
    SELECT ro.id INTO v_ya
      FROM remittance_operations ro
      JOIN remittance_operation_receipts r ON r.operation_id = ro.id
     WHERE ro.conversation_id = p_conv
       AND (r.comp_id = p_comp_id OR r.comp_id LIKE '%'||p_comp_id||'%')
     LIMIT 1;
    IF v_ya IS NOT NULL THEN
      RETURN QUERY SELECT v_ya, 'ya registrado (idempotente)'::text, v_rev, false; RETURN;
    END IF;
  END IF;

  -- (182 <- 178) The same receipt sent again (another image, another COMP id): its Ref is already
  -- a receipt of an open operation of this chat. It is that deposit, not a new one: never summed,
  -- never a second operation.
  v_ref := NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '');
  IF v_ref IS NOT NULL THEN
    SELECT ro.id INTO v_ya
      FROM remittance_operations ro
      JOIN remittance_operation_receipts r ON r.operation_id = ro.id
     WHERE ro.conversation_id = p_conv
       AND ro.status NOT IN ('completed', 'cancelled')
       AND r.reference ~ ('(^|[^0-9])' || v_ref || '([^0-9]|$)')
     ORDER BY ro.created_at DESC LIMIT 1;
    IF v_ya IS NOT NULL THEN
      RETURN QUERY SELECT v_ya, 'ya registrado (misma referencia)'::text, v_rev, false; RETURN;
    END IF;
  END IF;

  -- (160) movido branch: find the latest open remesa operation for this
  -- conversation that has no receipt yet, and is NOT (has vigente
  -- beneficiary AND positive saldo). The beneficiary+money conjunction
  -- is the exact structured equivalent of 156's `NOT (d.value > 0 AND
  -- COALESCE(d.notes,'') LIKE '%BENEFICIARIO%')`. An operation with a
  -- beneficiary but zero saldo is still the movido target.
  IF NOT v_rev THEN
    SELECT ro.id INTO v_ex
      FROM remittance_operations ro
     WHERE ro.conversation_id = p_conv
       AND ro.status NOT IN ('completed','cancelled')
       AND ro.service_type = 'remesa'
       AND NOT EXISTS (
         SELECT 1 FROM remittance_operation_receipts r
          WHERE r.operation_id = ro.id AND r.comp_id IS NOT NULL)
       AND NOT (
         (EXISTS (
           SELECT 1 FROM remittance_beneficiaries b
            WHERE b.operation_id = ro.id AND b.status = 'vigente'))
         -- COALESCE is load-bearing: cerebro_saldo_operacion returns NULL
         -- when the operation has no open objetivo, and `TRUE AND NULL`
         -- evaluates to NULL, which excludes the row and pushes a
         -- beneficiary-first operation into 'creado' (a phantom second
         -- remesa). 156's equivalent could never be NULL (deals.value is
         -- NOT NULL, notes is COALESCEd), so the guard must stay
         -- two-valued here too.
         AND (COALESCE((SELECT s.saldo FROM cerebro_saldo_operacion(ro.id) s), 0) > 0))
     ORDER BY ro.created_at DESC LIMIT 1;
  END IF;

  -- (182 <- 170) The open WAITING remesa this deposit completes: a remesa of this chat still
  -- being verified or in incident, opened in the window, with a receipt already, that is below
  -- its service minimum, still owes saldo, or this deposit alone is below the smallest minimum.
  -- A remesa that is ready to transfer is never touched. (160's version only took
  -- deposit_verification with saldo > 0 and then OVERWROTE the amount with this deposit.)
  IF NOT v_rev AND v_ex IS NULL THEN
    SELECT ro.id INTO v_suma
      FROM remittance_operations ro
     WHERE ro.conversation_id = p_conv
       AND ro.service_type = 'remesa'
       AND ro.status IN ('deposit_verification', 'incident')
       AND ro.created_at > now() - make_interval(hours => v_ventana)
       AND EXISTS (SELECT 1 FROM remittance_operation_receipts r WHERE r.operation_id = ro.id)  -- it has a deposit (170: notes LIKE '%DEPOSITO%')
       AND COALESCE(ro.incident_reason, '') NOT LIKE 'REFERENCIA IMPOSIBLE%'
       AND (COALESCE((SELECT s.saldo FROM cerebro_saldo_operacion(ro.id) s), 0) > 0
            OR ro.quoted_source_amount < cerebro_minimo_gyd(ro.id)
            OR p_monto < v_min_cup)
     ORDER BY ro.created_at DESC LIMIT 1;
  END IF;

  -- (160) Recarga 24 h window: use the latest CLOSED operation for this
  -- conversation instead of the max(deals.updated_at) with status <>
  -- 'open' OR stage = '1b36b34c'.
  IF NOT v_rev THEN
    SELECT EXISTS (
             SELECT 1 FROM messages m
              WHERE m.conversation_id = p_conv
                AND m.sender_type = 'customer'
                AND m.created_at > GREATEST(
                      now() - interval '24 hours',
                      COALESCE((SELECT max(op.updated_at) FROM remittance_operations op
                                 WHERE op.conversation_id = p_conv
                                   AND op.status IN ('completed','cancelled')),
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

  -- (160) movido branch: update the found op directly.
  IF v_ex IS NOT NULL THEN
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           incident_reason = CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident'
                                  THEN v_motivo ELSE NULL END,
           quoted_source_amount = p_monto,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.id = v_ex;
    PERFORM cerebro_objetivo_atar_op(p_conv, v_ex);
    -- (182 <- 170) Below the minimum of its service: wait for the rest.
    PERFORM cerebro_objetivo_minimo(p_conv, v_ex);
    -- (156) dual-write: insert parsed receipts for this operation.
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.id = v_ex
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    RETURN QUERY SELECT v_ex, 'movido'::text, false, false; RETURN;
  END IF;

  -- (160) sumado branch: update the found op directly.
  IF v_suma IS NOT NULL THEN
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           incident_reason = CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident'
                                  THEN v_motivo ELSE NULL END,
           quoted_source_amount = ro.quoted_source_amount + p_monto,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.id = v_suma;
    PERFORM cerebro_objetivo_atar_op(p_conv, v_suma);
    -- (182 <- 170) The objetivo covers the whole remesa.
    PERFORM cerebro_objetivo_minimo(p_conv, v_suma, true);
    -- (156) dual-write.
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.id = v_suma
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    -- (182 <- 170) The earlier receipts of the remesa that were never crossed are crossed now;
    -- this one is crossed by the Cerebro's own node right after this call.
    PERFORM cerebro_cruzar_pendientes(v_suma, v_ref);
    RETURN QUERY SELECT v_suma, 'sumado al envio abierto'::text, false, true; RETURN;
  END IF;

  -- (160) creado branch: INSERT remittance_operations directly, no deal.
  INSERT INTO remittance_operations (
    account_id, conversation_id, contact_id, deal_id, status,
    service_type, quoted_source_amount, source_currency, created_at,
    completed_at, cancelled_at, incident_reason
  )
  VALUES (
    (SELECT account_id FROM conversations WHERE id = p_conv),
    p_conv, v_contact, NULL,   -- deal_id = NULL (the whole point)
    cerebro_estado_desde_etapa(p_stage),
    CASE WHEN v_rev THEN 'remesa' WHEN v_recarga THEN 'recarga' ELSE 'remesa' END,
    p_monto, coalesce(p_moneda, 'GYD'), now(),
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'completed' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'cancelled' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident' THEN v_motivo ELSE NULL END
  )
  RETURNING id INTO v_id;

  IF NOT v_rev THEN PERFORM cerebro_objetivo_atar_op(p_conv, v_id); END IF;

  -- (156) dual-write: parse and insert receipts linked to this new op.
  INSERT INTO public.remittance_operation_receipts (
    operation_id, conversation_id, comp_id, amount, currency, receipt_status,
    recipient, via, reference, receipt_date, correct_destination, source)
  SELECT v_id, p_conv, p.comp_id, p.amount, p.currency, p.receipt_status,
         p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
    FROM cerebro_parsear_comprobantes(v_nota) p
  ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;

  -- (182 <- 170) Below the minimum of its service: wait for the rest.
  IF NOT v_rev THEN PERFORM cerebro_objetivo_minimo(p_conv, v_id); END IF;

  -- (160) OUT column keeps its name 'deal_id' but now carries the
  -- operation id. Callers (n8n node) pass it back to
  -- cerebro_cruzar_deposito which now calls cerebro_resolve_op_id.
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
  v_op_id uuid;
BEGIN
  -- (160) Resolve either flavour.
  v_op_id := cerebro_resolve_op_id(p_deal);

  -- (182 <- 178) The same receipt twice in one burst (same Ref, same amount) is ONE receipt.
  IF COALESCE(array_length(p_refs, 1), 0) > 1
     AND COALESCE(array_length(p_montos, 1), 0) = array_length(p_refs, 1) THEN
    SELECT array_agg(x.r ORDER BY x.i), array_agg(x.m ORDER BY x.i)
      INTO p_refs, p_montos
      FROM (SELECT DISTINCT ON (regexp_replace(COALESCE(t.r, ''), '[^0-9]', '', 'g'), t.m) t.r, t.m, t.i
              FROM unnest(p_refs, p_montos) WITH ORDINALITY AS t(r, m, i)
             ORDER BY regexp_replace(COALESCE(t.r, ''), '[^0-9]', '', 'g'), t.m, t.i) x;
  END IF;
  v_n := COALESCE(array_length(p_refs, 1), 0);

  -- (182 <- 178) Every Ref already consumed by THIS operation (a resent receipt): report where it
  -- stands and write nothing.
  IF v_n >= 1 AND v_op_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM unnest(p_refs) AS r
        WHERE NOT EXISTS (SELECT 1 FROM depositos_mmg x
                           WHERE x.trans_id = regexp_replace(COALESCE(r, ''), '[^0-9]', '', 'g')
                             AND x.operation_id = v_op_id AND x.consumido_en IS NOT NULL)) THEN
    SELECT s.objetivo, s.depositado, s.saldo INTO v_obj, v_dep, v_saldo FROM cerebro_saldo_operacion(v_op_id) s;
    SELECT COALESCE(sum(m), 0) INTO v_total FROM unnest(p_montos) AS m;
    SELECT jsonb_agg(jsonb_build_object('ref', t.r, 'monto', t.m, 'resultado', 'verificado',
                                        'trans_id', regexp_replace(COALESCE(t.r, ''), '[^0-9]', '', 'g'),
                                        'metodo', 'repetido') ORDER BY t.i)
      INTO v_det FROM unnest(p_refs, p_montos) WITH ORDINALITY AS t(r, m, i);
    RETURN QUERY SELECT
      CASE WHEN v_saldo IS NOT NULL AND v_saldo > 0 THEN 'verificado_incompleto'
           WHEN v_saldo IS NOT NULL AND v_saldo < 0 THEN 'verificado_de_mas'
           ELSE 'verificado' END,
      regexp_replace(COALESCE(p_refs[1], ''), '[^0-9]', '', 'g'), 0, 'repetido'::text, true,
      v_total, v_n, v_det, v_obj, v_dep, v_saldo;
    RETURN;
  END IF;

  SELECT s.objetivo, s.moneda INTO v_obj, v_mon FROM cerebro_saldo_operacion(v_op_id) s;

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
        FROM cerebro_cruzar_deposito(v_op_id, p_refs[1], p_montos[1],
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
        FROM cerebro_cruzar_deposito(v_op_id, p_refs[v_i], p_montos[v_i],
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
          FROM cerebro_cruzar_deposito(v_op_id, p_refs[v_i], p_montos[v_i],
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
    FROM cerebro_saldo_operacion(v_op_id) s;
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

  IF NOT p_simular THEN
    -- (160) Write status directly on the operation; no deals touch.
    UPDATE remittance_operations
       SET status = cerebro_estado_desde_etapa(v_stage_final),
           incident_reason = CASE WHEN cerebro_estado_desde_etapa(v_stage_final) = 'incident'
                                  THEN v_fallo ELSE NULL END,
           updated_at = now()
     WHERE id = v_op_id;
    GET DIAGNOSTICS v_tocados = ROW_COUNT;
    IF v_todos AND v_saldo IS NOT NULL AND v_saldo = 0 THEN
      PERFORM cerebro_objetivo_cerrar_op(v_op_id);
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

-- (182 <- 173) objetivo keyed by OPERATION: p_deal accepts a deal id OR an operation id
-- (cerebro_resolve_op_id, 160), so the deal path and the deal-free path share one body.
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_minimo(p_conv uuid, p_deal uuid, p_siempre boolean DEFAULT false)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op     uuid := cerebro_resolve_op_id(p_deal);
  v_deal   uuid;
  v_tot    numeric;
  v_min    numeric;
  v_cot    numeric;
  v_prev   numeric;
  v_meta   numeric;
  v_pedido text;
  v_obj    numeric;
  v_hay    boolean;
BEGIN
  SELECT o.deal_id, o.quoted_source_amount INTO v_deal, v_tot FROM remittance_operations o WHERE o.id = v_op;
  IF v_op IS NULL OR NOT FOUND THEN RETURN NULL; END IF;
  v_min  := cerebro_minimo_gyd(v_op);
  v_cot  := cerebro_cotizacion_vigente(p_conv);
  v_prev := (SELECT x.monto FROM cerebro_objetivo_envio x WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL);
  v_meta := greatest(v_min, COALESCE(v_cot, v_prev, 0));
  v_pedido := CASE
    WHEN v_cot IS NOT NULL AND v_cot >= v_min THEN 'cotizacion'
    WHEN v_cot IS NULL AND v_prev IS NOT NULL AND v_prev > v_min THEN NULL
    ELSE 'minimo ' || CASE cerebro_riel_op(v_op)
                        WHEN 'zelle' THEN 'Zelle'
                        WHEN 'clasica' THEN 'Clásica'
                        WHEN 'tropical' THEN 'Tropical'
                        WHEN 'efectivo_usd' THEN 'efectivo en USD'
                        WHEN 'recarga' THEN 'recarga'
                        ELSE 'tarjeta CUP' END
  END;
  -- Another operation of this conversation is already waiting on its own objetivo: leave it alone.
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio x
              WHERE x.conversation_id = p_conv AND x.cerrado_en IS NULL
                AND x.operation_id IS NOT NULL AND x.operation_id <> v_op) THEN
    RETURN NULL;
  END IF;
  v_hay := v_prev IS NOT NULL;
  IF v_tot >= v_meta AND NOT p_siempre AND NOT v_hay THEN RETURN NULL; END IF;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en, deal_id, cerrado_en, pedido, operation_id)
  VALUES (p_conv, greatest(v_meta, CASE WHEN p_siempre THEN v_tot ELSE 0 END), 'GYD', now(), v_deal, NULL,
          COALESCE(v_pedido, 'objetivo del envio'), v_op)
  ON CONFLICT (conversation_id) DO UPDATE SET
    monto        = EXCLUDED.monto,
    moneda       = 'GYD',
    deal_id      = v_deal,
    operation_id = v_op,
    pedido       = COALESCE(v_pedido, cerebro_objetivo_envio.pedido),
    fijado_en    = CASE WHEN cerebro_objetivo_envio.cerrado_en IS NULL THEN cerebro_objetivo_envio.fijado_en ELSE now() END,
    cerrado_en   = NULL
  RETURNING monto INTO v_obj;
  RETURN v_obj;
END $$;

-- (182 <- 170) The receipts of an operation come from remittance_operation_receipts (156), not
-- from deals.notes. p_deal accepts a deal id or an operation id.
CREATE OR REPLACE FUNCTION public.cerebro_cruzar_pendientes(p_deal uuid, p_excepto text DEFAULT NULL)
RETURNS TABLE(resultado text, trans_id text, n_refs integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c_ok       CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  c_esperado CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_op    uuid := cerebro_resolve_op_id(p_deal);
  v_refs  text[];
  v_mont  numeric[];
  v_sim   record;
  v_real  record;
BEGIN
  SELECT array_agg(b.ref ORDER BY b.ord1, b.ord2), array_agg(b.monto ORDER BY b.ord1, b.ord2)
    INTO v_refs, v_mont
    FROM (SELECT DISTINCT ON ((regexp_match(r.reference, '([0-9]{8,})'))[1])
                 (regexp_match(r.reference, '([0-9]{8,})'))[1] AS ref, r.amount AS monto,
                 COALESCE(r.block_index, 0) AS ord1, r.created_at AS ord2
            FROM remittance_operation_receipts r
           WHERE r.operation_id = v_op AND r.amount IS NOT NULL
           ORDER BY (regexp_match(r.reference, '([0-9]{8,})'))[1], r.created_at) b
   WHERE b.ref IS NOT NULL
     AND b.ref IS DISTINCT FROM p_excepto
     AND EXISTS (SELECT 1 FROM depositos_mmg m
                  WHERE m.trans_id = b.ref AND m.consumido_en IS NULL AND m.anulado_en IS NULL);

  IF v_refs IS NULL THEN RETURN; END IF;

  SELECT * INTO v_sim FROM cerebro_cruzar_depositos(v_op, v_refs, v_mont, c_ok, c_esperado, c_esperado, true);
  IF v_sim.resultado NOT IN ('verificado', 'verificado_incompleto') THEN
    RETURN QUERY SELECT v_sim.resultado, NULL::text, cardinality(v_refs); RETURN;
  END IF;
  SELECT * INTO v_real FROM cerebro_cruzar_depositos(v_op, v_refs, v_mont, c_ok, c_esperado, c_esperado, false);
  RETURN QUERY SELECT v_real.resultado, v_real.trans_id, cardinality(v_refs);
END $$;

-- (182 <- 171) A new quote re-targets the waiting remesas of the conversation, by operation.
CREATE OR REPLACE FUNCTION public.cerebro_aplicar_cotizacion(p_conv uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op   record;
  v_sal  record;
  v_n    integer := 0;
BEGIN
  FOR v_op IN
    SELECT o.id, o.account_id
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv
       AND o.service_type = 'remesa'
       AND o.status = 'deposit_verification'
       AND o.created_at > now() - make_interval(hours => COALESCE(NULLIF(cerebro_config_get('completar_ventana_horas'), '')::int, 6))
     FOR UPDATE OF o SKIP LOCKED
  LOOP
    PERFORM cerebro_objetivo_minimo(p_conv, v_op.id);
    PERFORM cerebro_cruzar_pendientes(v_op.id);
    SELECT * INTO v_sal FROM cerebro_saldo_operacion(v_op.id);
    IF (SELECT status FROM remittance_operations WHERE id = v_op.id) = 'deposit_verification'
       AND v_sal.objetivo IS NOT NULL AND v_sal.depositado > 0 AND v_sal.saldo <= 0
       AND NOT EXISTS (SELECT 1 FROM depositos_mmg m JOIN remittance_operation_receipts r
                         ON r.operation_id = v_op.id AND r.reference ~ ('(^|[^0-9])' || m.trans_id || '([^0-9]|$)')
                        WHERE m.consumido_en IS NULL AND m.anulado_en IS NULL) THEN
      UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op.id;
      PERFORM cerebro_objetivo_cerrar_op(v_op.id);
    END IF;
    IF (SELECT status FROM remittance_operations WHERE id = v_op.id) = 'ready_to_transfer' THEN
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
      VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'status', 'automation_late_deposit_verification', NULL,
              'The customer''s new quote is covered by the verified deposits (171).',
              jsonb_build_object('status', 'deposit_verification'),
              jsonb_build_object('status', 'ready_to_transfer', 'objetivo', v_sal.objetivo, 'depositado', v_sal.depositado));
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

-- (182 <- 168/170) The late MMG email re-cross, by operation and receipts.
CREATE OR REPLACE FUNCTION public.cerebro_recruzar_depositos_tardios()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op  record;
  v_res record;
  v_n   integer := 0;
BEGIN
  FOR v_op IN
    SELECT o.id, o.account_id
      FROM remittance_operations o
     WHERE o.status = 'deposit_verification'
       AND o.service_type = 'remesa'
       AND o.created_at > now() - interval '24 hours'
       AND o.updated_at < now() - interval '90 seconds'
       AND EXISTS (SELECT 1 FROM depositos_mmg m JOIN remittance_operation_receipts r
                     ON r.operation_id = o.id AND r.reference ~ ('(^|[^0-9])' || m.trans_id || '([^0-9]|$)')
                    WHERE m.consumido_en IS NULL AND m.anulado_en IS NULL)
     FOR UPDATE OF o SKIP LOCKED
  LOOP
    SELECT * INTO v_res FROM cerebro_cruzar_pendientes(v_op.id);
    CONTINUE WHEN v_res.resultado IS DISTINCT FROM 'verificado';

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'status', 'automation_late_deposit_verification', NULL,
            'MMG email ingested after the receipt was processed; re-crossed by cerebro_recruzar_depositos_tardios.',
            jsonb_build_object('status', 'deposit_verification'),
            jsonb_build_object('resultado', v_res.resultado, 'trans_id', v_res.trans_id, 'n_refs', v_res.n_refs,
                               'status', (SELECT status FROM remittance_operations WHERE id = v_op.id)));
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
