-- ROLLBACK of 217_zelle_objective_tier.sql: restores crm_calcular_monto_destino, crm_monto_resto_zelle, cerebro_resolver_operacion_beneficiario,
-- calculator_feed_operation and crm_resolve_pending_entry exactly as before 217 (pg_get_functiondef md5 on staging, 2026-10-05:
-- calculator_feed_operation 291d25bcbc91bfe164b8cfcad9c157f6, cerebro_resolver_operacion_beneficiario 359123ef627c42e9a808bc97d5128662,
-- crm_calcular_monto_destino 5490fdd8e3e821479af3bd0f22876c9e, crm_monto_resto_zelle c6d86945af68ec0e5976f0f2dd1fe8f2,
-- crm_resolve_pending_entry 36c6892c16d886de4db28b5d1e912dd0) and drops cerebro_zelle_cotizar_op. Zelle amounts return to the 215/216
-- rule (best GYD tier of the deposit, the objective is ignored). Amounts and entries already written keep their stored figures.
CREATE OR REPLACE FUNCTION public.calculator_feed_operation(p_operation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op        remittance_operations;
  v_rates     calculator_rate_versions;
  v_sell      numeric;
  v_zrate     numeric;
  v_part      record;
  v_missing   text[];
  v_basis     numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_currency  text;
  v_customer  text;
  v_entry_id  uuid;
  v_first_id  uuid;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.status <> 'completed' THEN
    RETURN NULL;
  END IF;

  IF v_op.quoted_source_amount IS NULL OR v_op.quoted_source_amount <= 0 THEN
    RETURN NULL;
  END IF;

  v_rates := calculator_rates_vigentes(v_op.account_id);
  -- (215) The Zelle sale rate is the tier of the deposit's TOTAL (also for a part of a split deposit).
  SELECT z.tasa INTO v_zrate FROM cerebro_zelle_cotizar_gyd(v_op.quoted_source_amount) z;

  SELECT c.name INTO v_customer
    FROM conversations conv JOIN contacts c ON c.id = conv.contact_id
   WHERE conv.id = v_op.conversation_id;

  FOR v_part IN SELECT * FROM calculator_operation_parts(v_op, v_rates) LOOP
    v_basis     := v_part.basis;
    v_amount    := NULL;
    v_facturado := NULL;
    v_invertido := NULL;
    v_missing   := calculator_missing_rates(v_part.service, v_rates) || coalesce(v_part.missing, ARRAY[]::text[]);
    -- (199) a recharge whose deposit matches no recharge price cannot be priced
    IF v_part.service = 'RECARGA' AND cerebro_recarga_precio(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['recargaPrecioGyd'];
    END IF;
    -- (209) a combo whose cost the admin has not entered yet stays pending
    IF v_part.service = 'COMBO' AND v_op.combo_costo_gyd IS NULL THEN
      v_missing := v_missing || ARRAY['comboCosto'];
    END IF;
    v_currency  := CASE WHEN v_part.service = 'CUP' THEN 'CUP' WHEN v_part.service = 'RECARGA' THEN 'REC'
                        WHEN v_part.service IN ('COMBO', 'VISA') THEN 'GYD' ELSE 'USD' END;
    -- (193) The sale rate of the line: a cash dollar sells at efectivo_usd_gyd; every other USD service at
    -- usdt_sell_gyd. The cost (usdt_buy_gyd) is shared. Snapshotted in usdt_sell_gyd (= the sale rate used).
    v_sell      := CASE WHEN v_part.service = 'EFECTIVO' THEN v_rates.efectivo_usd_gyd
                        -- (199) a recharge sells at the price its deposit pays (198 cerebro_recarga_precio)
                        WHEN v_part.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis)
                        -- (215) Zelle: tiered (still pending while the calculator has no sell rate); Clasica, Tropical and the rest keep usdt_sell_gyd
                        WHEN v_part.service = 'ZELLE' AND v_rates.usdt_sell_gyd IS NOT NULL THEN coalesce(v_zrate, v_rates.usdt_sell_gyd)
                        ELSE v_rates.usdt_sell_gyd END;

    IF v_part.service = 'COMBO' THEN
      -- (209) facturado = the verified deposit (GYD), invertido = the cost entered on the operation.
      IF v_basis IS NOT NULL AND v_basis > 0 AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_amount    := v_basis;
        v_facturado := v_basis;
        v_invertido := v_op.combo_costo_gyd;
      END IF;
    ELSIF v_part.service = 'VISA' THEN
      -- (213) facturado = the verified deposit (GYD), invertido = 0 (owner: all of it is profit). No rate, never pending.
      IF v_basis IS NOT NULL AND v_basis > 0 AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_amount    := v_basis;
        v_facturado := v_basis;
        v_invertido := 0;
      END IF;
    ELSIF v_basis IS NOT NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := calculator_amount_from_basis(v_part.service, v_basis, v_rates.cup_global_rate, v_sell);
      v_facturado := calculator_facturado(v_part.service, v_amount, v_rates.cup_global_rate, v_sell);
      v_invertido := CASE WHEN v_part.service = 'RECARGA'
                          -- (199) units x USDT cost per recharge x USDT buy rate (the guide's "rec promo" line)
                          THEN v_amount * v_rates.recarga_costo_usdt * v_rates.usdt_buy_gyd
                          ELSE calculator_invertido(v_part.service, v_amount, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd) END;
    END IF;

    IF v_basis IS NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_missing := ARRAY['beneficiaryAmounts'];
    END IF;

    IF v_amount IS NULL OR v_amount <= 0 THEN
      v_amount := v_part.placeholder_amount;
      v_facturado := NULL;
      v_invertido := NULL;
      IF coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_missing := ARRAY['beneficiaryAmounts'];
      END IF;
    END IF;

    -- (209) The cost of a combo is entered by hand and can change. Completed lines are append-only (149), so a live COMBO
    -- line whose figures differ is VOIDED here (figures untouched) and the upsert below revives that row with the new
    -- ones, the way a reverted-then-completed operation is re-fed. Identical figures: nothing is touched (idempotent).
    IF v_part.service = 'COMBO' THEN
      UPDATE remittance_calculator_entries e
         SET status = 'void', voided_at = clock_timestamp(), void_reason = 'combo cost or deposit changed; re-fed'
       WHERE e.account_id = v_op.account_id AND e.operation_id = v_op.id AND e.source = 'completed_operation'
         AND e.service = 'COMBO' AND e.status <> 'void'
         AND (e.status IS DISTINCT FROM CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END
              OR e.amount IS DISTINCT FROM v_amount OR e.facturado_gyd IS DISTINCT FROM v_facturado
              OR e.invertido_gyd IS DISTINCT FROM v_invertido OR e.basis_gyd IS DISTINCT FROM v_basis);
    END IF;

    INSERT INTO remittance_calculator_entries (
      account_id, source, status, operation_id, entry_date, customer_name,
      service, amount, amount_currency, basis_gyd,
      cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id,
      facturado_gyd, invertido_gyd, retorno_gyd,
      missing_inputs, delivery_mode, actor_user_id, completed_at, cost_gyd, sale_gyd
    ) VALUES (
      v_op.account_id, 'completed_operation',
      CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END,
      v_op.id, coalesce(v_op.completed_at, clock_timestamp())::date, v_customer,
      v_part.service, v_amount, v_currency, v_basis,
      -- (199) A RECARGA line reads like a manual "rec promo" one: cup_rate = USDT rate, cost_gyd = USDT cost, sale_gyd = price.
      -- (209) A COMBO line snapshots no rate (it does not depend on them). (213) Nor does a VISA line.
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_rates.cup_global_rate END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL
           WHEN v_part.service = 'RECARGA' THEN v_rates.usdt_buy_gyd ELSE v_rates.usdt_sell_cup END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_rates.usdt_buy_gyd END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_sell END, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp()),
      CASE WHEN v_part.service = 'RECARGA' THEN v_rates.recarga_costo_usdt
           WHEN v_part.service = 'COMBO' THEN v_op.combo_costo_gyd
           WHEN v_part.service = 'VISA' THEN 0 END,
      CASE WHEN v_part.service = 'RECARGA' THEN v_sell
           WHEN v_part.service IN ('COMBO', 'VISA') THEN v_facturado END
    )
    ON CONFLICT (account_id, operation_id, service) WHERE source = 'completed_operation'
    DO UPDATE SET
      status          = EXCLUDED.status,
      entry_date      = EXCLUDED.entry_date,
      customer_name   = EXCLUDED.customer_name,
      amount          = EXCLUDED.amount,
      amount_currency = EXCLUDED.amount_currency,
      basis_gyd       = EXCLUDED.basis_gyd,
      cup_global_rate = EXCLUDED.cup_global_rate,
      cup_rate        = EXCLUDED.cup_rate,
      usdt_buy_gyd    = EXCLUDED.usdt_buy_gyd,
      usdt_sell_gyd   = EXCLUDED.usdt_sell_gyd,
      rate_version_id = EXCLUDED.rate_version_id,
      facturado_gyd   = EXCLUDED.facturado_gyd,
      invertido_gyd   = EXCLUDED.invertido_gyd,
      retorno_gyd     = EXCLUDED.retorno_gyd,
      missing_inputs  = EXCLUDED.missing_inputs,
      delivery_mode   = EXCLUDED.delivery_mode,
      actor_user_id   = EXCLUDED.actor_user_id,
      completed_at    = EXCLUDED.completed_at,
      cost_gyd        = EXCLUDED.cost_gyd,
      sale_gyd        = EXCLUDED.sale_gyd,
      voided_at       = NULL,
      void_reason     = NULL
    WHERE remittance_calculator_entries.status = 'void'
    RETURNING id INTO v_entry_id;

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.cerebro_resolver_operacion_beneficiario(p_conversation_id uuid, p_estados text[], p_cuenta text)
 RETURNS TABLE(resultado text, operation_id uuid, candidatas integer, metodo text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_total     integer;
  v_unica     uuid;
  v_cuenta    text;
  v_es_correo boolean;
  v_es_tarjeta boolean;
  v_usd       numeric := crm_tasa_vigente('usd');
  v_cup       numeric := crm_tasa_vigente('gyd');
  v_desde     timestamptz;
  v_anchor_i  integer;
  v_anchor_t  timestamptz;
  v_m         record;
  v_num       text[];
  v_n         numeric;
  v_hit       uuid;
  v_hits      integer;
  v_cand      boolean;
  v_newest    uuid;
BEGIN
  -- (213) A visa and a combo are never the remesa target (the writers refuse them): they are not candidates here.
  -- 0/1 open operation: identical to cerebro_resolver_operacion.
  SELECT count(*) INTO v_total FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados));
  IF v_total = 0 THEN
    RETURN QUERY SELECT 'ninguna'::text, NULL::uuid, 0, 'ninguna'::text; RETURN;
  ELSIF v_total = 1 THEN
    SELECT o.id INTO v_unica FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
       AND (p_estados IS NULL OR o.status = ANY(p_estados));
    RETURN QUERY SELECT 'unica'::text, v_unica, 1, 'unica'::text; RETURN;
  END IF;

  -- Several: normalize the account the node is about to register.
  v_cuenta := lower(regexp_replace(coalesce(p_cuenta,''), '\s', '', 'g'));
  v_es_correo := position('@' in v_cuenta) > 0;
  IF NOT v_es_correo THEN
    v_cuenta := regexp_replace(v_cuenta, '\D', '', 'g');
    IF length(v_cuenta) = 11 AND left(v_cuenta, 1) = '1' THEN v_cuenta := substr(v_cuenta, 2); END IF;
  END IF;
  v_es_tarjeta := NOT v_es_correo AND length(v_cuenta) = 16;
  IF v_cuenta = '' THEN
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'sin_cuenta'::text; RETURN;
  END IF;

  -- The customer's messages since the oldest open operation (minus 3 h), in
  -- order, normalized, with their position.
  SELECT min(o.created_at) - interval '3 hours' INTO v_desde FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled');

  -- 1. Reparto guard.
  IF EXISTS (SELECT 1 FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) WHERE txt ~ '(personas|a cada|repart|una de las|mexico|méxico)') THEN
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'reparto'::text; RETURN;
  END IF;

  -- 3. Anchor: the MOST RECENT message that contains the account (133); else latest image.
  --    A customer who reuses an account for a new remesa writes it again: the first time it
  --    appeared belongs to the OLD remesa (1727ef31, de846b30).
  SELECT b.i, b.t INTO v_anchor_i, v_anchor_t FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b
   WHERE (v_es_correo AND replace(b.txt, ' ', '') LIKE '%' || v_cuenta || '%')
      OR (NOT v_es_correo AND regexp_replace(b.txt, '\D', '', 'g') LIKE '%' || v_cuenta || '%')
   ORDER BY b.i DESC LIMIT 1;
  IF v_anchor_i IS NULL THEN
    SELECT b.i, b.t INTO v_anchor_i, v_anchor_t FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b WHERE b.tipo = 'image' ORDER BY b.i DESC LIMIT 1;
  END IF;
  IF v_anchor_i IS NULL THEN v_anchor_t := now(); END IF;

  -- 4. Amount written next to the account.
  IF v_anchor_i IS NOT NULL THEN
    FOR v_m IN
      SELECT b.* FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b
       WHERE b.tipo = 'text' AND abs(b.i - v_anchor_i) <= 3
         AND abs(extract(epoch FROM b.t - v_anchor_t)) <= 180
       ORDER BY abs(b.i - v_anchor_i), b.i
    LOOP
      FOR v_num IN
        SELECT regexp_matches(v_m.txt,
          '(?:^|[^0-9.,])([0-9]{1,3}(?:[.,][0-9]{3})+|[0-9]{2,6})(?![0-9])\s*(usd|zelle|d[oó]lar(?:es)?|\$|cup|pesos)?', 'g')
      LOOP
        IF v_num[2] IS NULL AND btrim(v_m.txt) <> btrim(v_num[1])
           AND v_m.txt !~ '(zelle|usd|d[oó]lar|cup|tarjeta|\$)' THEN
          CONTINUE;
        END IF;
        v_n := replace(replace(v_num[1], '.', ''), ',', '')::numeric;
        SELECT count(*), min(o.id::text)::uuid INTO v_hits, v_hit FROM remittance_operations o
         WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
           AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
           AND (p_estados IS NULL OR o.status = ANY(p_estados))
           -- (215) A Zelle account is paired by the tiered USD of the deposit; a card (Clasica, Tropical) by the single rate.
           AND ((NOT v_es_tarjeta AND (SELECT z.usd FROM cerebro_zelle_cotizar_gyd(o.quoted_source_amount) z) = v_n)
                OR (v_es_tarjeta AND v_usd > 0 AND floor(o.quoted_source_amount / v_usd) = v_n)
                OR (v_es_tarjeta AND v_cup > 0 AND round(o.quoted_source_amount * v_cup) = v_n));
        IF v_hits = 1 THEN
          SELECT NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente')
              OR EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente'
                          AND (lower(coalesce(rb.zelle_account,'')) = v_cuenta
                               OR regexp_replace(coalesce(rb.zelle_account, rb.card_number, ''), '\D', '', 'g') IN (v_cuenta, '1' || v_cuenta)))
            INTO v_cand;
          IF v_cand THEN
            RETURN QUERY SELECT 'unica'::text, v_hit, v_total, 'monto'::text; RETURN;
          END IF;
          RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'monto_apunta_a_otra'::text; RETURN;
        END IF;
      END LOOP;
    END LOOP;
  END IF;

  -- 5. Proximity: exactly one open remesa created within 5 minutes.
  SELECT count(*), min(o.id::text)::uuid INTO v_hits, v_hit FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
     AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados))
     AND abs(extract(epoch FROM o.created_at - v_anchor_t)) <= 300;
  IF v_hits = 1 THEN
    SELECT NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente')
        OR EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente'
                    AND (lower(coalesce(rb.zelle_account,'')) = v_cuenta
                         OR regexp_replace(coalesce(rb.zelle_account, rb.card_number, ''), '\D', '', 'g') IN (v_cuenta, '1' || v_cuenta)))
      INTO v_cand;
    IF v_cand THEN
      RETURN QUERY SELECT 'unica'::text, v_hit, v_total, 'cercania'::text; RETURN;
    END IF;
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'cercania_apunta_a_otra'::text; RETURN;
  END IF;

  -- 6. Rule C.
  SELECT o.id INTO v_newest FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
     AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados))
   ORDER BY o.created_at DESC LIMIT 1;
  IF v_newest IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_newest AND rb.status = 'vigente')
     AND NOT EXISTS (
       SELECT 1 FROM remittance_operations o
        WHERE o.conversation_id = p_conversation_id AND o.id <> v_newest
          AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
          AND (p_estados IS NULL OR o.status = ANY(p_estados))
          AND o.created_at >= now() - interval '24 hours'
          AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = o.id AND rb.status = 'vigente'))
  THEN
    RETURN QUERY SELECT 'unica'::text, v_newest, v_total, 'regla_c'::text; RETURN;
  END IF;

  RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'sin_evidencia'::text;
