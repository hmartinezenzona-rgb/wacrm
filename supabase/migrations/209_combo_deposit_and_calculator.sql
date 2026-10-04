-- =====================================================================
-- 209 -- A combo deposit lands on the combo, and a completed combo feeds the calculator as COMBO (staging first)
--
-- odd/tasks/combos-end-to-end.md (T1b). 208 built the combo model; a combo deposit was still filed as a remesa and a
-- completed combo reached no calculator line.
--
--   A. DEPOSIT ROUTING (mirrors the recharge mechanism of 202/204)
--      - cerebro_combo_en_curso(conv): TRUE when a combo operation is open for the conversation, or the customer typed
--        "combo(s)" or "mandar/enviar comida" in the window cerebro_textos_cliente_recientes uses and no card is pending.
--        The text rule is deliberately narrower than the bare word "comida" (a remesa "para la comida de mi mama" stays
--        a remesa) and "paquete" is left out (ambiguous).
--      - cerebro_registrar_deposito: the deposit lands on the open combo ("movido"), or creates a combo operation when
--        combo is in progress. PRECEDENCE when both recarga and combo apply: the operation that is actually OPEN wins;
--        a combo wins only when a combo operation is open and no recarga operation is; with both open, or neither open
--        (text only), the recarga wins as before. Remesa and recarga-only conversations behave exactly as before.
--      - cerebro_recruzar_depositos_tardios also re-crosses a combo waiting in deposit_verification (it paid by MMG).
--      - A combo has its own rail 'combo' (cerebro_riel_op) with a minimum of 25,000 GYD per recipient
--        (cerebro_minimo_gyd), and the "waiting for the rest" objetivo names it (cerebro_objetivo_minimo), instead of
--        falling through to the 5,000 GYD card minimum.
--      - The status after a verified deposit follows cerebro_estado_desde_etapa like remesa/recarga; a combo whose
--        recipients are incomplete behaves like a recharge without numbers (the deposit lands, the data is asked for).
--   B. CALCULATOR
--      - entries service CHECK gains 'COMBO'; combo -> COMBO in calculator_service_for_operation and
--        calculator_resolve_operation_service.
--      - calculator_feed_operation, COMBO branch: basis_gyd = amount = facturado = the verified deposit (GYD), invertido =
--        remittance_operations.combo_costo_gyd, retorno = difference, amount_currency 'GYD', cost_gyd = the cost,
--        sale_gyd = the deposit, rate_version_id = the live version, every rate snapshot (cup_*, usdt_*) NULL (a combo
--        does not depend on the rates). While the cost IS NULL the line is verified_pending with missing_inputs
--        {comboCosto}. A changed cost re-feeds the operation: the live COMBO line (pending or completed; completed rows are
--        append-only) is voided and the same row revived with the new figures, so re-setting never duplicates.
--      - calculator_missing_rates('COMBO') asks for no rate.
--      - crm_set_combo_costo feeds a completed combo right after it saves the cost (set, change or clear).
--
-- Guarded by supabase/staging/assertions/combo-deposit-calculator.sql.
-- ROLLBACK: ROLLBACK-209-combo-deposit-and-calculator.sql
-- =====================================================================

ALTER TABLE remittance_calculator_entries DROP CONSTRAINT remittance_calculator_entries_service_chk;
ALTER TABLE remittance_calculator_entries ADD CONSTRAINT remittance_calculator_entries_service_chk
  CHECK (service = ANY (ARRAY['CUP', 'ZELLE', 'MLC', 'CLASICA', 'TROPICAL', 'USDT', 'RECARGA', 'SALDO_MOVIL', 'DIRECTO', 'EFECTIVO', 'COMBO']));

-- ---------------------------------------------------------------------
-- A. Deposit routing
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_combo_en_curso(p_conv uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (209) The customer asked for a combo in the recent window (combo/combos, or mandar/enviar comida) and no card is
  -- pending: the same rule shape as cerebro_recarga_en_curso.
  SELECT (coalesce(cerebro_textos_cliente_recientes(p_conv)
                     ~* '(\mcombos?\M|\m(mandar|enviar|mando|envio|envío)\s+(la\s+|una\s+|unas\s+|mucha\s+)?comida)', false)
          AND NOT EXISTS (SELECT 1 FROM cerebro_beneficiario_parcial bp
                           WHERE bp.conversation_id = p_conv AND COALESCE(bp.tarjeta, '') <> ''))
      -- or a combo is already open (the agent opened it with its recipients)
      OR EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.service_type = 'combo'
                    AND o.status NOT IN ('completed', 'cancelled'));
