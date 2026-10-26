-- ROLLBACK of 331: restores the five rewritten functions exactly as read from staging
-- (pg_get_functiondef, 2026-10-26), drops the reconciliation functions and trigger, and removes the
-- resolver columns. Data written by the engine (cases, allocations) stays in the phase 2 tables.
-- =====================================================================

DROP TRIGGER IF EXISTS funding_reconciliar_beneficiario_trg ON public.remittance_beneficiaries;
DROP FUNCTION IF EXISTS public.funding_reconciliar_beneficiario();
DROP FUNCTION IF EXISTS public.funding_case_resolver(uuid, text);
DROP FUNCTION IF EXISTS public.funding_reconciliar(uuid, text);
DROP FUNCTION IF EXISTS public.cerebro_op_conflicto(uuid);
DROP FUNCTION IF EXISTS public.cerebro_riel_por_prefijo(text);
ALTER TABLE public.funding_case DROP COLUMN IF EXISTS resolved_by;
ALTER TABLE public.funding_case DROP COLUMN IF EXISTS resolved_at;

CREATE OR REPLACE FUNCTION public.cerebro_fondos_operacion(p_op uuid)
 RETURNS TABLE(requerido numeric, depositado numeric, cubierto boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH base AS (
    SELECT ro.id, ro.mixed_group_id
      FROM remittance_operations ro
     WHERE ro.id = p_op
  ),
  miembros AS (
    SELECT m.id, m.quoted_source_amount
      FROM base b
      JOIN remittance_operations m
        ON (b.mixed_group_id IS NOT NULL AND m.mixed_group_id = b.mixed_group_id AND m.status <> 'cancelled')
        OR (b.mixed_group_id IS NULL AND m.id = b.id)
  ),
  depositos AS (
    -- A verified GYD deposit counts once: linked to a member, or unlinked but carrying the TransID of
    -- a member's receipt (the admin typed-TransID path consumes it with operation_id NULL).
    SELECT DISTINCT d.trans_id, d.monto
      FROM depositos_mmg d
     WHERE d.consumido_en IS NOT NULL
       AND d.anulado_en IS NULL
       AND d.descartado_en IS NULL
       AND COALESCE(d.moneda, 'GYD') = 'GYD'
       AND (d.operation_id IN (SELECT id FROM miembros)
            OR (d.operation_id IS NULL
                AND EXISTS (SELECT 1 FROM remittance_operation_receipts r
                             WHERE r.operation_id IN (SELECT id FROM miembros)
                               AND r.reference ~ ('(^|[^0-9])' || d.trans_id || '([^0-9]|$)'))))
  )
  SELECT (SELECT COALESCE(sum(quoted_source_amount), 0) FROM miembros),
         (SELECT COALESCE(sum(monto), 0) FROM depositos),
         ((SELECT COALESCE(sum(quoted_source_amount), 0) FROM miembros) > 0
          AND (SELECT COALESCE(sum(monto), 0) FROM depositos)
              >= (SELECT COALESCE(sum(quoted_source_amount), 0) FROM miembros));
$function$;

CREATE OR REPLACE FUNCTION public.crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb, p_notify boolean DEFAULT true, p_cup_source_card_id uuid DEFAULT NULL::uuid)
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
  v_n             int;
  v_nnull         int;
  v_sum           numeric;
  v_dest          numeric;
  v_cur           text;
  v_cur_ok        boolean;
  v_riel          text;
  v_req           numeric;
  v_dep           numeric;
  v_cov           boolean;
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

  -- (257) The optional CUP sending card: one of this account's active cards, else refused before anything changes.
  PERFORM cup_validar_tarjeta_origen(v_account_id, p_cup_source_card_id);

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

  -- (329) No delivery with unverified money: the operation, or its mixed group as a whole, must be
  -- covered by consumed, unvoided MMG deposits. Over-funding is allowed in phase 1 and stays visible
  -- as a negative balance in cerebro_saldo_operacion.
  SELECT s.requerido, s.depositado, s.cubierto INTO v_req, v_dep, v_cov
    FROM cerebro_fondos_operacion(p_operation_id) s;
  IF coalesce(v_req, 0) <= 0 THEN
    RAISE EXCEPTION 'the operation has no source amount to fund' USING ERRCODE = '22023';
  END IF;
  IF NOT coalesce(v_cov, false) THEN
    RAISE EXCEPTION 'the operation has % GYD of verified funding but needs % GYD: verify the deposit before delivering',
      v_dep, v_req USING ERRCODE = '22023';
  END IF;

  -- (329) EVERY RAIL: the recipients' amounts must add up to what the operation sends. The gate only
  -- applies when every vigente recipient has an amount and all their currencies equal the destination
  -- currency (a null destination only accepts null currencies). Zelle compares whole dollars; the
  -- other rails compare cents. Yoandrys 2026-10-26: a 1,100 USD Zelle was delivered with 800 + 200.
  SELECT o.quoted_destination_amount, o.destination_currency
    INTO v_dest, v_cur
    FROM remittance_operations o WHERE o.id = p_operation_id;
  SELECT count(*),
         count(*) FILTER (WHERE b.amount IS NULL),
         coalesce(sum(b.amount), 0),
         coalesce(bool_and(b.currency IS NOT DISTINCT FROM v_cur), true)
    INTO v_n, v_nnull, v_sum, v_cur_ok
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_operation_id AND b.status = 'vigente';
  v_riel := cerebro_riel_op(p_operation_id);
  IF coalesce(v_dest, 0) > 0 AND v_n > 0 AND v_nnull = 0 AND v_cur_ok THEN
    IF (v_riel = 'zelle' AND round(v_sum) <> round(v_dest))
       OR (v_riel IS DISTINCT FROM 'zelle' AND round(v_sum, 2) <> round(v_dest, 2)) THEN
      RAISE EXCEPTION 'the recipients add up to % % but the operation sends % %: complete them before delivering',
        round(v_sum, 2)::text, coalesce(v_cur, ''), round(v_dest, 2)::text, coalesce(v_cur, '')
        USING ERRCODE = '22023';
    END IF;
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
         delivered_by = auth.uid(),
         -- (257) In the SAME statement, so the calculator feed (AFTER UPDATE OF status) sees the chosen card.
         cup_source_card_id = p_cup_source_card_id
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
          jsonb_build_object('status', 'completed', 'evidence', p_evidence)
            || CASE WHEN p_cup_source_card_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('cup_source_card_id', p_cup_source_card_id) END);

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;

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
  v_after      remittance_operations%ROWTYPE;
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
         AND cerebro_riel_op(o.id) = v_key
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

  RETURN jsonb_build_object('grupo', v_anchor_id, 'depositado', v_dep, 'saldo', v_saldo, 'partes', v_partes,
                            'parcial', p_parcial, 'asignado', v_sum,
                            'deposito_verificado', v_dep0,
                            'sobrante', CASE WHEN p_parcial THEN v_dep0 - v_sum END);
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_cruzar_deposito(p_deal uuid, p_ref text, p_monto numeric, p_stage_ok uuid, p_stage_incidencia uuid, p_stage_esperado uuid, p_simular boolean DEFAULT false)
 RETURNS TABLE(resultado text, trans_id text, deal_actualizado integer, metodo text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ref        text;
  v_aplica     boolean;
  v_res        text;
  v_trans      text;
  v_recibido   timestamptz;
  v_metodo     text := 'exacto';
  v_nota       text;
  v_stage      uuid;
  v_tocados    int  := 0;
  v_horas      int;
  v_maxhoras   int;
  v_candidatos int := 0;
  v_conv       uuid;
  v_phone      text;
  v_op_id      uuid;
BEGIN
  -- (160) Resolve either flavour of id to an operation id.
  v_op_id := cerebro_resolve_op_id(p_deal);

  v_ref := NULLIF(regexp_replace(COALESCE(p_ref, ''), '[^0-9]', '', 'g'), '');

  -- (311) An admin verification has no operation (the registrar wrapper
  -- returns a NULL deal on purpose): the cross must still run and consume
  -- the deposit with operation_id NULL. With an operation, the old gate stays.
  IF v_op_id IS NULL THEN
    v_aplica := true;
  ELSE
    SELECT COALESCE(
             (SELECT ro.status FROM remittance_operations ro WHERE ro.id = v_op_id)
               = cerebro_estado_desde_etapa(p_stage_esperado),
             false)
      INTO v_aplica;
  END IF;

  IF NOT v_aplica THEN
    RETURN QUERY SELECT 'no_aplica'::text, v_ref, 0, 'ninguno'::text; RETURN;
  END IF;

  IF v_ref IS NULL THEN
    RETURN QUERY SELECT 'sin_referencia'::text, v_ref, 0, 'ninguno'::text; RETURN;
  END IF;

  v_maxhoras := COALESCE(NULLIF(cerebro_config_get('cruce_antiguedad_max_horas'), '')::int, 72);

  SELECT d.trans_id, d.recibido_en INTO v_trans, v_recibido
    FROM depositos_mmg d
   WHERE d.trans_id = v_ref AND d.consumido_en IS NULL AND d.monto = p_monto
     AND d.anulado_en IS NULL
   FOR UPDATE;

  IF v_trans IS NOT NULL AND v_recibido < now() - make_interval(hours => v_maxhoras) THEN
    v_res    := 'deposito_antiguo';
    v_metodo := 'antiguo';
  ELSIF v_trans IS NOT NULL THEN
    IF NOT p_simular THEN
      -- (160) Compatibility shim: mirror the legacy deal_id onto
      -- depositos_mmg so the 159 reader's WHERE deal_id = v_deal_id
      -- query continues to resolve consumed deposits. When the
      -- resolved operation has deal_id IS NULL we leave it untouched.
      UPDATE depositos_mmg d
         SET consumido_en = now(), operation_id = v_op_id,
             deal_id = COALESCE(deal_id, (SELECT deal_id FROM remittance_operations WHERE id = v_op_id))
       WHERE d.trans_id = v_trans AND d.consumido_en IS NULL;
    END IF;
    v_res := 'verificado';
  ELSIF EXISTS (SELECT 1 FROM depositos_mmg x
                 WHERE x.trans_id = v_ref AND x.anulado_en IS NOT NULL) THEN
    v_res := 'deposito_anulado';
  ELSIF EXISTS (SELECT 1 FROM depositos_mmg x
                 WHERE x.trans_id = v_ref AND x.consumido_en IS NOT NULL) THEN
    v_res := 'ya_reclamado';
  ELSIF EXISTS (SELECT 1 FROM depositos_mmg x WHERE x.trans_id = v_ref) THEN
    v_res := 'monto_no_coincide';
  ELSE
    v_res := 'sin_correo';
  END IF;

  IF v_res = 'sin_correo' THEN
    v_horas := COALESCE(NULLIF(cerebro_config_get('cruce_ventana_horas'), '')::int, 6);

    SELECT count(*) INTO v_candidatos
      FROM depositos_mmg m
     WHERE m.consumido_en IS NULL
       AND m.anulado_en IS NULL
       AND m.monto        = p_monto
       AND m.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                             AND now() + interval '15 minutes'
       -- (197) was: same length, first 5 and last 4 digits
       AND cerebro_ref_parecida(v_ref, m.trans_id);

    IF v_candidatos = 1 THEN
      IF p_simular THEN
        SELECT m.trans_id INTO v_trans
          FROM depositos_mmg m
         WHERE m.consumido_en IS NULL AND m.anulado_en IS NULL AND m.monto = p_monto
           AND m.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                                 AND now() + interval '15 minutes'
           -- (197) was: same length, first 5 and last 4 digits
       AND cerebro_ref_parecida(v_ref, m.trans_id);
      ELSE
        UPDATE depositos_mmg m
           SET consumido_en = now(), operation_id = v_op_id,
               deal_id = COALESCE(deal_id, (SELECT deal_id FROM remittance_operations WHERE id = v_op_id))
         WHERE m.trans_id = (
                 SELECT x.trans_id FROM depositos_mmg x
                  WHERE x.consumido_en IS NULL
                    AND x.anulado_en IS NULL
                    AND x.monto = p_monto
                    AND x.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                                          AND now() + interval '15 minutes'
                    -- (197) was: same length, first 5 and last 4 digits
       AND cerebro_ref_parecida(v_ref, x.trans_id)
                  LIMIT 1 FOR UPDATE SKIP LOCKED)
        RETURNING m.trans_id INTO v_trans;
      END IF;

      IF v_trans IS NOT NULL THEN
        v_res := 'verificado'; v_metodo := 'aproximado';
      END IF;
    ELSIF v_candidatos > 1 THEN
      v_metodo := 'ambiguo';
    END IF;
  END IF;

  IF v_res IN ('verificado','ya_reclamado','monto_no_coincide','deposito_antiguo','deposito_anulado') THEN
    v_stage := CASE WHEN v_res = 'verificado' THEN p_stage_ok ELSE p_stage_incidencia END;

    v_nota := CASE
      WHEN v_res = 'verificado' AND v_metodo = 'aproximado' THEN
        'VERIFICADO: casa con el correo de MMG (TransID ' || v_trans || ') '
        || '- COINCIDENCIA APROXIMADA: el comprobante decia ' || v_ref
        || '. Coinciden importe y hora, la referencia difiere en 2 digitos o menos, y era el unico'
        || ' candidato posible. CONFIRMAR VISUALMENTE el comprobante.'
      WHEN v_res = 'verificado' THEN
        'VERIFICADO: casa con el correo de MMG (TransID ' || v_ref || ')'
      WHEN v_res = 'deposito_anulado' THEN
        'SIN VERIFICAR - DEPOSITO ANULADO: el TransID ' || v_ref || ' figura como'
        || ' ANULADO en el libro de MMG. NO se ha dado por bueno. Motivo registrado: '
        || COALESCE((SELECT x.motivo_anulacion FROM depositos_mmg x WHERE x.trans_id = v_ref LIMIT 1), 'sin motivo')
      WHEN v_res = 'deposito_antiguo' THEN
        'SIN VERIFICAR - DEPOSITO ANTIGUO: el TransID ' || v_ref || ' si existe y el'
        || ' importe cuadra, pero el deposito se recibio el '
        || to_char(v_recibido AT TIME ZONE 'America/Guyana', 'DD/MM/YYYY HH24:MI')
        || ' (hace ' || floor(EXTRACT(epoch FROM (now() - v_recibido))/3600)::int || ' horas).'
        || ' NO se ha dado por bueno ni se ha consumido. Compruebe que esta remesa no'
        || ' se pago ya por otra via antes de transferir.'
      WHEN v_res = 'ya_reclamado' THEN
        'ALERTA: el TransID ' || v_ref || ' ya fue usado en otro envio'
      ELSE
        'ALERTA: el TransID ' || v_ref || ' existe en MMG pero el monto no coincide'
    END;

    IF NOT p_simular THEN
      -- (160) Compatibility shim: write deal_id on depositos_mmg so the
      -- 159 reader's WHERE deal_id = v_deal_id still resolves consumed
      -- deposits for legacy operations.
      UPDATE remittance_operations
         SET status = cerebro_estado_desde_etapa(v_stage),
             incident_reason = CASE WHEN cerebro_estado_desde_etapa(v_stage) = 'incident'
                                    THEN v_nota ELSE NULL END,
             updated_at = now()
       WHERE id = v_op_id;
      GET DIAGNOSTICS v_tocados = ROW_COUNT;
    ELSE
      v_tocados := 1;
    END IF;
  END IF;

  IF NOT p_simular AND v_metodo IN ('aproximado','ambiguo') THEN
    SELECT o.conversation_id INTO v_conv FROM remittance_operations o WHERE o.id = v_op_id;
    SELECT c.phone INTO v_phone FROM conversations v JOIN contacts c ON c.id = v.contact_id
     WHERE v.id = v_conv;

    PERFORM net.http_post(
      url     := cerebro_config_get('notify_url'),
      body    := jsonb_build_object('type','CRUCE_APROXIMADO','metodo',v_metodo,
                   'cliente_phone',COALESCE(v_phone,'?'),'monto',p_monto,
                   'ref_leida',v_ref,'ref_hallada',v_trans,'candidatos',v_candidatos),
      headers := jsonb_build_object('Content-Type','application/json',
                   'X-Cerebro-Secret', cerebro_config_get('notify_secret')));
  END IF;

  RETURN QUERY SELECT v_res, COALESCE(v_trans, v_ref), v_tocados, v_metodo;
END;
$function$;
