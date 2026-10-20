-- =====================================================================
-- 253 -- Mixed send: one deposit split across a group of operations
--
-- Production 2026-10-20 (conversation f8b7779c): the customer deposited 24,400 GYD for 18,200 GYD (70 USD Clasica) plus
-- 6,200 GYD (recarga). One receipt gets ONE service and ONE operation, so the Clasica operation took the whole 24,400
-- (93 USD), the cross-check saw 24,400 against the 18,200 quote ("verificado_de_mas" incident) and the recarga sat at 0.
--
-- Owner decision 2026-10-20: a GROUP of operations, each with ONE service, sharing one deposit.
--   * remittance_operations.mixed_group_id (uuid, NULL for every existing row): the id of the anchor operation (the one
--     that holds the deposit). The anchor points at itself. ON DELETE SET NULL.
--   * cerebro_saldo_operacion: for a grouped operation, objetivo = sum of the non-cancelled members' quoted_source_amount,
--     depositado = consumed, non-voided receipts tied to ANY member, the same values for every member. An ungrouped
--     operation runs the previous statement unchanged (same CTEs).
--   * crm_repartir_envio(p_operation_id, p_partes): redistributes the group's current total over services
--     ([{"servicio": <panel service key>, "monto_gyd": n}]). It never creates or loses money (parts must add up to the
--     total), maps each key to service_type / delivery_method exactly like _cambiar_servicio_core, reuses an open
--     operation of that service in the conversation or creates one, locks quoted_source_amount like a human correction
--     (096 guard), lets the calculated destination stay unlocked, writes one audit row per changed operation, and when
--     the group is fully deposited (saldo 0) readies every open member and closes their objectives.
--   * cerebro_cruzar_depositos: when the crossing settles a grouped operation (every receipt verified, saldo 0), the open
--     siblings get the same final status and their objectives are closed. Ungrouped: unchanged.
--
-- Bodies redefined from the LIVE staging text (pg_get_functiondef, 2026-10-20), changing only the cited parts. ACLs of the
-- two redefined functions are untouched by CREATE OR REPLACE; crm_repartir_envio gets the grants of crm_corregir_operacion.
-- Assertion: supabase/staging/assertions/mixed-send-split-deposit.sql. Rollback: ROLLBACK-253-mixed-send-split-deposit.sql.
-- odd/tasks/mixed-send-split-deposit.md (S1).
-- =====================================================================

