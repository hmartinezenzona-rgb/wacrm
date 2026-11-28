-- 340 -- Each card recipient ends on the operation of its own rail.
-- A card reparto saved on ONE operation (Clasica + Tropical, or Clasica + CUP)
-- left the second rail's recipients on the first rail's operation: the split
-- reused the operation for the first rail and created a new one for the
-- second, with no recipients. After the split, the rail-typed card rows
-- (multiple_distribution -> cuban_card, clasica, tropical) move to the group
-- member of their rail, duplicates on the target are dropped, and both
-- destinations are recomputed. Everything else stays untouched.

CREATE OR REPLACE FUNCTION public._repartir_envio_core(p_operation_id uuid, p_partes jsonb, p_audit_action text, p_actor text, p_reason text, p_parcial boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_services   constant text[] := ARRAY['cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo', 'mexico'];
  v_op         remittance_operations%ROWTYPE;
  v_anchor     remittance_operations%ROWTYPE;
  v_anchor_id  uuid;
  v_anchor_key text;
  v_el         jsonb;
  v_keys       text[] := ARRAY[]::text[];
  v_amts       numeric[] := ARRAY[]::numeric[];
  v_total      numeric;
  v_sum        numeric := 0;
  v_member     record;
  v_i          integer;
  v_key        text;
  v_target     uuid;
  v_created    boolean;
  v_type       text;
  v_dm         text;
  v_before     remittance_operations%ROWTYPE;
  v_mv_b record; v_mv_rail text; v_mv_target uuid; v_mv_pos integer;
  v_dsum numeric; v_dcur text; v_dnull integer; v_dncur integer;
  v_after      remittance_operations%ROWTYPE;
  v_b_sum      numeric; v_b_cur text; v_b_null integer; v_b_ncur integer;
  v_ids        uuid[] := ARRAY[]::uuid[];
  v_new        boolean[] := ARRAY[]::boolean[];
  v_obj        numeric;
  v_dep        numeric;
  v_saldo      numeric;
  v_partes     jsonb := '[]'::jsonb;
  v_dep0       numeric;
  v_min        numeric;
  v_single     boolean := false;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  -- The anchor is the group's anchor when the operation is already a member, else the operation itself.
  v_anchor_id := COALESCE(v_op.mixed_group_id, v_op.id);
  SELECT * INTO v_anchor FROM remittance_operations WHERE id = v_anchor_id FOR UPDATE;
  PERFORM 1 FROM remittance_operations WHERE mixed_group_id = v_anchor_id ORDER BY id FOR UPDATE;

  IF v_anchor.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  -- Parts: an array of at least two {servicio, monto_gyd}, distinct services, positive amounts.
  IF p_partes IS NULL OR jsonb_typeof(p_partes) <> 'array' OR jsonb_array_length(p_partes) < (2 - p_parcial::int) THEN
    RAISE EXCEPTION 'at least two parts are required' USING ERRCODE = '22023';
  END IF;
  FOR v_el IN SELECT * FROM jsonb_array_elements(p_partes) LOOP
    IF jsonb_typeof(v_el) <> 'object' OR jsonb_typeof(v_el -> 'servicio') <> 'string'
       OR jsonb_typeof(v_el -> 'monto_gyd') <> 'number' THEN
      RAISE EXCEPTION 'each part needs a servicio (text) and a monto_gyd (number)' USING ERRCODE = '22023';
    END IF;
    v_key := lower(btrim(v_el ->> 'servicio'));
    IF NOT (v_key = ANY (v_services)) THEN
      RAISE EXCEPTION 'unknown service: %', v_el ->> 'servicio' USING ERRCODE = '22023';
    END IF;
    IF v_key = ANY (v_keys) THEN
      RAISE EXCEPTION 'service % appears more than once', v_key USING ERRCODE = '22023';
    END IF;
    IF (v_el ->> 'monto_gyd')::numeric <= 0 THEN
      RAISE EXCEPTION 'every part must be greater than 0' USING ERRCODE = '22023';
    END IF;
    v_keys := v_keys || v_key;
    v_amts := v_amts || (v_el ->> 'monto_gyd')::numeric;
    v_sum  := v_sum + (v_el ->> 'monto_gyd')::numeric;
  END LOOP;

  -- The money being split: the group's total (non-cancelled members), or the lone operation's own amount.
  IF v_op.mixed_group_id IS NOT NULL THEN
    SELECT sum(quoted_source_amount) INTO v_total
      FROM remittance_operations WHERE mixed_group_id = v_anchor_id AND status <> 'cancelled';
  ELSE
    v_total := v_anchor.quoted_source_amount;
  END IF;
  IF p_parcial THEN
    -- (280) Partial deposit: the parts are the ones to apply now. They must fit inside the verified deposit; the rest of the plan stays pending.
    SELECT s.depositado INTO v_dep0 FROM cerebro_saldo_operacion(v_anchor_id) s;
    IF COALESCE(v_dep0, 0) <= 0 THEN
      RAISE EXCEPTION 'there is no verified deposit to cover the parts' USING ERRCODE = '22023';
    END IF;
    IF v_sum > v_dep0 THEN
      RAISE EXCEPTION 'the parts add up to % but the verified deposit is only %', v_sum, v_dep0 USING ERRCODE = '22023';
    END IF;
    v_single := array_length(v_keys, 1) = 1;
  ELSE
    IF v_total IS NULL OR v_total <= 0 THEN
      RAISE EXCEPTION 'there is no money to split: the total is %', COALESCE(v_total::text, 'empty') USING ERRCODE = '22023';
    END IF;
    IF v_sum <> v_total THEN
      RAISE EXCEPTION 'the parts add up to % but the total to split is %', v_sum, v_total USING ERRCODE = '22023';
    END IF;
  END IF;

  -- The anchor's own service must be one of the parts.
  v_anchor_key := cerebro_riel_op(v_anchor_id);
  IF v_anchor_key IS NULL OR NOT (v_anchor_key = ANY (v_keys)) THEN
    RAISE EXCEPTION 'the operation''s own service (%) must be one of the parts', COALESCE(v_anchor_key, 'unknown') USING ERRCODE = '22023';
  END IF;

  -- Every open member of the group needs its part; a completed member cannot be re-priced.
  FOR v_member IN SELECT id, status FROM remittance_operations
                   WHERE mixed_group_id = v_anchor_id AND status <> 'cancelled' LOOP
    IF v_member.status = 'completed' THEN
      RAISE EXCEPTION 'group member % is completed and cannot be re-split', v_member.id USING ERRCODE = '22023';
    END IF;
    IF NOT (COALESCE(cerebro_riel_op(v_member.id), '') = ANY (v_keys)) THEN
      RAISE EXCEPTION 'group member % (service %) has no part', v_member.id, cerebro_riel_op(v_member.id) USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF (SELECT count(*) - count(DISTINCT cerebro_riel_op(id)) FROM remittance_operations
       WHERE mixed_group_id = v_anchor_id AND status <> 'cancelled') > 0 THEN
    RAISE EXCEPTION 'two group members share one service' USING ERRCODE = '22023';
  END IF;

  FOR v_i IN 1 .. array_length(v_keys, 1) LOOP
    v_key := v_keys[v_i];
    v_created := false;

    IF v_key = v_anchor_key THEN
      v_target := v_anchor_id;
    ELSE
      -- An open operation of that service in the conversation, not in another group: the group's own first, then the newest.
      -- An ungrouped one that already holds money of its own (a deposit or a receipt) is never reused: its money would
      -- join the group and be re-priced. A fresh operation is created instead.
      SELECT o.id INTO v_target
        FROM remittance_operations o
       WHERE o.conversation_id = v_anchor.conversation_id
         AND o.status NOT IN ('completed', 'cancelled')
         AND (o.mixed_group_id = v_anchor_id
              OR (o.mixed_group_id IS NULL
                  AND NOT EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.anulado_en IS NULL)
                  AND NOT EXISTS (SELECT 1 FROM remittance_operation_receipts rr WHERE rr.operation_id = o.id)))
         AND (cerebro_riel_op(o.id) = v_key
              OR (v_key = 'cuban_card' AND cerebro_riel_op(o.id) = 'multiple_distribution'))
       ORDER BY (o.mixed_group_id IS NOT NULL) DESC, o.created_at DESC
       LIMIT 1
       FOR UPDATE;

      IF v_target IS NULL THEN
        -- Same mapping as _cambiar_servicio_core; the destination amount and currency come from the calculation.
        v_type := CASE WHEN v_key IN ('recarga', 'combo', 'visa', 'saldo', 'mexico') THEN v_key ELSE 'remesa' END;
        v_dm   := CASE WHEN v_type = 'remesa' THEN v_key END;
        INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                           deposit_method, source_country, source_currency, destination_currency)
        VALUES (v_anchor.account_id, v_anchor.conversation_id, v_anchor.contact_id, 'collecting_information', v_type, v_dm,
                v_anchor.deposit_method, v_anchor.source_country, v_anchor.source_currency,
                CASE WHEN v_type = 'mexico' THEN 'MXN' END)
        RETURNING id INTO v_target;
        v_created := true;
      END IF;
    END IF;

    SELECT * INTO v_before FROM remittance_operations WHERE id = v_target;

    -- (280) every part sent in a partial application must reach the minimum of its service.
    IF p_parcial THEN
      v_min := cerebro_minimo_gyd(v_target);
      IF v_min IS NOT NULL AND v_amts[v_i] < v_min THEN
        RAISE EXCEPTION 'part % (%) is below its minimum of %', v_key, v_amts[v_i], v_min USING ERRCODE = '22023';
      END IF;
    END IF;

    -- The share is written by a human, so the 096 guard locks quoted_source_amount; the explicit lock covers an
    -- unchanged amount. The remesa recalculation then writes the destination as a human too: release those locks unless
    -- an earlier correction had set them.
    UPDATE remittance_operations
       SET quoted_source_amount = v_amts[v_i],
           mixed_group_id = CASE WHEN v_single THEN v_op.mixed_group_id ELSE v_anchor_id END,
           admin_locked_fields = COALESCE(admin_locked_fields, '{}'::jsonb)
             || jsonb_build_object('quoted_source_amount', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
     WHERE id = v_target;

    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields
             - CASE WHEN v_before.admin_locked_fields ? 'quoted_destination_amount' THEN '' ELSE 'quoted_destination_amount' END
             - CASE WHEN v_before.admin_locked_fields ? 'destination_currency' THEN '' ELSE 'destination_currency' END
     WHERE id = v_target
       AND admin_locked_fields ?| ARRAY['quoted_destination_amount', 'destination_currency'];

    -- (338) Show each part's destination total when its recipients already carry
    -- their amounts in one currency (the CUP reparto operation leaves it empty).
    -- Never overwrite an admin lock.
    SELECT sum(b.amount), min(b.currency),
           count(*) FILTER (WHERE b.amount IS NULL), count(DISTINCT b.currency)
      INTO v_b_sum, v_b_cur, v_b_null, v_b_ncur
      FROM remittance_beneficiaries b
     WHERE b.operation_id = v_target AND b.status = 'vigente';
    IF coalesce(v_b_sum, 0) > 0 AND v_b_null = 0 AND v_b_ncur = 1 AND v_b_cur IS NOT NULL THEN
      UPDATE remittance_operations
         SET quoted_destination_amount = v_b_sum,
             destination_currency = v_b_cur
       WHERE id = v_target
         AND quoted_destination_amount IS NULL
         AND NOT (coalesce(admin_locked_fields, '{}'::jsonb) ? 'quoted_destination_amount');
    END IF;

    SELECT * INTO v_after FROM remittance_operations WHERE id = v_target;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_after.account_id, 'remittance_operations', v_target, 'mixed_split', p_audit_action,
            p_actor, p_reason,
            jsonb_build_object('quoted_source_amount', v_before.quoted_source_amount, 'mixed_group_id', v_before.mixed_group_id),
            jsonb_build_object('quoted_source_amount', v_after.quoted_source_amount, 'mixed_group_id', v_after.mixed_group_id,
                               'service', v_key, 'created', v_created));

    v_ids := v_ids || v_target;
    v_new := v_new || v_created;
  END LOOP;

  -- (340) Every card recipient lives on the operation of its own rail: a card
  -- reparto saved on ONE operation (Clasica + Tropical, or Clasica + CUP) is
  -- spread over the group members the split just created, so each part keeps
  -- its own recipients. Only the rail-typed card rows move; everything else
  -- stays. The destination total of both sides is recomputed afterwards.
  FOR v_mv_b IN
    SELECT b.id, b.operation_id, b.beneficiary_type
      FROM remittance_beneficiaries b
      JOIN remittance_operations o ON o.id = b.operation_id
     WHERE o.mixed_group_id = v_anchor_id AND b.status = 'vigente'
       AND b.beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical')
  LOOP
    v_mv_rail := CASE v_mv_b.beneficiary_type
                   WHEN 'multiple_distribution' THEN 'cuban_card'
                   ELSE v_mv_b.beneficiary_type END;
    CONTINUE WHEN cerebro_riel_op(v_mv_b.operation_id) = v_mv_rail;
    SELECT o2.id INTO v_mv_target
      FROM remittance_operations o2
     WHERE o2.mixed_group_id = v_anchor_id
       AND o2.id <> v_mv_b.operation_id
       AND cerebro_riel_op(o2.id) = v_mv_rail
     ORDER BY o2.created_at, o2.id LIMIT 1;
    CONTINUE WHEN v_mv_target IS NULL;
    -- the same card already sits on the target: drop this duplicate instead of moving it
    IF EXISTS (SELECT 1 FROM remittance_beneficiaries x
                WHERE x.operation_id = v_mv_target AND x.status = 'vigente'
                  AND x.beneficiary_type = v_mv_b.beneficiary_type
                  AND x.card_number IS NOT NULL
                  AND x.card_number = (SELECT y.card_number FROM remittance_beneficiaries y WHERE y.id = v_mv_b.id)) THEN
      UPDATE remittance_beneficiaries SET status = 'reemplazado', replaced_at = now() WHERE id = v_mv_b.id;
      CONTINUE;
    END IF;
    SELECT coalesce(max(position), 0) + 1 INTO v_mv_pos
      FROM remittance_beneficiaries WHERE operation_id = v_mv_target AND status = 'vigente';
    UPDATE remittance_beneficiaries
       SET operation_id = v_mv_target, position = v_mv_pos
     WHERE id = v_mv_b.id;
  END LOOP;

  -- Recompute the destination of every group member whose recipients all share
  -- one currency (the moved rows change the sums on both sides).
  FOR v_mv_target IN SELECT o3.id FROM remittance_operations o3 WHERE o3.mixed_group_id = v_anchor_id LOOP
    SELECT sum(b.amount), min(b.currency),
           count(*) FILTER (WHERE b.amount IS NULL), count(DISTINCT b.currency)
      INTO v_dsum, v_dcur, v_dnull, v_dncur
      FROM remittance_beneficiaries b
     WHERE b.operation_id = v_mv_target AND b.status = 'vigente';
    IF coalesce(v_dsum, 0) > 0 AND v_dnull = 0 AND v_dncur = 1 AND v_dcur IS NOT NULL THEN
      -- 338 wrote the destination with the split's automation actor, which locks
      -- the field; release only that lock (never a human's) so the new sum sticks.
      UPDATE remittance_operations
         SET admin_locked_fields = admin_locked_fields
               - CASE WHEN admin_locked_fields #>> '{quoted_destination_amount,by}' LIKE 'automation:%' THEN 'quoted_destination_amount' ELSE '' END
               - CASE WHEN admin_locked_fields #>> '{destination_currency,by}' LIKE 'automation:%' THEN 'destination_currency' ELSE '' END
       WHERE id = v_mv_target
         AND admin_locked_fields ?| ARRAY['quoted_destination_amount', 'destination_currency'];
      UPDATE remittance_operations
         SET quoted_destination_amount = v_dsum, destination_currency = v_dcur
       WHERE id = v_mv_target
         AND NOT (coalesce(admin_locked_fields, '{}'::jsonb) ? 'quoted_destination_amount');
    END IF;
  END LOOP;

  -- A fully deposited group is ready: every open member, with its objective closed.
  SELECT s.objetivo, s.depositado, s.saldo INTO v_obj, v_dep, v_saldo FROM cerebro_saldo_operacion(v_anchor_id) s;
  IF v_dep > 0 AND v_saldo = 0 THEN
    UPDATE remittance_operations
       SET status = 'ready_to_transfer', incident_reason = NULL, updated_at = now()
     WHERE mixed_group_id = v_anchor_id
       AND status IN ('incident', 'collecting_information', 'deposit_verification');
    FOR v_member IN SELECT id FROM remittance_operations WHERE mixed_group_id = v_anchor_id LOOP
      PERFORM cerebro_objetivo_cerrar_op(v_member.id);
    END LOOP;
  END IF;

  FOR v_i IN 1 .. array_length(v_ids, 1) LOOP
    SELECT * INTO v_after FROM remittance_operations WHERE id = v_ids[v_i];
    v_partes := v_partes || jsonb_build_object('operation_id', v_ids[v_i], 'servicio', v_keys[v_i], 'monto_gyd', v_amts[v_i],
                                                'creada', v_new[v_i], 'status', v_after.status);
  END LOOP;

  -- (331) The split is the instruction: the engine assigns the parts against the funding case.
  BEGIN
    PERFORM funding_reconciliar(v_anchor.conversation_id, 'automation:reparto');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'funding_reconciliar failed after split for conversation %: %', v_anchor.conversation_id, SQLERRM;
  END;

  RETURN jsonb_build_object('grupo', v_anchor_id, 'depositado', v_dep, 'saldo', v_saldo, 'partes', v_partes,
                            'parcial', p_parcial, 'asignado', v_sum,
                            'deposito_verificado', v_dep0,
                            'sobrante', CASE WHEN p_parcial THEN v_dep0 - v_sum END);
END $function$;

-- ROLLBACK: ROLLBACK-340-reparto-destinatarios-por-via.sql