$function$;

-- cerebro_registrar_deposito: current body (202/204 chain), with the combo branch.
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
  -- (202) Decided up front (was computed after the movido search, inline): a recharge deposit can land on the recharge
  -- the customer's numbers already opened.
  v_recarga := NOT v_rev AND cerebro_recarga_en_curso(p_conv);
  -- (209) A combo deposit lands on the combo. When both apply the operation that is actually OPEN wins: the combo only
  -- when a combo operation is open and no recarga operation is; with both open, or only text, the recarga as before.
  v_combo := NOT v_rev AND cerebro_combo_en_curso(p_conv)
             AND (NOT v_recarga
                  OR (EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                                 AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled'))
                      AND NOT EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                                 AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled'))));
  IF v_combo THEN v_recarga := false; END IF;

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
       -- (202) or the recharge the customer's numbers opened
       -- (209) or the combo the customer is ordering
       AND (ro.service_type = 'remesa' OR (v_recarga AND ro.service_type = 'recarga')
            OR (v_combo AND ro.service_type = 'combo'))
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

  -- (160) Recarga 24 h window: now decided up front by cerebro_recarga_en_curso (202).

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
    -- (202) a recharge takes any number typed since (no repeats)
    IF (SELECT service_type FROM remittance_operations WHERE id = v_ex) = 'recarga' THEN
      PERFORM crm_registrar_numeros_recarga(p_conv, cerebro_textos_cliente_recientes(p_conv));
    END IF;
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
    CASE WHEN v_rev THEN 'remesa' WHEN v_combo THEN 'combo' WHEN v_recarga THEN 'recarga' ELSE 'remesa' END,
    p_monto, coalesce(p_moneda, 'GYD'), now(),
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'completed' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'cancelled' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident' THEN v_motivo ELSE NULL END
  )
  RETURNING id INTO v_id;

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
  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_recruzar_depositos_tardios()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op  record;
  v_res record;
  v_n   integer := 0;
BEGIN
  FOR v_op IN
    SELECT o.id, o.account_id
      FROM remittance_operations o
     WHERE o.status = 'deposit_verification'
       AND o.service_type IN ('remesa', 'combo')  -- (209) a combo is paid by MMG too
       AND o.created_at > now() - interval '24 hours'
       AND o.updated_at < now() - interval '90 seconds'
       AND EXISTS (SELECT 1 FROM depositos_mmg m JOIN remittance_operation_receipts r
                     ON r.operation_id = o.id
                    AND (r.reference ~ ('(^|[^0-9])' || m.trans_id || '([^0-9]|$)')
                         -- (197) or a similar reference of the same amount (a misread digit or a swap)
                         OR (m.monto = r.amount AND cerebro_ref_parecida((regexp_match(r.reference, '([0-9]{8,})'))[1], m.trans_id)))
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
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_riel_op(p_op uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN o.service_type = 'recarga' THEN 'recarga'
              -- (209) a combo has its own rail (its recipients are 'combo' rows, but it can have none yet)
              WHEN o.service_type = 'combo' THEN 'combo' ELSE COALESCE(
    NULLIF(o.delivery_method, ''),
    (SELECT b.beneficiary_type FROM remittance_beneficiaries b
      WHERE b.operation_id = o.id AND b.status = 'vigente' ORDER BY b.position LIMIT 1),
    (SELECT p.tipo FROM cerebro_destino_pendiente p
      WHERE p.conversation_id = o.conversation_id AND p.actualizado > now() - interval '24 hours'),
    (SELECT CASE WHEN NULLIF(bp.zelle_cuenta, '') IS NOT NULL THEN 'zelle'
                 WHEN NULLIF(bp.tarjeta, '') IS NOT NULL THEN 'cuban_card' END
       FROM cerebro_beneficiario_parcial bp
      WHERE bp.conversation_id = o.conversation_id AND bp.actualizado > now() - interval '24 hours')) END
    FROM remittance_operations o
   WHERE o.id = p_op;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_minimo_gyd(p_op uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_riel text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM remittance_operations WHERE id = p_op) THEN RETURN NULL; END IF;
  v_riel := cerebro_riel_op(p_op);
  RETURN CASE
    WHEN v_riel = 'recarga'
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200)
    -- (209) A combo: 25,000 GYD per recipient (at least one).
    WHEN v_riel = 'combo'
      THEN 25000 * greatest(1, (SELECT count(*) FROM remittance_beneficiaries b
                                 WHERE b.operation_id = p_op AND b.status = 'vigente'))
    WHEN v_riel IN ('zelle', 'clasica', 'tropical')
      THEN COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                    NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN v_riel = 'efectivo_usd'
      THEN cerebro_minimo_efectivo_gyd()  -- (188) 100 USD x the calculator cash rate
    ELSE COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000)
  END;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_objetivo_minimo(p_conv uuid, p_deal uuid, p_siempre boolean DEFAULT false)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                        WHEN 'combo' THEN 'combo'  -- (209)
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
END $function$;

-- ---------------------------------------------------------------------
-- B. Calculator
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculator_service_for_operation(p_delivery_method text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE lower(coalesce(p_delivery_method, ''))
           WHEN 'cuban_card'            THEN 'CUP'
           WHEN 'multiple_distribution' THEN 'CUP'
           WHEN 'zelle'                 THEN 'ZELLE'
           WHEN 'clasica'               THEN 'CLASICA'
           WHEN 'tropical'              THEN 'TROPICAL'
           -- (193) Cash dollars delivered in Cuba: their own service, priced at the cash sale rate.
           WHEN 'efectivo_usd'          THEN 'EFECTIVO'
           -- (199) A beneficiary row of a recharge (one Cuban number per recharge).
           WHEN 'recarga'               THEN 'RECARGA'
           -- (209) A combo (its beneficiary rows are typed 'combo' and so is its service_type).
           WHEN 'combo'                 THEN 'COMBO'
           ELSE NULL
         END;
$function$;

CREATE OR REPLACE FUNCTION public.calculator_resolve_operation_service(p_operation_id uuid, p_delivery_method text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
           -- (199) A recharge is priced as RECARGA whatever its rows say (even with no number yet).
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'recarga' THEN 'RECARGA'
           -- (209) A combo is priced as COMBO whatever its rows say.
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'combo' THEN 'COMBO'
           WHEN NOT EXISTS (
             SELECT 1 FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) THEN calculator_service_for_operation(p_delivery_method)
           WHEN (
             SELECT count(DISTINCT b.beneficiary_type)
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) = 1 THEN calculator_service_for_operation((
             SELECT b.beneficiary_type
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
              LIMIT 1
           ))
           ELSE NULL
         END;
$function$;

CREATE OR REPLACE FUNCTION public.calculator_missing_rates(p_service text, p_rates calculator_rate_versions)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_service
    WHEN 'CUP' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.cup_global_rate IS NULL THEN 'cupGlobalRate' END,
        CASE WHEN p_rates.usdt_sell_cup   IS NULL THEN 'usdtSellCup'   END,
        CASE WHEN p_rates.usdt_buy_gyd    IS NULL THEN 'usdtBuyGyd'    END
      ], NULL)
    -- (199) A recharge: its USDT cost and the USDT buy rate (its price comes from the deposit, see the feed).
    WHEN 'RECARGA' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.recarga_costo_usdt IS NULL THEN 'recargaCostoUsdt' END,
        CASE WHEN p_rates.usdt_buy_gyd       IS NULL THEN 'usdtBuyGyd'       END
      ], NULL)
    -- (209) A combo depends on no rate: its cost is entered on the operation (the feed names comboCosto).
    WHEN 'COMBO' THEN ARRAY[]::text[]
    -- (193) Cash: the shared buy rate and the cash sale rate (efectivo_usd_gyd), not the Zelle sale rate.
    WHEN 'EFECTIVO' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.usdt_buy_gyd     IS NULL THEN 'usdtBuyGyd'     END,
        CASE WHEN p_rates.efectivo_usd_gyd IS NULL THEN 'efectivoUsdGyd' END
      ], NULL)
    ELSE
      array_remove(ARRAY[
        CASE WHEN p_rates.usdt_buy_gyd  IS NULL THEN 'usdtBuyGyd'  END,
        CASE WHEN p_rates.usdt_sell_gyd IS NULL THEN 'usdtSellGyd' END
      ], NULL)
  END;
