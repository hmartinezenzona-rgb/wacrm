-- =====================================================================
-- 255 -- The bot splits one customer deposit across services: cerebro_repartir_envio (staging first)
--
-- odd/tasks/mixed-send-split-deposit.md (S4a). Migration 253 gave the panel crm_repartir_envio(operation, parts). The Cerebro
-- WhatsApp agent needs the same split by conversation, with the parts coming from the model as free text
-- ("clasica 18200, recarga 6200"), e.g. production 2026-10-20 (f8b7779c): 24,400 GYD deposited for 70 USD Clasica (18,200) plus a
-- phone top-up (6,200).
--
-- Authorization pattern reused from 230 (_cambiar_servicio_core / crm_cambiar_servicio / cerebro_cambiar_servicio): crm_repartir_envio
-- authorizes with is_account_member(account, 'agent'), which reads auth.uid(); the bot runs as service_role with no auth.uid(), so it
-- can never pass that check, and the 096 lock guard only lets a human or an asserted wacrm.origin = 'admin' writer set the lock map.
-- As 230 did for the service change, the body moves into an INTERNAL core with the audit action, actor and reason as parameters:
--   1. _repartir_envio_core(operation, parts, audit action, actor, reason): the 253 body unchanged except the membership check
--      (moved to the caller) and the audit columns. No API role can execute it (REVOKE from PUBLIC, anon, authenticated,
--      service_role); the SECURITY DEFINER callers run as the owner.
--   2. crm_repartir_envio(uuid, jsonb): same signature, grants, refusals and result; checks the membership, then calls the core with
--      action 'human_correction', actor wacrm_current_actor() and the 253 reason. Panel behaviour is unchanged.
--   3. cerebro_repartir_envio(p_conv uuid, p_partes text, p_execution text DEFAULT NULL) RETURNS text: the bot tool. service_role only.
--      It runs the core with wacrm.origin = 'admin' and wacrm.actor = 'automation:cerebro_repartir_envio' for the call only
--      (restored afterwards), exactly like cerebro_cambiar_servicio, so quoted_source_amount is locked on every member (the lock
--      names the bot) and later automation cannot overwrite a share. Audit: action 'automation_mixed_split' (added to
--      remittance_admin_audit_action_chk, as 230 did), field 'mixed_split', actor 'automation:cerebro_repartir_envio',
--      reason 'n8n execution <id>'. One tool_execution_log line (tool 'repartir_envio').
--      * The anchor: the conversation's open operation (not completed / cancelled) that holds the deposit: one already in a group
--        first, then one with a consumed deposit or a receipt, newest first; else the newest open one with quoted_source_amount > 0.
--        None: 'No hay un deposito registrado para repartir todavia.' and nothing is written.
--      * A business refusal (SQLSTATE 22023 from the core) becomes a Spanish sentence with the server's reason and nothing is changed
--        (the call runs in a sub-transaction); an unexpected error still raises.
--      * The answer is Spanish text the agent reads: each part with its GYD amount (and the destination amount for remesa rails),
--        and the group state.
-- Helpers: _cerebro_partes_envio_parse(text) -> jsonb {ok, partes | segmento}; _cerebro_fmt_monto(numeric) -> text. Both internal.
-- Assertion: supabase/staging/assertions/bot-mixed-split.sql. Rollback: ROLLBACK-255-bot-mixed-split.sql.
-- =====================================================================

ALTER TABLE remittance_admin_audit DROP CONSTRAINT remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk CHECK (action = ANY (ARRAY[
  'automation_write_suppressed', 'automation_completion_suppressed', 'automation_revert_suppressed', 'human_correction',
  'human_reassignment', 'human_deposit_verification', 'human_forced_verification', 'human_delivery', 'calculator_feed_failed',
  'calculator_pending_resolved', 'human_beneficiary_added', 'automation_reparto_registered', 'human_calculator_correction',
  'automation_cash_delivery_data_registered', 'automation_late_deposit_verification', 'human_manual_close',
  'human_operation_deleted', 'automation_recharge_numbers_registered', 'automation_combo_recipient_registered',
  'human_combo_cost_set', 'automation_visa_registered', 'human_calculator_entry_deleted', 'human_calculator_manual_added',
  'automation_service_change', 'automation_mixed_split']));

