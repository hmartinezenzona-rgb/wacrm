-- ROLLBACK of 257_cup_source_card.sql: restores the 256 bodies of calculator_feed_operation, crm_entregar_operacion, crm_cerrar_operacion_manual,
-- crm_inventario_cup_operacion, cup_planificar and cup_consumir with their original signatures and ACLs, drops the 4-/7-argument allocators, the
-- validator and the remittance_operations.cup_source_card_id column (the recorded choices are lost; consumptions already taken stay).
-- No BEGIN/COMMIT.

DROP FUNCTION IF EXISTS public.crm_entregar_operacion(uuid, jsonb, boolean, uuid);
DROP FUNCTION IF EXISTS public.crm_cerrar_operacion_manual(uuid, text, boolean, text, uuid);
DROP FUNCTION IF EXISTS public.crm_inventario_cup_operacion(uuid, uuid);

CREATE OR REPLACE FUNCTION public.crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb, p_notify boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_deal_id       uuid;

  v_status_before text;
  v_status_after  text;
  v_completed_at  timestamptz;

  v_mode          text;
  v_wamid         text;
  v_path          text;
BEGIN
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to deliver this operation' USING ERRCODE = '42501';
  END IF;

  IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'evidence must be a JSON object' USING ERRCODE = '22023';
  END IF;

  v_mode := p_evidence ->> 'mode';
  IF v_mode IS NULL OR v_mode NOT IN ('proof_sent', 'no_proof', 'skip_proof') THEN
    RAISE EXCEPTION 'evidence mode must be proof_sent, no_proof or skip_proof' USING ERRCODE = '22023';
  END IF;

  IF p_evidence ? 'wamid' AND (p_evidence -> 'wamid') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'wamid') <> 'string' THEN
      RAISE EXCEPTION 'evidence wamid must be a string' USING ERRCODE = '22023';
    END IF;
    v_wamid := p_evidence ->> 'wamid';
    IF v_wamid = '' OR length(v_wamid) > 500 THEN
      RAISE EXCEPTION 'evidence wamid must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_evidence ? 'path' AND (p_evidence -> 'path') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'path') <> 'string' THEN
      RAISE EXCEPTION 'evidence path must be a string' USING ERRCODE = '22023';
    END IF;
    v_path := p_evidence ->> 'path';
    IF v_path = '' OR length(v_path) > 500 THEN
      RAISE EXCEPTION 'evidence path must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- (164) The ordering lock that stood here — a `FOR UPDATE` on the legacy
  -- deal row — was removed with the legacy table. It only serialized
  -- against retired n8n notes/value writes and touched no result.

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  IF NOT crm_beneficiarios_completos(p_operation_id) THEN
    RAISE EXCEPTION 'beneficiary data is incomplete' USING ERRCODE = '22023';
  END IF;

  -- (143) With proof and 2+ current beneficiaries, every beneficiary needs
  -- its own proof (crm_registrar_prueba_beneficiario) before delivering.
  IF v_mode = 'proof_sent' AND crm_pruebas_faltantes(p_operation_id) > 0 THEN
    RAISE EXCEPTION 'every beneficiary needs its delivery proof before delivering (% missing)',
      crm_pruebas_faltantes(p_operation_id)
      USING ERRCODE = '22023';
  END IF;

  -- (114) One statement: status, evidence, completed_at (the latter set
  -- automatically by trg_remittance_operations_touch, 040) all land in
  -- the same NEW row image the calculator feed trigger reads.
  UPDATE remittance_operations
     SET status = 'completed',
         -- (191) The panel's notify-customer choice, in the row image the notifier reads.
         customer_notice_muted_for = CASE WHEN p_notify THEN NULL ELSE 'completed' END,
         delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid()
   WHERE id = p_operation_id
     AND status = 'ready_to_transfer'
  RETURNING status, completed_at INTO v_status_after, v_completed_at;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer'),
          jsonb_build_object('status', 'completed', 'evidence', p_evidence));

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;
REVOKE ALL ON FUNCTION public.crm_entregar_operacion(uuid, jsonb, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_entregar_operacion(uuid, jsonb, boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.crm_cerrar_operacion_manual(p_operation_id uuid, p_motivo text DEFAULT NULL::text, p_notify boolean DEFAULT false, p_delivery_method text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_status_before text;
  v_service_before text;
  v_service_after text;
  v_completed_at  timestamptz;
  v_motivo        text := coalesce(nullif(btrim(p_motivo), ''), 'Closed manually from the panel');
BEGIN
  SELECT account_id, status, service_type INTO v_account_id, v_status_before, v_service_before
    FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'only an owner or admin can close an operation manually' USING ERRCODE = '42501';
  END IF;
  -- (191) No typed reason any more: the fixed note above is audited unless one is given.
  IF length(v_motivo) > 500 THEN
    RAISE EXCEPTION 'the reason must be at most 500 characters' USING ERRCODE = '22023';
  END IF;
  -- (196) The service chosen in the panel when the remesa has no beneficiary, so the calculator can price it.
  IF p_delivery_method IS NOT NULL THEN
    IF p_delivery_method NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo') THEN
      RAISE EXCEPTION 'unknown service: %', p_delivery_method USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente') THEN
      RAISE EXCEPTION 'this remesa already has a beneficiary: its service comes from it' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_status_before NOT IN ('ready_to_transfer', 'transferring') THEN
    RAISE EXCEPTION 'only a verified operation can be closed manually (status %)', v_status_before USING ERRCODE = '22023';
  END IF;

  -- (249) The chosen service IS the operation's service, as in _cambiar_servicio_core (222): a remesa rail makes a remesa.
  v_service_after := CASE WHEN p_delivery_method IS NULL THEN v_service_before
                          WHEN p_delivery_method IN ('recarga', 'combo', 'visa', 'saldo') THEN p_delivery_method
                          ELSE 'remesa' END;

  -- One statement, like crm_entregar_operacion: completed_at (040) and the calculator feed read this row image.
  UPDATE remittance_operations
     SET status = 'completed', delivery_mode = 'closed_manually', delivered_by = auth.uid(),
         -- (196) In the same UPDATE, so the calculator feed (AFTER UPDATE OF status) sees the service.
         -- (200) 'recarga' is a kind of operation, not a delivery method: it sets service_type. (208) So is 'combo'. (213) And 'visa'. (223) And 'saldo'.
         delivery_method = CASE WHEN p_delivery_method IN ('recarga', 'combo', 'visa', 'saldo') THEN delivery_method ELSE coalesce(p_delivery_method, delivery_method) END,
         service_type = v_service_after,
         -- (249) A combo cost belongs to a combo only.
         combo_costo_gyd = CASE WHEN v_service_after = 'combo' THEN combo_costo_gyd END,
         -- (191) Silent by default (p_notify false); the bell on the panel can turn the notice on.
         customer_notice_muted_for = CASE WHEN p_notify THEN NULL ELSE 'completed' END
   WHERE id = p_operation_id
  RETURNING completed_at INTO v_completed_at;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_manual_close', wacrm_current_actor(),
          v_motivo, jsonb_build_object('status', v_status_before),
          jsonb_build_object('status', 'completed', 'delivery_mode', 'closed_manually', 'notify', p_notify)
            || CASE WHEN p_delivery_method IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('delivery_method', p_delivery_method) END
            -- (249) A change of service is visible in the audit row.
            || CASE WHEN v_service_after IS DISTINCT FROM v_service_before
                    THEN jsonb_build_object('service_type', v_service_after, 'service_type_before', v_service_before)
                    ELSE '{}'::jsonb END);

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;
REVOKE ALL ON FUNCTION public.crm_cerrar_operacion_manual(uuid, text, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_cerrar_operacion_manual(uuid, text, boolean, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.crm_inventario_cup_operacion(p_operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op       remittance_operations;
  v_day      date := cup_cuba_day(now());
  v_n_cup    integer;
  v_total    numeric;
  v_planned  numeric;
  v_usdt     numeric;
  v_bens     jsonb;
  v_lines    jsonb;
  v_consumed numeric;
  v_rate     numeric;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_op.account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to read the CUP plan of this operation' USING ERRCODE = '42501';
  END IF;

  IF v_op.status = 'cancelled' THEN
    RETURN jsonb_build_object('state', 'unavailable', 'operation_id', v_op.id);
  END IF;

  SELECT count(*) INTO v_n_cup FROM remittance_beneficiaries b
   WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND calculator_service_for_operation(b.beneficiary_type) = 'CUP';

  -- ---- completed: what really left, from the consumptions linked to the operation or to its entries ----------------------------
  IF v_op.status = 'completed' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'card_id', c.id, 'card_name', c.name, 'last4', c.last4, 'lot_id', l.id,
             'amount_cup', k.amount_cup, 'lot_rate', l.rate_cup_per_usdt, 'consumed_at', k.consumed_at) ORDER BY k.consumed_at, k.id), '[]'::jsonb),
           coalesce(sum(k.amount_cup), 0)
      INTO v_lines, v_consumed
      FROM cup_lot_consumptions k
      JOIN cup_cards c ON c.id = k.card_id
      JOIN cup_lots l ON l.id = k.lot_id
     WHERE k.account_id = v_op.account_id
       AND (k.operation_id = v_op.id
            OR k.calculator_entry_id IN (SELECT e.id FROM remittance_calculator_entries e WHERE e.operation_id = v_op.id));
    IF v_consumed = 0 AND v_n_cup = 0 THEN
      RETURN jsonb_build_object('state', 'not_cup', 'operation_id', v_op.id);
    END IF;
    SELECT e.cup_rate INTO v_rate
      FROM remittance_calculator_entries e
     WHERE e.operation_id = v_op.id AND e.account_id = v_op.account_id AND e.service = 'CUP' AND e.source = 'completed_operation'
       AND e.status <> 'void' AND e.deleted_at IS NULL
     ORDER BY e.created_at DESC, e.id LIMIT 1;
    RETURN jsonb_build_object('state', 'completed', 'operation_id', v_op.id, 'estimate', false,
                              'consumed_cup', v_consumed, 'cup_rate', v_rate, 'lines', v_lines);
  END IF;

  -- ---- not completed: the plan --------------------------------------------------------------------------------------------------
  IF v_n_cup = 0 THEN
    RETURN jsonb_build_object('state', 'not_cup', 'operation_id', v_op.id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cup_cards c WHERE c.account_id = v_op.account_id AND c.active) THEN
    RETURN jsonb_build_object('state', 'no_inventory', 'operation_id', v_op.id);
  END IF;

  -- One statement: the CUP beneficiaries in position order with the CUP each receives (a lone CUP beneficiary without an amount takes the
  -- quoted CUP), ONE plan for their total from the shared allocator, and the plan cut per beneficiary by cumulative ranges (the same greedy
  -- fill as consuming the total at once: the first beneficiary takes the first part of the plan, and so on).
  WITH ben AS (
    SELECT b.id, b."position" AS pos, b.created_at, b.name,
           CASE WHEN b.amount > 0 AND coalesce(b.currency, 'CUP') = 'CUP' THEN b.amount
                WHEN v_n_cup = 1 AND v_op.destination_currency = 'CUP' AND v_op.quoted_destination_amount > 0
                  THEN v_op.quoted_destination_amount END AS amt
      FROM remittance_beneficiaries b
     WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND calculator_service_for_operation(b.beneficiary_type) = 'CUP'
  ), bens AS (
    SELECT x.*, sum(x.amt) OVER (ORDER BY x.pos, x.created_at, x.id) - x.amt AS s, sum(x.amt) OVER (ORDER BY x.pos, x.created_at, x.id) AS e
      FROM ben x WHERE x.amt IS NOT NULL
  ), tot AS (
    SELECT coalesce(sum(x.amt), 0) AS t FROM bens x
  ), parts AS (
    SELECT p.seq, p.card_id, p.lot_id, p.amount_cup, p.lot_rate,
           sum(p.amount_cup) OVER (ORDER BY p.seq) - p.amount_cup AS ps, sum(p.amount_cup) OVER (ORDER BY p.seq) AS pe
      FROM tot, cup_planificar(v_op.account_id, tot.t, v_day) p
  )
  SELECT (SELECT t FROM tot),
         (SELECT coalesce(sum(p.amount_cup), 0) FROM parts p),
         (SELECT coalesce(sum(p.amount_cup / p.lot_rate), 0) FROM parts p),
         (SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'beneficiary_id', bn.id, 'position', bn.pos, 'name', bn.name, 'amount_cup', bn.amt,
                   'missing_cup', bn.amt - coalesce(ln.placed, 0),
                   'lines', coalesce(ln.lines, '[]'::jsonb)) ORDER BY bn.pos, bn.created_at, bn.id), '[]'::jsonb)
            FROM bens bn
            LEFT JOIN LATERAL (
              SELECT sum(least(p.pe, bn.e) - greatest(p.ps, bn.s)) AS placed,
                     jsonb_agg(jsonb_build_object(
                       'card_id', c.id, 'card_name', c.name, 'last4', c.last4, 'lot_id', p.lot_id,
                       'amount_cup', least(p.pe, bn.e) - greatest(p.ps, bn.s), 'lot_rate', p.lot_rate) ORDER BY p.seq) AS lines
                FROM parts p JOIN cup_cards c ON c.id = p.card_id
               WHERE p.pe > bn.s AND p.ps < bn.e
            ) ln ON true)
    INTO v_total, v_planned, v_usdt, v_bens;

  IF v_total = 0 THEN
    RETURN jsonb_build_object('state', 'no_amounts', 'operation_id', v_op.id);
  END IF;

  RETURN jsonb_build_object('state', 'plan', 'operation_id', v_op.id, 'estimate', true, 'cuba_day', v_day,
                            'total_cup', v_total, 'planned_cup', v_planned, 'missing_cup', v_total - v_planned,
                            'effective_rate', CASE WHEN v_planned > 0 THEN v_planned / v_usdt END,
                            'beneficiaries', v_bens);