ALTER TABLE public.remittance_operations
  ADD COLUMN IF NOT EXISTS mixed_group_id uuid REFERENCES public.remittance_operations(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS remittance_operations_mixed_group_idx
  ON public.remittance_operations (mixed_group_id) WHERE mixed_group_id IS NOT NULL;

COMMENT ON COLUMN public.remittance_operations.mixed_group_id IS
  'Mixed send: id of the anchor operation of a group sharing one deposit (the anchor points at itself). NULL = not grouped.';

-- (253) A grouped operation reads the whole group; the ungrouped statement (CTEs dep and obj) is the previous one.
CREATE OR REPLACE FUNCTION public.cerebro_saldo_operacion(p_op uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH dep AS (
    SELECT COALESCE(sum(m.monto), 0) AS total
      FROM depositos_mmg m
     WHERE m.operation_id = p_op
       AND m.consumido_en IS NOT NULL
       AND m.anulado_en  IS NULL
  ),
  obj AS (
    SELECT o.monto, o.moneda
      FROM cerebro_objetivo_envio o
     WHERE o.conversation_id = (SELECT ro.conversation_id
                                  FROM remittance_operations ro
                                 WHERE ro.id = p_op)
       AND o.cerrado_en IS NULL
       AND (o.operation_id IS NULL OR o.operation_id = p_op)
  ),
  grp AS (
    SELECT ro.mixed_group_id AS g FROM remittance_operations ro WHERE ro.id = p_op
  ),
  gobj AS (
    SELECT sum(ro.quoted_source_amount) AS monto
      FROM remittance_operations ro
     WHERE ro.mixed_group_id = (SELECT g FROM grp)
       AND ro.status <> 'cancelled'
  ),
  gdep AS (
    SELECT COALESCE(sum(m.monto), 0) AS total
      FROM depositos_mmg m
     WHERE m.operation_id IN (SELECT ro.id FROM remittance_operations ro
                               WHERE ro.mixed_group_id = (SELECT g FROM grp))
       AND m.consumido_en IS NOT NULL
       AND m.anulado_en  IS NULL
  )
  SELECT CASE WHEN (SELECT g FROM grp) IS NULL THEN (SELECT monto FROM obj) ELSE (SELECT monto FROM gobj) END,
         CASE WHEN (SELECT g FROM grp) IS NULL THEN (SELECT total FROM dep) ELSE (SELECT total FROM gdep) END,
         CASE WHEN (SELECT g FROM grp) IS NULL
              THEN (SELECT monto FROM obj) - (SELECT total FROM dep)
              ELSE (SELECT monto FROM gobj) - (SELECT total FROM gdep) END,
         CASE WHEN (SELECT g FROM grp) IS NULL THEN COALESCE((SELECT moneda FROM obj), 'GYD') ELSE 'GYD' END;
$function$;

-- (253) Sibling status when the crossing settles a group; everything else is the live body.
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
  v_grupo uuid;
BEGIN
  -- (160) Resolve either flavour.
  v_op_id := cerebro_resolve_op_id(p_deal);
  SELECT ro.mixed_group_id INTO v_grupo FROM remittance_operations ro WHERE ro.id = v_op_id;   -- (253)

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
      -- (253) The crossing settled a mixed-send group (the saldo is the group's): the open siblings take the same final
      -- status and their objectives are closed. An ungrouped operation has no siblings.
      IF v_grupo IS NOT NULL THEN
        UPDATE remittance_operations
           SET status = cerebro_estado_desde_etapa(v_stage_final),
               incident_reason = NULL,
               updated_at = now()
         WHERE mixed_group_id = v_grupo
           AND id <> v_op_id
           AND status IN ('collecting_information', 'deposit_verification', 'incident');
        PERFORM cerebro_objetivo_cerrar_op(m.id)
           FROM remittance_operations m
          WHERE m.mixed_group_id = v_grupo AND m.id <> v_op_id;
      END IF;
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

-- (253) The split. Same authorization as crm_corregir_operacion; service mapping as _cambiar_servicio_core.
CREATE OR REPLACE FUNCTION public.crm_repartir_envio(p_operation_id uuid, p_partes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_services   constant text[] := ARRAY['cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo'];
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
  v_after      remittance_operations%ROWTYPE;
  v_ids        uuid[] := ARRAY[]::uuid[];
  v_new        boolean[] := ARRAY[]::boolean[];
  v_obj        numeric;
  v_dep        numeric;
  v_saldo      numeric;
  v_partes     jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_op.account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to split this operation' USING ERRCODE = '42501';
  END IF;

  -- The anchor is the group's anchor when the operation is already a member, else the operation itself.
  v_anchor_id := COALESCE(v_op.mixed_group_id, v_op.id);
  SELECT * INTO v_anchor FROM remittance_operations WHERE id = v_anchor_id FOR UPDATE;
  PERFORM 1 FROM remittance_operations WHERE mixed_group_id = v_anchor_id ORDER BY id FOR UPDATE;

  IF v_anchor.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  -- Parts: an array of at least two {servicio, monto_gyd}, distinct services, positive amounts.
  IF p_partes IS NULL OR jsonb_typeof(p_partes) <> 'array' OR jsonb_array_length(p_partes) < 2 THEN
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
  IF v_total IS NULL OR v_total <= 0 THEN
    RAISE EXCEPTION 'there is no money to split: the total is %', COALESCE(v_total::text, 'empty') USING ERRCODE = '22023';
  END IF;
  IF v_sum <> v_total THEN
    RAISE EXCEPTION 'the parts add up to % but the total to split is %', v_sum, v_total USING ERRCODE = '22023';
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
      SELECT o.id INTO v_target
        FROM remittance_operations o
       WHERE o.conversation_id = v_anchor.conversation_id
         AND o.status NOT IN ('completed', 'cancelled')
         AND (o.mixed_group_id IS NULL OR o.mixed_group_id = v_anchor_id)
         AND cerebro_riel_op(o.id) = v_key
       ORDER BY (o.mixed_group_id IS NOT NULL) DESC, o.created_at DESC
       LIMIT 1
       FOR UPDATE;

      IF v_target IS NULL THEN
        -- Same mapping as _cambiar_servicio_core; the destination amount and currency come from the calculation.
        v_type := CASE WHEN v_key IN ('recarga', 'combo', 'visa', 'saldo') THEN v_key ELSE 'remesa' END;
        v_dm   := CASE WHEN v_type = 'remesa' THEN v_key END;
        INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                           deposit_method, source_country, source_currency)
        VALUES (v_anchor.account_id, v_anchor.conversation_id, v_anchor.contact_id, 'collecting_information', v_type, v_dm,
                v_anchor.deposit_method, v_anchor.source_country, v_anchor.source_currency)
        RETURNING id INTO v_target;
        v_created := true;
      END IF;
    END IF;

    SELECT * INTO v_before FROM remittance_operations WHERE id = v_target;

    -- The share is written by a human, so the 096 guard locks quoted_source_amount; the explicit lock covers an
    -- unchanged amount. The remesa recalculation then writes the destination as a human too: release those locks unless
    -- an earlier correction had set them.
    UPDATE remittance_operations
       SET quoted_source_amount = v_amts[v_i],
           mixed_group_id = v_anchor_id,
           admin_locked_fields = COALESCE(admin_locked_fields, '{}'::jsonb)
             || jsonb_build_object('quoted_source_amount', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
     WHERE id = v_target;

    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields
             - CASE WHEN v_before.admin_locked_fields ? 'quoted_destination_amount' THEN '' ELSE 'quoted_destination_amount' END
             - CASE WHEN v_before.admin_locked_fields ? 'destination_currency' THEN '' ELSE 'destination_currency' END
     WHERE id = v_target
       AND admin_locked_fields ?| ARRAY['quoted_destination_amount', 'destination_currency'];

    SELECT * INTO v_after FROM remittance_operations WHERE id = v_target;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_after.account_id, 'remittance_operations', v_target, 'mixed_split', 'human_correction',
            wacrm_current_actor(), 'mixed send: one deposit split across a group of operations',
            jsonb_build_object('quoted_source_amount', v_before.quoted_source_amount, 'mixed_group_id', v_before.mixed_group_id),
            jsonb_build_object('quoted_source_amount', v_after.quoted_source_amount, 'mixed_group_id', v_after.mixed_group_id,
                               'service', v_key, 'created', v_created));

    v_ids := v_ids || v_target;
    v_new := v_new || v_created;
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

  RETURN jsonb_build_object('grupo', v_anchor_id, 'depositado', v_dep, 'saldo', v_saldo, 'partes', v_partes);
END $function$;

REVOKE ALL ON FUNCTION public.crm_repartir_envio(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.crm_repartir_envio(uuid, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.crm_repartir_envio(uuid, jsonb) TO authenticated, service_role;