$function$;

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
                        WHEN v_part.service = 'COMBO' THEN 'GYD' ELSE 'USD' END;
    -- (193) The sale rate of the line: a cash dollar sells at efectivo_usd_gyd; every other USD service at
    -- usdt_sell_gyd. The cost (usdt_buy_gyd) is shared. Snapshotted in usdt_sell_gyd (= the sale rate used).
    v_sell      := CASE WHEN v_part.service = 'EFECTIVO' THEN v_rates.efectivo_usd_gyd
                        -- (199) a recharge sells at the price its deposit pays (198 cerebro_recarga_precio)
                        WHEN v_part.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis)
                        ELSE v_rates.usdt_sell_gyd END;

    IF v_part.service = 'COMBO' THEN
      -- (209) facturado = the verified deposit (GYD), invertido = the cost entered on the operation.
      IF v_basis IS NOT NULL AND v_basis > 0 AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_amount    := v_basis;
        v_facturado := v_basis;
        v_invertido := v_op.combo_costo_gyd;
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
      -- (209) A COMBO line snapshots no rate (it does not depend on them).
      CASE WHEN v_part.service = 'COMBO' THEN NULL ELSE v_rates.cup_global_rate END,
      CASE WHEN v_part.service = 'COMBO' THEN NULL
           WHEN v_part.service = 'RECARGA' THEN v_rates.usdt_buy_gyd ELSE v_rates.usdt_sell_cup END,
      CASE WHEN v_part.service = 'COMBO' THEN NULL ELSE v_rates.usdt_buy_gyd END,
      CASE WHEN v_part.service = 'COMBO' THEN NULL ELSE v_sell END, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp()),
      CASE WHEN v_part.service = 'RECARGA' THEN v_rates.recarga_costo_usdt
           WHEN v_part.service = 'COMBO' THEN v_op.combo_costo_gyd END,
      CASE WHEN v_part.service = 'RECARGA' THEN v_sell
           WHEN v_part.service = 'COMBO' THEN v_facturado END
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
$function$;