END $function$
;
CREATE OR REPLACE FUNCTION public.crm_calcular_monto_destino(p_operation_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op            remittance_operations%ROWTYPE;
  v_found         boolean := true;
  v_vigente_count integer;
  v_ben           remittance_beneficiaries%ROWTYPE;
  v_rate          numeric;
  v_amount        numeric;
  v_currency      text;
  v_computable    boolean := false;
BEGIN
  -- Recursion guard: the UPDATEs below re-fire this migration's own AFTER
  -- triggers. If a calculation is already running higher up the call stack,
  -- do nothing here — the flag belongs to that outer invocation, so this
  -- nested call must not touch (and must not reset) it.
  IF current_setting('wacrm.calc_destino', true) = 'on' THEN
    RETURN;
  END IF;

  PERFORM set_config('wacrm.calc_destino', 'on', true);

  BEGIN
    SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
    IF NOT FOUND THEN
      v_found := false;
    END IF;

    -- Eligible at all: exists, is a remesa, is still open, its destination
    -- amount isn't human-locked, and it either has no destination amount
    -- yet or the one it has is this function's own prior calculation (never
    -- a pre-existing/manual value).
    IF v_found
       AND v_op.service_type = 'remesa'
       AND v_op.status NOT IN ('completed', 'cancelled')
       AND NOT (v_op.admin_locked_fields ? 'quoted_destination_amount')
       AND (v_op.quoted_destination_amount IS NULL
            OR coalesce(v_op.quoted_destination_origin, '') = 'calculated')
    THEN
      SELECT count(*) INTO v_vigente_count
        FROM remittance_beneficiaries
       WHERE operation_id = p_operation_id AND status = 'vigente';

      IF v_vigente_count = 1
         AND coalesce(v_op.quoted_source_amount, 0) > 0
         AND upper(coalesce(v_op.source_currency, 'GYD')) = 'GYD'
      THEN
        SELECT * INTO v_ben
          FROM remittance_beneficiaries
         WHERE operation_id = p_operation_id AND status = 'vigente';

        IF v_ben.beneficiary_type IN ('zelle', 'clasica', 'tropical') THEN
          -- (215) Zelle is priced by tier of the deposit; Clasica and Tropical keep the single rate.
          IF v_ben.beneficiary_type = 'zelle' THEN
            SELECT z.tasa INTO v_rate FROM cerebro_zelle_cotizar_gyd(v_op.quoted_source_amount) z;
          ELSE
            v_rate := crm_tasa_vigente('usd');
          END IF;
          IF v_rate > 0 THEN
            -- Whole units, rounded DOWN, in the business's favour: a
            -- part-unit is never delivered as a full one, because that
            -- hands over more value than the deposit covers (75,000 GYD
            -- at 260 is 288.46 USD; delivering 289 gives away 140 GYD).
            -- Mirrors document-rates.ts deriveAmountFromDeposit and 111's
            -- calculator_amount_from_basis, so the panel and the ledger
            -- cannot disagree about one remesa. n8n's bot has always
            -- floored — this brings the panel in line with it.
            v_amount := floor(v_op.quoted_source_amount / v_rate);
            v_currency := 'USD';
            v_computable := true;
          END IF;
        ELSIF v_ben.beneficiary_type = 'efectivo_usd' THEN
          -- (188) Cash USD has its own rate, the calculator's efectivo_usd_gyd (via `tasas`
          -- as 'efectivo'). Whole dollars, rounded DOWN, like the other USD rails.
          v_rate := crm_tasa_vigente('efectivo');
          IF v_rate > 0 THEN
            v_amount := floor(v_op.quoted_source_amount / v_rate);
            v_currency := 'USD';
            v_computable := true;
          END IF;
        ELSIF v_ben.beneficiary_type = 'cuban_card' THEN
          v_rate := crm_tasa_vigente('gyd');
          IF v_rate > 0 THEN
            v_amount := round(v_op.quoted_source_amount * v_rate);
            v_currency := 'CUP';
            v_computable := true;
          END IF;
        END IF;
      END IF;

      IF v_computable THEN
        UPDATE remittance_operations
           SET quoted_destination_amount = v_amount,
               destination_currency = v_currency,
               quoted_destination_rate = v_rate,
               quoted_destination_origin = 'calculated'
         WHERE id = p_operation_id
           AND (quoted_destination_amount IS DISTINCT FROM v_amount
                OR destination_currency IS DISTINCT FROM v_currency
                OR quoted_destination_rate IS DISTINCT FROM v_rate
                OR quoted_destination_origin IS DISTINCT FROM 'calculated');

        IF NOT (v_op.admin_locked_fields ? 'beneficiaries')
           AND (v_ben.amount IS NULL OR v_ben.amount_origin = 'calculated')
        THEN
          UPDATE remittance_beneficiaries
             SET amount = v_amount,
                 currency = v_currency,
                 amount_origin = 'calculated'
           WHERE id = v_ben.id
             AND (amount IS DISTINCT FROM v_amount
                  OR currency IS DISTINCT FROM v_currency
                  OR amount_origin IS DISTINCT FROM 'calculated');
        END IF;
      ELSIF v_op.quoted_destination_origin = 'calculated' THEN
        -- No longer computable (e.g. a second beneficiary showed up, or the
        -- rate disappeared) but the current value was this function's own
        -- stale calculation — clear it rather than leave a number nothing
        -- can now reproduce. destination_currency is left untouched: it is
        -- not exclusively this migration's field to clear.
        UPDATE remittance_operations
           SET quoted_destination_amount = NULL,
               quoted_destination_rate = NULL,
               quoted_destination_origin = NULL
         WHERE id = p_operation_id;

        IF NOT (v_op.admin_locked_fields ? 'beneficiaries') THEN
          UPDATE remittance_beneficiaries
             SET amount = NULL,
                 currency = NULL,
                 amount_origin = NULL
           WHERE operation_id = p_operation_id
             AND status = 'vigente'
             AND amount_origin = 'calculated';
        END IF;
      END IF;

      -- (176) Several beneficiaries, one of them a Zelle without its amount (kept by
      -- 175 next to a card reparto): the Zelle gets what is left of the remesa.
      IF v_vigente_count > 1 AND NOT (v_op.admin_locked_fields ? 'beneficiaries') THEN
        PERFORM crm_monto_resto_zelle(p_operation_id);
      END IF;
    END IF;

    PERFORM set_config('wacrm.calc_destino', 'off', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('wacrm.calc_destino', 'off', true);
    RAISE;
  END;
END $function$
;
CREATE OR REPLACE FUNCTION public.crm_monto_resto_zelle(p_operation_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op    remittance_operations%ROWTYPE;
  v_total numeric;
  v_usd   numeric := crm_tasa_vigente('usd');
  v_cup   numeric := crm_tasa_vigente('gyd');
  v_zrate numeric;
  v_zelle uuid;
  v_resto numeric;
  v_monto numeric;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.admin_locked_fields ? 'beneficiaries' OR NOT (v_usd > 0 AND v_cup > 0) THEN RETURN NULL; END IF;

  v_total := CASE WHEN coalesce(v_op.quoted_source_amount, 0) > 0 THEN v_op.quoted_source_amount
                  ELSE cerebro_cotizacion_vigente(v_op.conversation_id) END;
  IF v_total IS NULL OR v_total <= 0 THEN RETURN NULL; END IF;

  -- (215) The Zelle share is priced at the tier of the deposit's TOTAL; the other USD shares keep the single rate.
  SELECT z.tasa INTO v_zrate FROM cerebro_zelle_cotizar_gyd(v_total) z;
  v_zrate := coalesce(v_zrate, v_usd);

  -- Exactly one vigente Zelle without a human amount; every other vigente share priced.
  IF (SELECT count(*) FROM remittance_beneficiaries
       WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type = 'zelle'
         AND (amount IS NULL OR amount_origin = 'calculated')) <> 1
     OR (SELECT count(*) FROM remittance_beneficiaries
          WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type = 'zelle') <> 1
     OR EXISTS (SELECT 1 FROM remittance_beneficiaries
                 WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type <> 'zelle'
                   AND (amount IS NULL OR currency NOT IN ('CUP', 'USD'))) THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_zelle FROM remittance_beneficiaries
   WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type = 'zelle';

  SELECT v_total - coalesce(sum(CASE WHEN currency = 'CUP' THEN amount / v_cup ELSE amount * v_usd END), 0)
    INTO v_resto
    FROM remittance_beneficiaries
   WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type <> 'zelle';

  v_monto := floor(v_resto / v_zrate);
  IF v_monto <= 0 THEN v_monto := NULL; END IF;

  UPDATE remittance_beneficiaries
     SET amount = v_monto,
         currency = CASE WHEN v_monto IS NULL THEN NULL ELSE 'USD' END,
         amount_origin = CASE WHEN v_monto IS NULL THEN NULL ELSE 'calculated' END
   WHERE id = v_zelle
     AND (amount IS DISTINCT FROM v_monto OR (v_monto IS NOT NULL AND amount_origin IS DISTINCT FROM 'calculated'));
  RETURN v_monto;
END $function$
;
CREATE OR REPLACE FUNCTION public.crm_resolve_pending_entry(p_entry_id uuid, p_rates jsonb, p_reason text)
 RETURNS remittance_calculator_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry     remittance_calculator_entries;
  v_before    jsonb;
  v_basis     numeric;
  v_cup_glob  numeric;
  v_cup_rate  numeric;
  v_buy       numeric;
  v_sell      numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_missing   text[];
  v_key       text;
  v_value     numeric;
  v_zrate     numeric;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin') THEN
    RAISE EXCEPTION 'not authorized to resolve ledger entries' USING ERRCODE = '42501';
  END IF;

  IF v_entry.status <> 'verified_pending' THEN
    RAISE EXCEPTION 'only a pending entry can be resolved' USING ERRCODE = '22023';
  END IF;

  -- (209) A COMBO line is priced by the combo's cost (crm_set_combo_costo, panel), never by rates.
  IF v_entry.service = 'COMBO' THEN
    RAISE EXCEPTION 'a combo line is resolved by entering the combo cost in the panel, not with rates' USING ERRCODE = '22023';
  END IF;

  -- (213) A VISA line never needs rates (facturado = the deposit, invertido = 0): nothing to resolve with them.
  IF v_entry.service = 'VISA' THEN
    RAISE EXCEPTION 'a visa line needs no rates: it is priced by its deposit' USING ERRCODE = '22023';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'a reason of at least 5 characters is required' USING ERRCODE = '22023';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' OR p_rates = '{}'::jsonb THEN
    RAISE EXCEPTION 'no rates provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_rates) LOOP
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup', 'efectivo_usd_gyd') THEN
      RAISE EXCEPTION 'unknown rate: %', v_key USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_rates -> v_key) <> 'number' THEN
      RAISE EXCEPTION 'rate % must be a number', v_key USING ERRCODE = '22023';
    END IF;
    v_value := (p_rates ->> v_key)::numeric;
    IF v_value <= 0 OR v_value >= 1e9 THEN
      RAISE EXCEPTION 'rate % must be greater than 0 and less than 1e9', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_before := to_jsonb(v_entry);

  -- coalesce, not overwrite: what the entry already recorded wins.
  v_cup_glob := coalesce(v_entry.cup_global_rate, (p_rates ->> 'cup_global_rate')::numeric);
  v_cup_rate := coalesce(v_entry.cup_rate,        (p_rates ->> 'usdt_sell_cup')::numeric);
  v_buy      := coalesce(v_entry.usdt_buy_gyd,    (p_rates ->> 'usdt_buy_gyd')::numeric);
  -- (193) A cash line sells at the cash rate.
  v_sell     := coalesce(v_entry.usdt_sell_gyd,
                         CASE WHEN v_entry.service = 'EFECTIVO' THEN (p_rates ->> 'efectivo_usd_gyd')::numeric
                              ELSE (p_rates ->> 'usdt_sell_gyd')::numeric END);

  -- (215) A ZELLE line whose operation's deposit total reaches a tier above the base one sells at that tier, not at
  -- the rate the payload carries. A deposit in the base tier keeps the rate the admin entered, and a line still
  -- missing its sell rate keeps asking for it (the required-rate check below is unchanged).
  IF v_entry.service = 'ZELLE' AND v_sell IS NOT NULL THEN
    SELECT z.tasa INTO v_zrate
      FROM remittance_operations o, cerebro_zelle_cotizar_gyd(o.quoted_source_amount) z
     WHERE o.id = v_entry.operation_id;
    IF v_zrate IS NOT NULL AND v_zrate < cerebro_tasa_zelle(50) THEN
      v_sell := coalesce(v_entry.usdt_sell_gyd, v_zrate);
    END IF;
  END IF;

  IF v_entry.service = 'CUP' THEN
    v_missing := array_remove(ARRAY[
      CASE WHEN v_cup_glob IS NULL THEN 'cupGlobalRate' END,
      CASE WHEN v_cup_rate IS NULL THEN 'usdtSellCup'   END,
      CASE WHEN v_buy      IS NULL THEN 'usdtBuyGyd'    END
    ], NULL);
  ELSE
    v_missing := array_remove(ARRAY[
      CASE WHEN v_buy  IS NULL THEN 'usdtBuyGyd'  END,
      CASE WHEN v_sell IS NULL THEN CASE WHEN v_entry.service = 'EFECTIVO' THEN 'efectivoUsdGyd' ELSE 'usdtSellGyd' END END
    ], NULL);
  END IF;

  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'still missing required rate(s): %', array_to_string(v_missing, ', ')
      USING ERRCODE = '22023';
  END IF;

  -- The deposit is re-read from the operation rather than trusted from the
  -- pending row, whose `amount` column held the deposit as a placeholder.
  -- (142) A line of a MIXED remesa is priced on its own share of the
  -- deposit (basis_gyd), never on the whole deposit.
  IF v_entry.basis_gyd IS NOT NULL THEN
    v_basis := v_entry.basis_gyd;
  ELSIF EXISTS (SELECT 1 FROM remittance_calculator_entries o
                 WHERE o.account_id = v_entry.account_id
                   AND o.operation_id = v_entry.operation_id
                   AND o.source = 'completed_operation'
                   AND o.service <> v_entry.service
                   AND o.status <> 'void') THEN
    RAISE EXCEPTION 'this line belongs to a mixed remesa whose share is unknown: fix the beneficiary amounts and re-feed the operation'
      USING ERRCODE = '22023';
  ELSE
    SELECT quoted_source_amount INTO v_basis
      FROM remittance_operations WHERE id = v_entry.operation_id;
  END IF;

  v_amount    := calculator_amount_from_basis(v_entry.service, v_basis, v_cup_glob, v_sell);
  v_facturado := calculator_facturado(v_entry.service, v_amount, v_cup_glob, v_sell);
  v_invertido := calculator_invertido(v_entry.service, v_amount, v_cup_rate, v_buy);

  IF v_amount IS NULL OR v_facturado IS NULL OR v_invertido IS NULL THEN
    RAISE EXCEPTION 'the operation has no usable deposit amount to price' USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_calculator_entries
     SET status          = 'completed',
         amount          = v_amount,
         cup_global_rate = v_cup_glob,
         cup_rate        = v_cup_rate,
         usdt_buy_gyd    = v_buy,
         usdt_sell_gyd   = v_sell,
         facturado_gyd   = v_facturado,
         invertido_gyd   = v_invertido,
         retorno_gyd     = v_facturado - v_invertido,
         missing_inputs  = NULL
   WHERE id = p_entry_id
   RETURNING * INTO v_entry;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, action, actor, reason, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id,
          'calculator_pending_resolved', wacrm_current_actor(), btrim(p_reason),
          v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$function$
;
DROP FUNCTION IF EXISTS public.cerebro_zelle_cotizar_op(uuid, numeric);
DELETE FROM supabase_migrations.schema_migrations WHERE version = '217';