-- ---------------------------------------------------------------------
-- 1. The shared core (253 body; membership check moved to the callers)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._repartir_envio_core(p_operation_id uuid, p_partes jsonb, p_audit_action text, p_actor text, p_reason text)
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

  RETURN jsonb_build_object('grupo', v_anchor_id, 'depositado', v_dep, 'saldo', v_saldo, 'partes', v_partes);
END $function$;

REVOKE ALL ON FUNCTION public._repartir_envio_core(uuid, jsonb, text, text, text) FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. The panel RPC keeps its signature, grants and behaviour
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_repartir_envio(p_operation_id uuid, p_partes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
BEGIN
  SELECT account_id INTO v_account FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to split this operation' USING ERRCODE = '42501';
  END IF;
  RETURN _repartir_envio_core(p_operation_id, p_partes, 'human_correction', wacrm_current_actor(),
                              'mixed send: one deposit split across a group of operations');
END $function$;

-- ---------------------------------------------------------------------
-- 3. Helpers (internal)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._cerebro_fmt_monto(p_n numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT regexp_replace(to_char(p_n, 'FM999,999,999,999,990.00'), '\.?0+$', '');
$function$;

-- Parses the model's free text into {"ok":true,"partes":[{"servicio","monto_gyd"}]} or {"ok":false,"segmento":<what was not understood>}.
-- Segments are separated by commas, semicolons, newlines or " y ". Each holds one service word and one GYD amount; thousands
-- separators ("18,200", "18.200", "18 200") and "gyd" / "$" are accepted. A service word must be the WHOLE rest of the segment, so
-- "saldo movil" is saldo and "saldo de recarga" is recarga; a segment with a "usd" amount is not understood (amounts are GYD).
CREATE OR REPLACE FUNCTION public._cerebro_partes_envio_parse(p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_t      text;
  v_prev   text;
  v_seg    text;
  v_nums   text[];
  v_rest   text;
  v_key    text;
  v_amt    numeric;
  v_partes jsonb := '[]'::jsonb;
BEGIN
  v_t := lower(translate(coalesce(p_text, ''), 'ÁÉÍÓÚÑÜáéíóúñü', 'AEIOUNUaeiounu'));
  -- thousands separators: 18,200 / 18.200 / 18 200 (a group of exactly three digits after one to three)
  LOOP
    v_prev := v_t;
    v_t := regexp_replace(v_t, '(?<![0-9])([0-9]{1,3})[.,]([0-9]{3})(?![0-9])', '\1\2', 'g');
    v_t := regexp_replace(v_t, '(?<![0-9])([0-9]{1,3}) ([0-9]{3})(?![0-9])', '\1\2', 'g');
    EXIT WHEN v_t = v_prev;
  END LOOP;
  v_t := regexp_replace(v_t, '\mgyd\M', ' ', 'g');
  v_t := replace(v_t, '$', ' ');

  FOR v_seg IN SELECT btrim(s) FROM regexp_split_to_table(v_t, '\s*[;,\r\n]+\s*|\s+y\s+') AS s LOOP
    CONTINUE WHEN v_seg = '';
    SELECT array_agg(m[1]) INTO v_nums FROM regexp_matches(v_seg, '([0-9]+)', 'g') AS m;
    v_rest := btrim(regexp_replace(regexp_replace(regexp_replace(v_seg, '[0-9]+', ' ', 'g'), '[:=\-.]', ' ', 'g'), '\s+', ' ', 'g'));
    LOOP
      v_prev := v_rest;
      v_rest := regexp_replace(v_rest, '^(para|de|la|el|los|las|una|un|por|en)\s+', '');
      EXIT WHEN v_rest = v_prev;
    END LOOP;
    v_key := CASE v_rest
      WHEN 'clasica' THEN 'clasica'
      WHEN 'tropical' THEN 'tropical'
      WHEN 'zelle' THEN 'zelle'
      WHEN 'cup' THEN 'cuban_card'
      WHEN 'tarjeta cup' THEN 'cuban_card'
      WHEN 'tarjeta' THEN 'cuban_card'
      WHEN 'efectivo' THEN 'efectivo_usd'
      WHEN 'efectivo usd' THEN 'efectivo_usd'
      WHEN 'recarga' THEN 'recarga'
      WHEN 'recargas' THEN 'recarga'
      WHEN 'saldo de recarga' THEN 'recarga'
      WHEN 'combo' THEN 'combo'
      WHEN 'combos' THEN 'combo'
      WHEN 'visa' THEN 'visa'
      WHEN 'extension de visa' THEN 'visa'
      WHEN 'extension visa' THEN 'visa'
      WHEN 'saldo movil' THEN 'saldo'
      WHEN 'saldo' THEN 'saldo'
      ELSE NULL
    END;
    IF v_key IS NULL OR coalesce(array_length(v_nums, 1), 0) <> 1 OR length(v_nums[1]) > 12 THEN
      RETURN jsonb_build_object('ok', false, 'segmento', v_seg);
    END IF;
    v_amt := v_nums[1]::numeric;
    IF v_amt <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'segmento', v_seg);
    END IF;
    v_partes := v_partes || jsonb_build_object('servicio', v_key, 'monto_gyd', v_amt);
  END LOOP;

  IF jsonb_array_length(v_partes) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'segmento', '');
  END IF;
  RETURN jsonb_build_object('ok', true, 'partes', v_partes);
END $function$;

REVOKE ALL ON FUNCTION public._cerebro_fmt_monto(numeric) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_partes_envio_parse(text) FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. The bot tool
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_repartir_envio(p_conv uuid, p_partes text, p_execution text DEFAULT NULL)
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
     ORDER BY (o.mixed_group_id IS NOT NULL) DESC,
              (EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL)
               OR EXISTS (SELECT 1 FROM remittance_operation_receipts rr WHERE rr.operation_id = o.id)) DESC,
              o.created_at DESC
     LIMIT 1;

    IF v_op IS NULL THEN
      v_outcome := 'sin_deposito';
      v_text := 'No hay un deposito registrado para repartir todavia.';
    ELSE
      v_prev_origin := coalesce(current_setting('wacrm.origin', true), '');
      v_prev_actor  := coalesce(current_setting('wacrm.actor', true), '');
      BEGIN
        PERFORM set_config('wacrm.origin', 'admin', true);
        PERFORM set_config('wacrm.actor', c_actor, true);
        v_res := _repartir_envio_core(v_op, v_parse -> 'partes', 'automation_mixed_split', c_actor,
                                      'n8n execution ' || coalesce(nullif(btrim(p_execution), ''), 'unknown'));
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
      EXCEPTION
        WHEN SQLSTATE '22023' THEN
          PERFORM set_config('wacrm.origin', v_prev_origin, true);
          PERFORM set_config('wacrm.actor', v_prev_actor, true);
          v_outcome := 'rechazado';
          IF SQLERRM LIKE 'the parts add up to % but the total to split is %' THEN
            v_a := substring(SQLERRM from 'add up to ([0-9.]+) but');
            v_b := substring(SQLERRM from 'total to split is ([0-9.]+)$');
            v_text := 'No se pudo repartir: las partes suman ' || _cerebro_fmt_monto(v_a::numeric) ||
                      ' GYD pero el deposito a repartir es ' || _cerebro_fmt_monto(v_b::numeric) ||
                      ' GYD. No cambie nada; corrige los montos y vuelve a intentar.';
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
        v_outcome := 'repartido';
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

  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments, outcome)
  VALUES (coalesce(nullif(btrim(p_execution), ''), gen_random_uuid()::text) || ':repartir_envio:' || md5(coalesce(p_partes, '')),
          'repartir_envio', p_execution, p_conv, v_op, jsonb_build_array(to_jsonb(p_partes)), v_outcome)
  ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN v_text;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_repartir_envio(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_repartir_envio(uuid, text, text) TO service_role;