END;
$function$;
REVOKE ALL ON FUNCTION public.crm_inventario_cup_operacion(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.crm_inventario_cup_operacion(uuid) TO authenticated;
COMMENT ON FUNCTION public.crm_inventario_cup_operacion(uuid) IS '(241) Agent+ of the operation''s account. Delivery panel: estimated CUP plan per beneficiary (not completed) or the consumptions of a completed CUP operation; card name + last4 only.';

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
  v_cup_rate  numeric;   -- (240) CUP chat line: the rate the consumed lots cost, combined with the global rate for any shortfall
  v_cup_done  boolean;   -- (240) CUP was taken from the inventory for this part and still has to be linked to its entry
  v_inv       record;
  v_rcost     numeric;   -- (242) USDT cost of ONE recharge of this line, by its promotion tier
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
  SELECT z.tasa INTO v_zrate FROM cerebro_zelle_cotizar_op(v_op.id, v_op.quoted_source_amount) z;

  SELECT c.name INTO v_customer
    FROM conversations conv JOIN contacts c ON c.id = conv.contact_id
   WHERE conv.id = v_op.conversation_id;

  FOR v_part IN SELECT * FROM calculator_operation_parts(v_op, v_rates) LOOP
    v_basis     := v_part.basis;
    v_amount    := NULL;
    v_facturado := NULL;
    v_invertido := NULL;
    v_cup_rate  := NULL;
    v_cup_done  := false;
    v_missing   := calculator_missing_rates(v_part.service, v_rates) || coalesce(v_part.missing, ARRAY[]::text[]);
    -- (199) a recharge whose deposit matches no recharge price cannot be priced
    IF v_part.service = 'RECARGA' AND cerebro_recarga_precio(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['recargaPrecioGyd'];
    END IF;
    -- (223) a mobile balance whose deposit is not a whole number of packages cannot be priced: no silent rounding
    IF v_part.service = 'SALDO_MOVIL' AND cerebro_saldo_paquetes(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['saldoPaquetes'];
    END IF;
    -- (209) a combo whose cost the admin has not entered yet stays pending
    IF v_part.service = 'COMBO' AND v_op.combo_costo_gyd IS NULL THEN
      v_missing := v_missing || ARRAY['comboCosto'];
    END IF;
    v_currency  := CASE WHEN v_part.service = 'CUP' THEN 'CUP' WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN 'REC'
                        WHEN v_part.service IN ('COMBO', 'VISA') THEN 'GYD' ELSE 'USD' END;
    -- (193) The sale rate of the line: a cash dollar sells at efectivo_usd_gyd; every other USD service at
    -- usdt_sell_gyd. The cost (usdt_buy_gyd) is shared. Snapshotted in usdt_sell_gyd (= the sale rate used).
    v_sell      := CASE WHEN v_part.service = 'EFECTIVO' THEN v_rates.efectivo_usd_gyd
                        -- (199) a recharge sells at the price its deposit pays (198 cerebro_recarga_precio)
                        WHEN v_part.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis)
                        -- (223) a mobile balance sells at the package price (cerebro_saldo_precio)
                        WHEN v_part.service = 'SALDO_MOVIL' THEN cerebro_saldo_precio()
                        -- (215) Zelle: tiered (still pending while the calculator has no sell rate); Clasica, Tropical and the rest keep usdt_sell_gyd
                        WHEN v_part.service = 'ZELLE' AND v_rates.usdt_sell_gyd IS NOT NULL THEN coalesce(v_zrate, v_rates.usdt_sell_gyd)
                        ELSE v_rates.usdt_sell_gyd END;

    -- (242) A recharge is costed by the promotion tier of its price: the precio_recarga row the price belongs to (min_cup 500 = "starts
    -- at 500 CUP", 5,200 GYD; min_cup 600 = 6,200 GYD). The 500 tier takes recarga_costo_usdt_500; every other tier (600 and any
    -- future one) and a 500 tier whose rate is not set yet keep recarga_costo_usdt, i.e. the behaviour before 242.
    v_rcost := v_rates.recarga_costo_usdt;
    IF v_part.service = 'RECARGA' AND v_rates.recarga_costo_usdt_500 IS NOT NULL
       AND (SELECT min(r.min_cup) FROM precio_recarga r WHERE r.precio_gyd = v_sell) = 500 THEN
      v_rcost := v_rates.recarga_costo_usdt_500;
    END IF;

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
      -- (235) facturado is the money that came in for this line (its GYD share of the operation: v_basis), not delivered units x price.
      -- The rounding leftover of a dollar rail (deposit - floor(deposit / price) x price, always below one price unit) is therefore
      -- billed and, since invertido (what the delivery costs) is untouched, lands in retorno. Where facturado already was the deposit
      -- (CUP, recarga, saldo: amount x price = basis exactly) nothing changes. A line still pending keeps NULL.
      IF v_facturado IS NOT NULL THEN
        v_facturado := v_basis;
      END IF;
      v_invertido := CASE WHEN v_part.service = 'RECARGA'
                          -- (199) units x USDT cost per recharge x USDT buy rate (the guide's "rec promo" line); (242) cost by tier
                          THEN v_amount * v_rcost * v_rates.usdt_buy_gyd
                          -- (223) packages x USDT cost per package x USDT buy rate
                          WHEN v_part.service = 'SALDO_MOVIL' THEN v_amount * v_rates.saldo_costo_usdt * v_rates.usdt_buy_gyd
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

    -- (223) The amount of a mobile balance line is the saldo itself (packages x saldo per package) in 'SM'; without an exact
    -- package count there is no saldo to show, so the raw deposit stays, labelled GYD (never SM). facturado/invertido
    -- above were already computed from the package count.
    IF v_part.service = 'SALDO_MOVIL' THEN
      IF cerebro_saldo_paquetes(v_basis) IS NOT NULL THEN
        v_amount   := cerebro_saldo_paquetes(v_basis) * cerebro_saldo_unidad();
        v_currency := 'SM';
      ELSE
        v_currency := 'GYD';
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

    -- (240) CUP inventory. A CUP chat line that is about to be WRITTEN (no live or deliberately deleted row exists for this
    -- operation: a fresh insert or the revival of a void row) and is fully priced takes its CUP from the owner's sending cards
    -- (cup_consumir: cards by priority, lots FIFO, daily limit per Cuba day, split across cards). The line's cup_rate becomes
    -- amount / (consumed / lot-rate + shortfall / global usdt_sell_cup), so invertido = amount / cup_rate * usdt_buy_gyd is
    -- exactly what that CUP cost. Consumption happens BEFORE the insert so no completed row is ever updated (149 guard untouched)
    -- and is linked to the entry right after it. A re-feed of a live line never gets here (no double consumption). Any failure
    -- of the inventory part is caught HERE (its own subtransaction rolls back what it did): the line keeps the global rate and a
    -- notification is raised, so the feed (and the delivery behind it) is never aborted and an inventory failure is never silent.
    IF v_part.service = 'CUP' AND coalesce(array_length(v_missing, 1), 0) = 0 AND v_facturado IS NOT NULL AND v_amount > 0
       AND NOT EXISTS (SELECT 1 FROM remittance_calculator_entries e
                        WHERE e.account_id = v_op.account_id AND e.operation_id = v_op.id AND e.source = 'completed_operation'
                          AND e.service = 'CUP' AND (e.status <> 'void' OR e.deleted_at IS NOT NULL))
    THEN
      v_cup_done := true;
      BEGIN
        SELECT * INTO v_inv
          FROM cup_consumir(v_op.account_id, v_amount, NULL, v_op.id, coalesce(v_op.completed_at, clock_timestamp()),
                            cup_cuba_day(coalesce(v_op.completed_at, clock_timestamp())));
        IF v_inv.missing_cup > 0 THEN
          PERFORM cup_alertar(v_op.account_id, v_op.id, 'Inventario CUP insuficiente',
            format('La operacion de %s no se cubrio por completo con el inventario CUP: faltan %s CUP (limite diario o saldo agotado). '
                   'Esa parte usa la tasa global. Revise las tarjetas y lotes en Inventario CUP.',
                   coalesce(v_customer, 'un cliente'), to_char(v_inv.missing_cup, 'FM999G999G999G990')));
        END IF;
        IF v_inv.consumed_cup > 0 THEN
          v_cup_rate  := v_amount / (v_inv.consumed_cup / v_inv.effective_rate + v_inv.missing_cup / v_rates.usdt_sell_cup);
          v_invertido := calculator_invertido('CUP', v_amount, v_cup_rate, v_rates.usdt_buy_gyd);
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_cup_rate := NULL;
        v_cup_done := false;
        PERFORM cup_alertar(v_op.account_id, v_op.id, 'Error en el inventario CUP',
          format('No se pudo descontar el inventario CUP de la operacion de %s (%s). La linea quedo con la tasa global; revise el inventario.',
                 coalesce(v_customer, 'un cliente'), left(SQLERRM, 200)));
      END;
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
           WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN v_rates.usdt_buy_gyd
           -- (240) a CUP line taken from the inventory snapshots the combined lot rate
           WHEN v_part.service = 'CUP' AND v_cup_rate IS NOT NULL THEN v_cup_rate ELSE v_rates.usdt_sell_cup END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_rates.usdt_buy_gyd END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_sell END, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp()),
      CASE WHEN v_part.service = 'RECARGA' THEN v_rcost
           WHEN v_part.service = 'SALDO_MOVIL' THEN v_rates.saldo_costo_usdt
           WHEN v_part.service = 'COMBO' THEN v_op.combo_costo_gyd
           WHEN v_part.service = 'VISA' THEN 0 END,
      CASE WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN v_sell
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
    -- (226) a row the admin deleted on purpose (deleted_at) is never revived: only a reverted operation's void row is
    WHERE remittance_calculator_entries.status = 'void'
      AND remittance_calculator_entries.deleted_at IS NULL
    RETURNING id INTO v_entry_id;

    -- (240) link the CUP taken above to the line it priced (or give it back if, against expectation, no row was written)
    IF v_cup_done THEN
      IF v_entry_id IS NOT NULL THEN
        UPDATE cup_lot_consumptions SET calculator_entry_id = v_entry_id
         WHERE account_id = v_op.account_id AND operation_id = v_op.id AND calculator_entry_id IS NULL;
      ELSE
        PERFORM cup_devolver(NULL, v_op.id);
      END IF;
    END IF;

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cup_planificar(p_account_id uuid, p_amount_cup numeric, p_cuba_day date)
 RETURNS TABLE(seq integer, card_id uuid, lot_id uuid, amount_cup numeric, lot_rate numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_card   cup_cards;
  v_lot    cup_lots;
  v_left   numeric;
  v_room   numeric;
  v_take   numeric;
  v_seq    integer := 0;
BEGIN
  IF p_account_id IS NULL OR p_amount_cup IS NULL OR p_amount_cup <= 0 THEN
    RETURN;
  END IF;

  v_left := p_amount_cup;
  FOR v_card IN
    SELECT c.* FROM cup_cards c WHERE c.account_id = p_account_id AND c.active ORDER BY c.priority, c.created_at, c.id
  LOOP
    EXIT WHEN v_left <= 0;
    SELECT greatest(v_card.daily_limit_cup - coalesce(sum(k.amount_cup), 0), 0) INTO v_room
      FROM cup_lot_consumptions k WHERE k.card_id = v_card.id AND k.cuba_day = p_cuba_day AND k.kind <> 'ajuste';
    v_room := least(v_room, v_left);
    FOR v_lot IN
      SELECT l.* FROM cup_lots l WHERE l.card_id = v_card.id AND l.remaining_cup > 0 ORDER BY l.loaded_at, l.created_at, l.id
    LOOP
      EXIT WHEN v_room <= 0;
      v_take := least(v_lot.remaining_cup, v_room);
      v_seq := v_seq + 1;
      seq := v_seq; card_id := v_card.id; lot_id := v_lot.id; amount_cup := v_take; lot_rate := v_lot.rate_cup_per_usdt;
      RETURN NEXT;
      v_room := v_room - v_take;
      v_left := v_left - v_take;
    END LOOP;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cup_consumir(p_account_id uuid, p_amount_cup numeric, p_entry_id uuid, p_operation_id uuid, p_at timestamp with time zone, p_cuba_day date)
 RETURNS TABLE(consumed_cup numeric, missing_cup numeric, effective_rate numeric, parts jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_part     record;
  v_day      date;
  v_at       timestamptz := coalesce(p_at, clock_timestamp());
  v_consumed numeric := 0;
  v_usdt     numeric := 0;
  v_parts    jsonb := '[]'::jsonb;
  v_kind     text := 'operacion';
BEGIN
  IF p_account_id IS NULL OR p_amount_cup IS NULL OR p_amount_cup <= 0 THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric, NULL::numeric, '[]'::jsonb;
    RETURN;
  END IF;
  v_day := coalesce(p_cuba_day, cup_cuba_day(v_at));

  -- (256) the kind of what this call writes: a manual Calculator line, else a chat / CRM operation.
  IF p_entry_id IS NOT NULL AND EXISTS (SELECT 1 FROM remittance_calculator_entries e WHERE e.id = p_entry_id AND e.source = 'manual') THEN
    v_kind := 'manual';
  END IF;

  -- lock order: calculator-cut (callers that hold it) -> cup-inventory. Same key as the 239 admin RPCs.
  PERFORM pg_advisory_xact_lock(hashtextextended('cup-inventory:' || p_account_id::text, 0));

  -- Idempotent: what already stands for this entry (or operation, before its entry exists) is reported, not taken again.
  SELECT coalesce(sum(k.amount_cup), 0), coalesce(sum(k.amount_cup / l.rate_cup_per_usdt), 0),
         coalesce(jsonb_agg(jsonb_build_object('card_id', k.card_id, 'lot_id', k.lot_id, 'amount_cup', k.amount_cup,
                                               'rate_cup_per_usdt', l.rate_cup_per_usdt) ORDER BY k.consumed_at, k.id), '[]'::jsonb)
    INTO v_consumed, v_usdt, v_parts
    FROM cup_lot_consumptions k JOIN cup_lots l ON l.id = k.lot_id
   WHERE k.account_id = p_account_id
     AND ((p_entry_id IS NOT NULL AND k.calculator_entry_id = p_entry_id)
          OR (p_operation_id IS NOT NULL AND k.operation_id = p_operation_id));
  IF v_consumed > 0 THEN
    RETURN QUERY SELECT v_consumed, greatest(p_amount_cup - v_consumed, 0::numeric), v_consumed / v_usdt, v_parts;
    RETURN;
  END IF;

  -- (241) the split is decided by the shared allocator; this function only writes it.
  FOR v_part IN SELECT * FROM cup_planificar(p_account_id, p_amount_cup, v_day) ORDER BY seq
  LOOP
    PERFORM 1 FROM cup_lots WHERE id = v_part.lot_id FOR UPDATE;
    INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, calculator_entry_id, operation_id, amount_cup, consumed_at, cuba_day, kind)
    VALUES (p_account_id, v_part.lot_id, v_part.card_id, p_entry_id, p_operation_id, v_part.amount_cup, v_at, v_day, v_kind);
    UPDATE cup_lots SET remaining_cup = remaining_cup - v_part.amount_cup WHERE id = v_part.lot_id;
    v_consumed := v_consumed + v_part.amount_cup;
    v_usdt := v_usdt + v_part.amount_cup / v_part.lot_rate;
    v_parts := v_parts || jsonb_build_object('card_id', v_part.card_id, 'lot_id', v_part.lot_id, 'amount_cup', v_part.amount_cup,
                                             'rate_cup_per_usdt', v_part.lot_rate);
  END LOOP;

  RETURN QUERY SELECT v_consumed, greatest(p_amount_cup - v_consumed, 0::numeric),
                      CASE WHEN v_consumed > 0 THEN v_consumed / v_usdt END, v_parts;
END;
$function$;

DROP FUNCTION IF EXISTS public.cup_consumir(uuid, numeric, uuid, uuid, timestamptz, date, uuid);
DROP FUNCTION IF EXISTS public.cup_planificar(uuid, numeric, date, uuid);
DROP FUNCTION IF EXISTS public.cup_validar_tarjeta_origen(uuid, uuid);

DROP INDEX IF EXISTS public.remittance_operations_cup_source_card_idx;
ALTER TABLE public.remittance_operations DROP COLUMN IF EXISTS cup_source_card_id;