CREATE OR REPLACE FUNCTION public.crm_set_combo_costo(p_operation_id uuid, p_costo_gyd numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- (208) The admin enters what a combo cost (GYD); NULL clears it. Same role as closing an operation by hand.
DECLARE
  v_account_id uuid;
  v_service    text;
  v_before     numeric;
  v_status     text;
BEGIN
  SELECT account_id, service_type, combo_costo_gyd, status INTO v_account_id, v_service, v_before, v_status
    FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'only an owner or admin can set the cost of a combo' USING ERRCODE = '42501';
  END IF;
  IF v_service IS DISTINCT FROM 'combo' THEN
    RAISE EXCEPTION 'only a combo has a cost entered by hand' USING ERRCODE = '22023';
  END IF;
  IF p_costo_gyd IS NOT NULL AND (p_costo_gyd < 0 OR p_costo_gyd >= 1e9) THEN
    RAISE EXCEPTION 'the cost must be between 0 and 1e9' USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_operations SET combo_costo_gyd = p_costo_gyd WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'combo_costo_gyd', 'human_combo_cost_set', wacrm_current_actor(),
          jsonb_build_object('combo_costo_gyd', v_before), jsonb_build_object('combo_costo_gyd', p_costo_gyd));

  -- (209) A completed combo reaches the calculator now: the line is created, priced, or (cost cleared) left pending.
  IF v_status = 'completed' THEN
    PERFORM calculator_feed_operation(p_operation_id);
  END IF;

  RETURN jsonb_build_object('combo_costo_gyd', p_costo_gyd);
END $function$;

