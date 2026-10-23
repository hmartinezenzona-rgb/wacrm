-- ROLLBACK 291: back to the 280 bodies of cerebro_registrar_deposito and cerebro_repartir_envio.
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
  v_combo   boolean := false;
  v_visa    boolean := false;
  v_mexico  boolean := false;
  v_open_m  boolean := false;
  v_open_r  boolean := false;
  v_open_c  boolean := false;
  v_open_v  boolean := false;
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
  v_res     jsonb;
  v_dest    uuid;
  v_accion  text;
BEGIN
  -- (267) One writer at a time per conversation: the same lock cerebro_aplicar_servicio (266) takes (re-entrant).
  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_servicio:' || p_conv::text, 0));
  v_rev := cerebro_es_revendedor(p_conv);
  -- (202, 209, 213, 267) Which kind of operation this deposit belongs to (at most one flag is true; none = a remesa).
  -- (267) The service comes from facts, never from the customer's words: cerebro_resolver_servicio (265) gives the service
  -- of the operation this deposit joins or creates (the open operation that holds the money, else the declared intent,
  -- else Q1, else remesa). A reseller's deposit is always a remesa. A resolver error keeps the remesa fallback.
  IF NOT v_rev THEN
    v_res    := cerebro_resolver_servicio(p_conv, NULL::text, NULL::text, p_monto);
    v_dest   := nullif(v_res ->> 'destino_operacion', '')::uuid;
    v_accion := v_res ->> 'accion';
    IF COALESCE(v_res ->> 'motivo', '') = 'error' THEN
      NULL;  -- fail open: remesa, all three flags stay false
    ELSIF v_res ->> 'servicio' IS NOT NULL THEN
      v_recarga := (v_res ->> 'servicio') = 'recarga';
      v_combo   := (v_res ->> 'servicio') = 'combo';
      v_visa    := (v_res ->> 'servicio') = 'visa';
      v_mexico  := (v_res ->> 'servicio') = 'mexico';
    ELSE
      -- No service decided (several open operations and no deposit): the open operation keeps winning, in the live order
      -- recarga > combo > visa. No words are read; with nothing open the deposit is a remesa.
      v_open_r := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_c := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_v := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'visa' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_m := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'mexico' AND o.status NOT IN ('completed', 'cancelled'));
      v_recarga := v_open_r;
      v_combo   := v_open_c AND NOT v_open_r;
      v_visa    := v_open_v AND NOT v_open_r AND NOT v_open_c;
      v_mexico  := v_open_m AND NOT v_open_r AND NOT v_open_c AND NOT v_open_v;
    END IF;
  END IF;

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

  -- (160, 232) movido branch: find the latest open remesa operation for this conversation that has no receipt yet,
  -- and is NOT (has a vigente recipient AND still owes saldo AND already holds money).
  -- 156's guard was `NOT (d.value > 0 AND notes LIKE '%BENEFICIARIO%')`: value is money ALREADY deposited, so a deal with
  -- money and a recipient was a complete remittance and a new deposit was a different one. 160 translated "money
  -- already there" into `saldo > 0` (money still OWED), which for a recipient-first operation (nothing deposited, the
  -- whole quote owed) excluded exactly the operation the deposit belongs to (Edel, 2026-10-08).
  -- (232) The guard now needs the operation to hold money. It holds money when quoted_source_amount > 0, or any receipt
  -- row hangs from it, or something was consumed against it (the `depositado` of cerebro_saldo_operacion). An operation
  -- in incident or with a locked quoted_source_amount keeps the 160 behaviour: the deposit amount would be overwritten
  -- over a decision someone made, or suppressed by the lock.
  IF NOT v_rev THEN
    SELECT ro.id INTO v_ex
      FROM remittance_operations ro
     WHERE ro.conversation_id = p_conv
       AND ro.status NOT IN ('completed','cancelled')
       -- (202) or the recharge the customer's numbers opened
       -- (209) or the combo the customer is ordering
       AND (ro.service_type = 'remesa' OR (v_recarga AND ro.service_type = 'recarga')
            OR (v_combo AND ro.service_type = 'combo')
            -- (213) or the visa the customer is paying for
            OR (v_visa AND ro.service_type = 'visa')
            -- (273) or the Mexico send the customer is paying for
            OR (v_mexico AND ro.service_type = 'mexico'))
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
         AND (COALESCE((SELECT s.saldo FROM cerebro_saldo_operacion(ro.id) s), 0) > 0)
         -- (232) ... and only when the operation already holds money (or is not safe to overwrite).
         AND (COALESCE(ro.quoted_source_amount, 0) > 0
              OR EXISTS (SELECT 1 FROM remittance_operation_receipts r2 WHERE r2.operation_id = ro.id)
              OR COALESCE((SELECT s.depositado FROM cerebro_saldo_operacion(ro.id) s), 0) > 0
              OR ro.status = 'incident'
              OR COALESCE(ro.admin_locked_fields, '{}'::jsonb) ? 'quoted_source_amount'))
     -- (267) the operation the resolver names (destino_operacion) first, when it is still open and eligible above
     -- (280) an operation outside a group comes before a group member (after a partial application the next deposit belongs to the pending
     -- part, never to a member of a group that is already covered and locked); with a plan waiting, the part the customer listed first
     -- takes the deposit; ties are broken by id so the choice is deterministic.
     ORDER BY (ro.id = v_dest) DESC NULLS LAST, (ro.mixed_group_id IS NULL) DESC,
              coalesce((SELECT pl.partes -> 0 ->> 'servicio' = cerebro_riel_op(ro.id) FROM cerebro_reparto_planeado pl
                         WHERE pl.conversation_id = ro.conversation_id), false) DESC,
              ro.created_at DESC, ro.id LIMIT 1;
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

  -- (160) Recarga 24 h window: now decided up front by the resolver (267).

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
    -- (156) dual-write: insert parsed receipts for this operation (before the conversion: the resolver reads them).
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.id = v_ex
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    -- (267) the resolver said convert: the deposit is attached, so the service is decided again and converted here
    IF v_accion = 'convertir' THEN
      PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
    END IF;
    PERFORM cerebro_objetivo_atar_op(p_conv, v_ex);
    -- (182 <- 170) Below the minimum of its service: wait for the rest.
    PERFORM cerebro_objetivo_minimo(p_conv, v_ex);
    -- (202) a recharge takes any number typed since (no repeats)
    IF (SELECT service_type FROM remittance_operations WHERE id = v_ex) = 'recarga' THEN
      PERFORM crm_registrar_numeros_recarga(p_conv, cerebro_textos_cliente_recientes(p_conv));
    END IF;
    -- (277) a split planned before the deposit is applied when this deposit is exactly its total
    PERFORM _cerebro_aplicar_plan_reparto(p_conv, v_ex);
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
    -- (156) dual-write (before the conversion: the resolver reads the receipts).
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.id = v_suma
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    -- (267) the resolver said convert: the deposit is attached, so the service is decided again and converted here
    IF v_accion = 'convertir' THEN
      PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
    END IF;
    PERFORM cerebro_objetivo_atar_op(p_conv, v_suma);
    -- (182 <- 170) The objetivo covers the whole remesa.
    PERFORM cerebro_objetivo_minimo(p_conv, v_suma, true);
    -- (182 <- 170) The earlier receipts of the remesa that were never crossed are crossed now;
    -- this one is crossed by the Cerebro's own node right after this call.
    PERFORM cerebro_cruzar_pendientes(v_suma, v_ref);
    PERFORM _cerebro_aplicar_plan_reparto(p_conv, v_suma);
    RETURN QUERY SELECT v_suma, 'sumado al envio abierto'::text, false, true; RETURN;
  END IF;

  -- (160) creado branch: INSERT remittance_operations directly, no deal.
  INSERT INTO remittance_operations (
    account_id, conversation_id, contact_id, deal_id, status,
    service_type, quoted_source_amount, source_currency, destination_currency, created_at,
    completed_at, cancelled_at, incident_reason
  )
  VALUES (
    (SELECT account_id FROM conversations WHERE id = p_conv),
    p_conv, v_contact, NULL,   -- deal_id = NULL (the whole point)
    cerebro_estado_desde_etapa(p_stage),
    CASE WHEN v_rev THEN 'remesa' WHEN v_combo THEN 'combo' WHEN v_visa THEN 'visa' WHEN v_mexico THEN 'mexico' WHEN v_recarga THEN 'recarga' ELSE 'remesa' END,
    p_monto, coalesce(p_moneda, 'GYD'), CASE WHEN v_mexico AND NOT v_rev THEN 'MXN' END, now(),
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'completed' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'cancelled' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident' THEN v_motivo ELSE NULL END
  )
  RETURNING id INTO v_id;

  -- (267) the resolver said convert: the deposit is attached to v_id, so the service is decided again and converted here
  IF v_accion = 'convertir' AND NOT v_rev THEN
    PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
  END IF;

  IF NOT v_rev THEN PERFORM cerebro_objetivo_atar_op(p_conv, v_id); END IF;

  -- (201) A new recharge takes the Cuban numbers the customer TYPED since asking for it (same window as v_recarga).
  IF v_recarga AND NOT v_rev THEN
    PERFORM crm_registrar_numeros_recarga(p_conv, cerebro_textos_cliente_recientes(p_conv));
  END IF;

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
  IF NOT v_rev THEN PERFORM _cerebro_aplicar_plan_reparto(p_conv, v_id); END IF;
  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_repartir_envio(p_conv uuid, p_partes text, p_execution text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_actor       constant text := 'automation:cerebro_repartir_envio';
  v_parse       jsonb;
  v_op          uuid;
  v_res         jsonb;
  v_text        text;
  v_outcome     text;
  v_prev_origin text;
  v_prev_actor  text;
  v_p           jsonb;
  v_o           remittance_operations%ROWTYPE;
  v_lista       text[] := ARRAY[]::text[];
  v_dep         numeric;
  v_saldo       numeric;
  v_motivo      text;
  v_a           text;
  v_b           text;
  v_plan        jsonb;
  v_dverif      numeric;
  v_totop       numeric;
  v_sum         numeric;
  v_parcial     boolean := false;
  v_npartes     int;
  v_pl          cerebro_reparto_planeado%ROWTYPE;
  v_pend        jsonb := '[]'::jsonb;
  v_pend_txt    text;
  v_pend_tot    numeric := 0;
  v_e           jsonb;
BEGIN
  v_parse := _cerebro_partes_envio_parse(p_partes);

  IF NOT (v_parse ->> 'ok')::boolean THEN
    v_outcome := 'no_entendido';
    v_text := CASE WHEN v_parse ->> 'segmento' = '' THEN 'No entendi el reparto: no vi ninguna parte.'
                   ELSE 'No entendi esta parte: "' || (v_parse ->> 'segmento') || '".' END
              || ' Indica cada parte con servicio y monto en GYD, por ejemplo: "clasica 18200, recarga 6200".';
  ELSE
    -- One splitter at a time per conversation.
    PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_repartir_envio:' || p_conv::text, 0));

    -- The operation holding the deposit: grouped first, then deposit/receipt holder, newest first; else the newest with an amount.
    SELECT o.id INTO v_op
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv
       AND o.status NOT IN ('completed', 'cancelled')
       AND (o.mixed_group_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL)
            OR EXISTS (SELECT 1 FROM remittance_operation_receipts rr WHERE rr.operation_id = o.id)
            OR coalesce(o.quoted_source_amount, 0) > 0)
     ORDER BY -- (280) with a plan waiting, the operation whose amount is the plan's total holds the deposit being split
              coalesce((SELECT o.quoted_source_amount = pl.total_gyd FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = o.conversation_id), false) DESC,
              -- (280) a group already fully covered (a partial application) is not the holder of the next deposit
              (o.mixed_group_id IS NOT NULL
               AND coalesce((SELECT s.depositado > 0 AND s.saldo <= 0 FROM cerebro_saldo_operacion(o.id) s), false)) ASC,
              (o.mixed_group_id IS NOT NULL) DESC,
              (EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL)
               OR EXISTS (SELECT 1 FROM remittance_operation_receipts rr WHERE rr.operation_id = o.id)) DESC,
              o.created_at DESC
     LIMIT 1;

    IF v_op IS NULL THEN
      -- (277) No deposit yet: the split is PLANNED (parts persisted, one empty operation per part) and applied when a deposit of
      -- exactly the planned total arrives (cerebro_registrar_deposito).
      v_plan := _cerebro_reparto_planear(p_conv, v_parse -> 'partes', true, 'agent:repartir_envio');
      v_outcome := CASE WHEN (v_plan ->> 'ok')::boolean THEN 'planeado' ELSE 'rechazado' END;
      v_text := v_plan ->> 'texto';
    ELSE
      -- (280) Partial deposit: when the parts do not add up to the operation's total but fit inside the verified deposit, the bot is
      -- applying only what is covered now. The rest of the plan stays pending (own empty operation, own data) for the next deposit.
      SELECT s.depositado INTO v_dverif FROM cerebro_saldo_operacion(v_op) s;
      SELECT sum((e ->> 'monto_gyd')::numeric), count(*) INTO v_sum, v_npartes FROM jsonb_array_elements(v_parse -> 'partes') e;
      SELECT CASE WHEN o.mixed_group_id IS NOT NULL
                  THEN (SELECT sum(x.quoted_source_amount) FROM remittance_operations x WHERE x.mixed_group_id = o.mixed_group_id AND x.status <> 'cancelled')
                  ELSE o.quoted_source_amount END
        INTO v_totop FROM remittance_operations o WHERE o.id = v_op;
      v_parcial := coalesce(v_dverif, 0) > 0 AND (v_sum IS DISTINCT FROM v_totop OR v_npartes = 1) AND v_sum <= v_dverif;
      IF v_parcial AND v_npartes = 1 THEN
        -- a single part only makes sense when the plan still has other parts waiting
        SELECT * INTO v_pl FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
        IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_pl.partes) e
                                     WHERE e ->> 'servicio' <> (v_parse -> 'partes' -> 0 ->> 'servicio')) THEN
          v_parcial := false;
        END IF;
      END IF;

      v_prev_origin := coalesce(current_setting('wacrm.origin', true), '');
      v_prev_actor  := coalesce(current_setting('wacrm.actor', true), '');
      BEGIN
        PERFORM set_config('wacrm.origin', 'admin', true);
        PERFORM set_config('wacrm.actor', c_actor, true);
        v_res := _repartir_envio_core(v_op, v_parse -> 'partes', 'automation_mixed_split', c_actor,
                                      'n8n execution ' || coalesce(nullif(btrim(p_execution), ''), 'unknown'), v_parcial);
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
      EXCEPTION
        WHEN SQLSTATE '22023' THEN
          PERFORM set_config('wacrm.origin', v_prev_origin, true);
          PERFORM set_config('wacrm.actor', v_prev_actor, true);
          v_outcome := 'rechazado';
          IF SQLERRM LIKE 'part % is below its minimum of %' THEN
            v_a := substring(SQLERRM from '^part ([a-z_]+) ');
            v_text := 'REPARTO NO APLICADO: la parte ' || CASE v_a WHEN 'cuban_card' THEN 'tarjeta CUP' WHEN 'efectivo_usd' THEN 'efectivo USD' ELSE v_a END
                      || ' (' || _cerebro_fmt_monto(substring(SQLERRM from '\(([0-9.]+)\)')::numeric) || ' GYD) esta por debajo de su minimo ('
                      || _cerebro_fmt_monto(substring(SQLERRM from 'minimum of ([0-9.]+)$')::numeric) || ' GYD). No se cambio nada. '
                      || 'Preguntale al cliente si sube esa parte o la deja fuera del reparto.';
          ELSIF SQLERRM LIKE 'the parts add up to % but the total to split is %' THEN
            v_a := substring(SQLERRM from 'add up to ([0-9.]+) but');
            v_b := substring(SQLERRM from 'total to split is ([0-9.]+)$');
            -- (277) Facts instead of a bare refusal: the plan is kept and the answer carries what the Decisor needs.
            -- (280) an existing plan is never overwritten by a refused attempt (the bot may have sent only some of its parts)
            IF NOT EXISTS (SELECT 1 FROM cerebro_reparto_planeado WHERE conversation_id = p_conv) THEN
              v_plan := _cerebro_reparto_planear(p_conv, v_parse -> 'partes', false, 'agent:repartir_envio');
            END IF;
            v_text := 'REPARTO NO APLICADO: las partes suman ' || _cerebro_fmt_monto(v_a::numeric) || ' GYD y el deposito a repartir es '
                      || _cerebro_fmt_monto(v_b::numeric) || ' GYD ('
                      || CASE WHEN v_a::numeric > v_b::numeric THEN 'faltan ' || _cerebro_fmt_monto(v_a::numeric - v_b::numeric) || ' GYD para cubrir las partes'
                              ELSE 'sobran ' || _cerebro_fmt_monto(v_b::numeric - v_a::numeric) || ' GYD del deposito' END
                      || '). Partes planeadas: ' || _cerebro_texto_partes(v_parse -> 'partes') || '. No se cambio nada. '
                      || 'Preguntale al cliente que parte cambia (o si deposita el resto) y vuelve a llamar con montos que sumen exactamente '
                      || _cerebro_fmt_monto(v_b::numeric) || ' GYD, o con solo las partes que el deposito verificado cubre (el resto queda pendiente). No prometas ninguna entrega hasta entonces.';
          ELSE
            v_motivo := CASE
              WHEN SQLERRM LIKE 'at least two parts%' THEN 'hacen falta al menos dos servicios'
              WHEN SQLERRM LIKE 'service % appears more than once' THEN 'hay un servicio repetido'
              WHEN SQLERRM LIKE 'the operation''s own service%' THEN 'el servicio de la operacion actual debe ser una de las partes'
              WHEN SQLERRM = 'operation is closed' THEN 'la operacion ya esta cerrada'
              WHEN SQLERRM LIKE 'there is no money to split%' THEN 'la operacion no tiene un monto registrado'
              WHEN SQLERRM LIKE 'group member % is completed%' THEN 'un servicio del grupo ya esta completado'
              ELSE 'el reparto no es valido' END;
            v_text := 'No se pudo repartir: ' || v_motivo || ' (detalle: ' || SQLERRM || '). No cambie nada.';
          END IF;
        WHEN OTHERS THEN
          PERFORM set_config('wacrm.origin', v_prev_origin, true);
          PERFORM set_config('wacrm.actor', v_prev_actor, true);
          RAISE;
      END;

      IF v_res IS NOT NULL THEN
        v_outcome := CASE WHEN v_parcial THEN 'parcial' ELSE 'repartido' END;
        IF v_parcial THEN
          -- (280) The plan keeps only the parts not applied; their operations stay open (and keep their data).
          SELECT * INTO v_pl FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
          IF FOUND THEN
            SELECT coalesce(jsonb_agg(e ORDER BY ord), '[]'::jsonb), coalesce(sum((e ->> 'monto_gyd')::numeric), 0)
              INTO v_pend, v_pend_tot
              FROM jsonb_array_elements(v_pl.partes) WITH ORDINALITY t(e, ord)
             WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_parse -> 'partes') x WHERE x ->> 'servicio' = e ->> 'servicio');
            IF jsonb_array_length(v_pend) = 0 THEN
              DELETE FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
            ELSE
              UPDATE cerebro_reparto_planeado SET partes = v_pend, total_gyd = v_pend_tot, creado_at = now() WHERE conversation_id = p_conv;
              FOR v_e IN SELECT e FROM jsonb_array_elements(v_pend) e LOOP
                PERFORM _cerebro_op_parte(p_conv, v_e ->> 'servicio', 'agent:repartir_envio', 'pending part after partial deposit');
              END LOOP;
              v_pend_txt := _cerebro_texto_partes(v_pend);
            END IF;
          END IF;
        ELSE
          DELETE FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
        END IF;
        FOR v_p IN SELECT * FROM jsonb_array_elements(v_res -> 'partes') LOOP
          SELECT * INTO v_o FROM remittance_operations WHERE id = (v_p ->> 'operation_id')::uuid;
          v_lista := v_lista || (
            CASE v_p ->> 'servicio' WHEN 'cuban_card' THEN 'tarjeta CUP' WHEN 'efectivo_usd' THEN 'efectivo USD' ELSE v_p ->> 'servicio' END
            || ' ' || _cerebro_fmt_monto((v_p ->> 'monto_gyd')::numeric) || ' GYD'
            || CASE WHEN v_o.quoted_destination_amount IS NOT NULL AND v_o.destination_currency IS NOT NULL
                    THEN ' (' || trim_scale(v_o.quoted_destination_amount)::text || ' ' || v_o.destination_currency || ')' ELSE '' END);
        END LOOP;
        v_dep   := (v_res ->> 'depositado')::numeric;
        v_saldo := (v_res ->> 'saldo')::numeric;
        IF v_parcial THEN
          v_text := 'Reparto parcial hecho: ' || array_to_string(v_lista, ', ') || '. Deposito verificado ' || _cerebro_fmt_monto(v_dep)
            || ' GYD; asignado ' || _cerebro_fmt_monto((v_res ->> 'asignado')::numeric) || ' GYD'
            || CASE WHEN (v_res ->> 'sobrante')::numeric > 0
                    THEN ' (sobran ' || _cerebro_fmt_monto((v_res ->> 'sobrante')::numeric) || ' GYD del deposito sin asignar)' ELSE '' END
            || '. ' || CASE WHEN v_pend_txt IS NOT NULL
                            THEN 'Pendiente, con su operacion y sus datos esperando deposito: ' || v_pend_txt || ' (total ' || _cerebro_fmt_monto(v_pend_tot) || ' GYD). '
                                 || 'Cuando el cliente deposite se unira a su operacion.'
                            ELSE 'No quedan partes pendientes.' END;
        ELSE
        v_text := 'Reparto hecho: ' || array_to_string(v_lista, ', ') || '. ' ||
          CASE
            WHEN v_dep > 0 AND v_saldo = 0 THEN 'Deposito ' || _cerebro_fmt_monto(v_dep) || ' GYD verificado, todo listo para transferir.'
            WHEN v_dep > 0 AND v_saldo > 0 THEN 'Deposito ' || _cerebro_fmt_monto(v_dep) || ' GYD verificado, faltan ' ||
                                                _cerebro_fmt_monto(v_saldo) || ' GYD por depositar para completar.'
            WHEN v_dep > 0 THEN 'Deposito ' || _cerebro_fmt_monto(v_dep) || ' GYD verificado, sobran ' ||
                                _cerebro_fmt_monto(-v_saldo) || ' GYD frente al reparto; un operador debe revisarlo.'
            ELSE 'Todavia no hay deposito verificado: queda pendiente el comprobante de ' || _cerebro_fmt_monto(v_dep + v_saldo) || ' GYD.'
          END;
        END IF;
      END IF;
    END IF;
  END IF;

  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments, outcome)
  VALUES (coalesce(nullif(btrim(p_execution), ''), gen_random_uuid()::text) || ':repartir_envio:' || md5(coalesce(p_partes, '')),
          'repartir_envio', p_execution, p_conv, v_op, jsonb_build_array(to_jsonb(p_partes)), v_outcome)
  ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN v_text;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_registrar_deposito(uuid, numeric, text, uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_deposito(uuid, numeric, text, uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_repartir_envio(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_repartir_envio(uuid, text, text) TO service_role;
