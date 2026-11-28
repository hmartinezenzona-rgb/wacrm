-- =====================================================================
-- 230 -- The bot changes the service of the customer's open operation itself (staging first)
--
-- odd/tasks/bot-change-service.md (A1-A4). Production 2026-10-08 (Carlos): cash USD quoted at 290 GYD/USD (162 USD), receipt sent,
-- then "Mejor zelle". The bot quoted 181 USD by Zelle in words but the operation stayed efectivo_usd / 162 USD: the bot had NO write
-- path to Zelle (cerebro_marcar_destino_usd takes clasica / tropical / efectivo only; cerebro_registrar_destino never overwrites
-- efectivo_usd or zelle; the panel's crm_cambiar_servicio is for authenticated members). Owner decision 2026-10-08: when the customer
-- asks to change the service, EVEN AFTER the deposit is verified, the bot changes it itself and tells the customer the new amount.
--
-- 1. _cambiar_servicio_core(operation, service, audit action, actor, reason): the ONE implementation of the change, moved here
--    unchanged from crm_cambiar_servicio (223): the recipients that fit stay (a card rail re-types the card), the others are retired,
--    the destination quote is cleared and recomputed by crm_calcular_monto_destino (224: Zelle tiers, single rate, cash rate, CUP
--    rate), the rail and service_type are locked, one audit row is written. The caller has locked the row and validated the service.
--    INTERNAL: no API role can execute it (REVOKE from PUBLIC, anon, authenticated, service_role); the two SECURITY DEFINER callers
--    below run as the owner.
-- 2. crm_cambiar_servicio(uuid, text): the panel RPC keeps its signature, grants (authenticated + service_role, not anon), refusals
--    (42501, P0002, 22023) and returned shape; only the body after the validations now calls the core. Audit: human_correction,
--    actor wacrm_current_actor(), no reason, as before.
-- 3. cerebro_cambiar_servicio(p_conversation_id uuid, p_servicio text, p_execution_id text DEFAULT NULL) RETURNS jsonb: the bot's
--    tool. Executable by service_role only (the role of cerebro_marcar_destino_usd and the other bot functions on staging:
--    {postgres, service_role}); nothing for PUBLIC, anon or authenticated.
--    * Accepts cuban_card, zelle, clasica, tropical, efectivo_usd, recarga, combo, visa, saldo (case-insensitive, trimmed) and the
--      aliases cup -> cuban_card, efectivo -> efectivo_usd. Anything else: {ok:false, reason:'servicio_desconocido'}.
--    * The operation: the conversation's single OPEN operation among collecting_information, awaiting_deposit, deposit_received,
--      deposit_verification, ready_to_transfer, incident (the bot's own list of 163, plus the two orphan statuses). None open: the
--      conversation's latest operation decides ('estado_no_permite' with its status when it is completed / cancelled / transferring)
--      or 'sin_operacion' when there is none. Two or more: the bot's usual hand-over (cerebro_registrar_derivacion, razon
--      operacion_ambigua) and {ok:false, reason:'operacion_ambigua', derivado}.
--    * Refusals write nothing (apart from the tool_execution_log line and the hand-over above): estado_no_permite (status not
--      collecting_information / awaiting_deposit / deposit_received / deposit_verification / ready_to_transfer), tipo_no_soportado
--      (service_type outside remesa/recarga/combo/visa/saldo), bloqueado_por_humano (delivery_method, service_type or
--      quoted_destination_amount in admin_locked_fields NOT locked by an automation: a human fixed it; payload campo),
--      por_debajo_del_minimo (cerebro_minimo_gyd of the NEW service, payload minimo_gyd, source_amount_gyd, servicio),
--      varios_destinatarios (several recipients with their own amounts cannot move between CUP and USD, the panel's 22023).
--      The minimum is judged by the existing rule (cerebro_minimo_gyd, which reads the operation's rail) on the changed operation
--      inside a sub-transaction that is rolled back when it fails, so no threshold is duplicated here.
--    * The same service again: {ok:true, changed:false} with the current quote; nothing written, nothing audited.
--    * Success: {ok:true, changed:true, operation_id, servicio, source_amount_gyd, destination_amount, destination_currency, rate,
--      previous:{servicio, destination_amount, destination_currency, rate}, retired_recipients (count), retyped_recipients, status}.
--    * The automation runs the core with wacrm.origin = 'admin' and wacrm.actor = 'automation:cerebro_cambiar_servicio' for the call
--      only (restored afterwards), because the 096 lock guard only lets a human-or-asserted-admin writer set the lock map. The rail
--      lock it leaves is stamped 'automation:' so the bot may change its own earlier change, and it suppresses a LATE bot write of
--      the old rail (the receipt turn of the incident marking "efectivo" after the switch) exactly as a panel change does.
--    * Audit: one remittance_admin_audit row, action 'automation_service_change' (added to remittance_admin_audit_action_chk, as 228
--      did for its action), field 'service', actor 'automation:cerebro_cambiar_servicio', reason 'n8n execution <id>', before/after
--      as the panel's. One tool_execution_log line (tool 'cambiar_servicio', key <execution>:cambiar_servicio:md5(service)).
--    * It changes no status, so the status notifier does not fire and customer_notice_muted_for is not needed (the panel path
--      does not touch it either); it writes no message, outbox row or notification: the bot answers the customer itself.
--    * Concurrency: the operation row is locked FOR UPDATE (as the panel does) and its status re-read after the lock.
-- Pre-230 md5 (pg_get_functiondef / pg_get_constraintdef, staging 2026-10-08; the ROLLBACK restores exactly these):
-- crm_cambiar_servicio ee82240e976cd036b8b23b085c8d8ca9; remittance_admin_audit_action_chk (constraint definition text + newline)
-- a3453bb94deeb54ef1037f81e9ccfe73. Staging had no drift in crm_cambiar_servicio, crm_calcular_monto_destino, cerebro_riel_op,
-- cerebro_minimo_gyd or cerebro_marcar_destino_usd (repo definitions equal staging's).
-- Guarded by supabase/staging/assertions/bot-change-service.sql. ROLLBACK: ROLLBACK-230-bot-change-service.sql
-- =====================================================================

ALTER TABLE remittance_admin_audit DROP CONSTRAINT remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk CHECK (action = ANY (ARRAY[
  'automation_write_suppressed', 'automation_completion_suppressed', 'automation_revert_suppressed', 'human_correction',
  'human_reassignment', 'human_deposit_verification', 'human_forced_verification', 'human_delivery', 'calculator_feed_failed',
  'calculator_pending_resolved', 'human_beneficiary_added', 'automation_reparto_registered', 'human_calculator_correction',
  'automation_cash_delivery_data_registered', 'automation_late_deposit_verification', 'human_manual_close',
  'human_operation_deleted', 'automation_recharge_numbers_registered', 'automation_combo_recipient_registered',
  'human_combo_cost_set', 'automation_visa_registered', 'human_calculator_entry_deleted', 'human_calculator_manual_added', 'automation_service_change']));

-- ---------------------------------------------------------------------
-- 1. The shared core
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._cambiar_servicio_core(p_operation_id uuid, p_servicio text, p_audit_action text, p_actor text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op         remittance_operations%ROWTYPE;
  v_servicio   text := lower(btrim(coalesce(p_servicio, '')));
  v_actual     text;
  v_card_types constant text[] := ARRAY['cuban_card', 'clasica', 'tropical'];
  v_new_type   text;
  v_new_dm     text;
  v_fit        integer;
  v_mixed      integer;
  v_retired    uuid[];
  v_retyped    uuid[];
  v_before     jsonb;
  v_after      jsonb;
  v_single     remittance_beneficiaries%ROWTYPE;
BEGIN
  -- The callers have validated the service and the operation; they hold its row lock (taken again here, same transaction).
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  v_actual := cerebro_riel_op(p_operation_id);
  IF v_actual IS NOT DISTINCT FROM v_servicio THEN
    RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', false);
  END IF;

  v_new_type := CASE WHEN v_servicio IN ('recarga', 'combo', 'visa', 'saldo') THEN v_servicio ELSE 'remesa' END;
  v_new_dm   := CASE WHEN v_new_type = 'remesa' THEN v_servicio END;

  -- Which current recipients fit the new service (a card rail also takes multiple_distribution on CUP).
  SELECT count(*) INTO v_fit
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
     AND CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN b.beneficiary_type = ANY (v_card_types)
              WHEN v_servicio = 'zelle' THEN b.beneficiary_type = 'zelle'
              WHEN v_servicio = 'efectivo_usd' THEN b.beneficiary_type = 'efectivo_usd'
              WHEN v_servicio = 'combo' THEN b.beneficiary_type = 'combo'
              ELSE false END;

  -- Several card shares with their own amounts cannot move between CUP and USD: there is nothing to recompute them from.
  IF v_servicio IN ('cuban_card', 'clasica', 'tropical') AND v_fit > 1 THEN
    SELECT count(*) INTO v_mixed
      FROM remittance_beneficiaries b
     WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
       AND b.beneficiary_type = ANY (v_card_types)
       AND (b.beneficiary_type = 'cuban_card') <> (v_servicio = 'cuban_card');
    IF v_mixed > 0 THEN
      RAISE EXCEPTION 'several recipients with their own amounts cannot change between CUP and USD: correct them one by one' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_before := jsonb_build_object(
    'service', v_actual, 'service_type', v_op.service_type, 'delivery_method', v_op.delivery_method,
    'destination_currency', v_op.destination_currency, 'quoted_destination_amount', v_op.quoted_destination_amount,
    'combo_costo_gyd', v_op.combo_costo_gyd,
    'recipients', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'type', b.beneficiary_type) ORDER BY b.position), '[]'::jsonb)
                     FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente'));

  -- 1. The operation: new service, quote cleared, rail locked against the bot. The 096 guard locks the changed
  --    destination fields for a human writer; they are released right after (2).
  UPDATE remittance_operations
     SET service_type = v_new_type,
         delivery_method = v_new_dm,
         destination_currency = NULL,
         quoted_destination_amount = NULL,
         quoted_destination_rate = NULL,
         quoted_destination_origin = NULL,
         combo_costo_gyd = CASE WHEN v_new_type = 'combo' THEN combo_costo_gyd END,
         admin_locked_fields = coalesce(admin_locked_fields, '{}'::jsonb)
           || jsonb_build_object('delivery_method', jsonb_build_object('by', wacrm_current_actor(), 'at', now()),
                                 'service_type', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = p_operation_id;

  -- 2. The quote is calculated, not manual: release the destination locks so the calculation can write it.
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields - 'quoted_destination_amount' - 'destination_currency'
   WHERE id = p_operation_id;

  -- 3. Recipients that do not fit are retired.
  WITH r AS (
    UPDATE remittance_beneficiaries b
       SET status = 'reemplazado', replaced_at = now()
     WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
       AND NOT CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN b.beneficiary_type = ANY (v_card_types)
                    WHEN v_servicio = 'zelle' THEN b.beneficiary_type = 'zelle'
                    WHEN v_servicio = 'efectivo_usd' THEN b.beneficiary_type = 'efectivo_usd'
                    WHEN v_servicio = 'combo' THEN b.beneficiary_type = 'combo'
                    ELSE false END
    RETURNING b.id)
  SELECT coalesce(array_agg(id), ARRAY[]::uuid[]) INTO v_retired FROM r;

  -- 4. Recipients that fit: a card rail re-types the card; a lone recipient is priced again.
  IF v_servicio IN ('cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd') THEN
    WITH k AS (
      UPDATE remittance_beneficiaries b
         SET beneficiary_type = CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN v_servicio ELSE b.beneficiary_type END,
             amount = CASE WHEN v_fit = 1 THEN NULL ELSE b.amount END,
             currency = CASE WHEN v_fit = 1 THEN NULL ELSE b.currency END,
             amount_origin = CASE WHEN v_fit = 1 THEN NULL ELSE b.amount_origin END
       WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
         AND (v_fit = 1 OR (v_servicio IN ('cuban_card', 'clasica', 'tropical') AND b.beneficiary_type <> v_servicio))
         AND NOT (v_servicio = 'cuban_card' AND b.beneficiary_type = 'multiple_distribution')
      RETURNING b.id)
    SELECT coalesce(array_agg(id), ARRAY[]::uuid[]) INTO v_retyped FROM k;
  ELSE
    v_retyped := ARRAY[]::uuid[];
  END IF;

  -- 5. The existing calculation prices the operation again (the recipient triggers have already run it; this covers
  --    the case where nothing was re-typed). A lone recipient of an operation whose recipients were locked by an earlier
  --    correction does not get its amount from the calculation, so it takes the recalculated quote here.
  PERFORM crm_calcular_monto_destino(p_operation_id);
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF v_op.quoted_destination_origin = 'calculated' THEN
    SELECT * INTO v_single FROM remittance_beneficiaries
     WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type <> 'combo' ORDER BY position LIMIT 1;
    IF v_single.id IS NOT NULL
       AND (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente') = 1
       AND (v_single.amount IS DISTINCT FROM v_op.quoted_destination_amount
            OR v_single.currency IS DISTINCT FROM v_op.destination_currency) THEN
      UPDATE remittance_beneficiaries
         SET amount = v_op.quoted_destination_amount, currency = v_op.destination_currency, amount_origin = 'calculated'
       WHERE id = v_single.id;
    END IF;
  END IF;

  -- 6. The calculation's own writes were locked by the guard (the writer is a human): release them again.
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields - 'quoted_destination_amount' - 'destination_currency'
   WHERE id = p_operation_id
     AND admin_locked_fields ?| ARRAY['quoted_destination_amount', 'destination_currency'];

  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  v_after := jsonb_build_object(
    'service', v_servicio, 'service_type', v_op.service_type, 'delivery_method', v_op.delivery_method,
    'destination_currency', v_op.destination_currency, 'quoted_destination_amount', v_op.quoted_destination_amount,
    'combo_costo_gyd', v_op.combo_costo_gyd,
    'retired_recipients', to_jsonb(v_retired), 'retyped_recipients', to_jsonb(v_retyped));

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_op.account_id, 'remittance_operations', p_operation_id, 'service', p_audit_action,
          p_actor, p_reason, v_before, v_after);

  RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', true,
                            'retired', to_jsonb(v_retired), 'retyped', to_jsonb(v_retyped));
END $function$;

REVOKE ALL ON FUNCTION public._cambiar_servicio_core(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. The panel RPC: same validations, then the core
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_cambiar_servicio(p_operation_id uuid, p_servicio text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op         remittance_operations%ROWTYPE;
  v_servicio   text := lower(btrim(coalesce(p_servicio, '')));
  v_core       jsonb;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_op.account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to change the service of this operation' USING ERRCODE = '42501';
  END IF;

  IF v_op.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF v_servicio NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo') THEN
    RAISE EXCEPTION 'unknown service: %', p_servicio USING ERRCODE = '22023';
  END IF;

  IF v_op.service_type NOT IN ('remesa', 'recarga', 'combo', 'visa', 'saldo') THEN
    RAISE EXCEPTION 'the service of a % operation cannot be changed here', v_op.service_type USING ERRCODE = '22023';
  END IF;

  -- (230) The change itself is shared with the bot's cerebro_cambiar_servicio.
  v_core := _cambiar_servicio_core(p_operation_id, v_servicio, 'human_correction', wacrm_current_actor(), NULL);

  IF NOT (v_core ->> 'changed')::boolean THEN
    RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', false);
  END IF;

  RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', true,
                            'retired_recipients', jsonb_array_length(v_core -> 'retired'),
                            'retyped_recipients', jsonb_array_length(v_core -> 'retyped'));
END $function$;

REVOKE ALL ON FUNCTION public.crm_cambiar_servicio(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_cambiar_servicio(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 3. The bot's tool
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_cambiar_servicio(p_conversation_id uuid, p_servicio text, p_execution_id text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_actor      constant text := 'automation:cerebro_cambiar_servicio';
  v_raw        text := lower(btrim(coalesce(p_servicio, '')));
  v_servicio   text;
  v_ids        uuid[];
  v_op         uuid;
  v_o          remittance_operations%ROWTYPE;
  v_status     text;
  v_actual     text;
  v_key        text;
  v_core       jsonb;
  v_result     jsonb;
  v_min        numeric;
  v_n          integer;
  v_prev       jsonb;
  v_prev_origin text;
  v_prev_actor  text;
  v_campo      text;
BEGIN
  v_servicio := CASE v_raw WHEN 'cup' THEN 'cuban_card' WHEN 'efectivo' THEN 'efectivo_usd' ELSE v_raw END;

  <<flow>>
  BEGIN
    IF v_servicio NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo') THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'servicio_desconocido');
      EXIT flow;
    END IF;

    -- The conversation's open operation, the way the bot's other writers find it.
    SELECT coalesce(array_agg(o.id ORDER BY o.created_at), ARRAY[]::uuid[]) INTO v_ids
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer', 'incident');
    IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
      SELECT o.id, o.status INTO v_op, v_status
        FROM remittance_operations o WHERE o.conversation_id = p_conversation_id ORDER BY o.created_at DESC LIMIT 1;
      IF v_op IS NULL THEN
        v_result := jsonb_build_object('ok', false, 'reason', 'sin_operacion');
      ELSE
        v_result := jsonb_build_object('ok', false, 'reason', 'estado_no_permite', 'status', v_status, 'operation_id', v_op);
      END IF;
      EXIT flow;
    END IF;
    IF array_length(v_ids, 1) > 1 THEN
      -- The same hand-over as cerebro_marcar_destino_usd: several open operations need a person.
      SELECT count(*) INTO v_n FROM cerebro_registrar_derivacion(
        p_conversation_id, 'Hay varias operaciones abiertas y el caso requiere revisión humana.', 'operacion_ambigua', true);
      v_result := jsonb_build_object('ok', false, 'reason', 'operacion_ambigua', 'derivado', v_n > 0);
      EXIT flow;
    END IF;
    v_op := v_ids[1];

    -- Same row lock as the panel; the status is read again under it.
    SELECT * INTO v_o FROM remittance_operations WHERE id = v_op FOR UPDATE;
    IF v_o.status NOT IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer') THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'estado_no_permite', 'status', v_o.status, 'operation_id', v_op);
      EXIT flow;
    END IF;
    IF v_o.service_type NOT IN ('remesa', 'recarga', 'combo', 'visa', 'saldo') THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'tipo_no_soportado', 'service_type', v_o.service_type, 'operation_id', v_op);
      EXIT flow;
    END IF;

    v_actual := cerebro_riel_op(v_op);
    v_prev := jsonb_build_object('servicio', v_actual, 'destination_amount', v_o.quoted_destination_amount,
                                 'destination_currency', v_o.destination_currency, 'rate', v_o.quoted_destination_rate);
    IF v_actual IS NOT DISTINCT FROM v_servicio THEN
      v_result := jsonb_build_object('ok', true, 'changed', false, 'operation_id', v_op, 'servicio', v_servicio,
                                     'source_amount_gyd', v_o.quoted_source_amount, 'destination_amount', v_o.quoted_destination_amount,
                                     'destination_currency', v_o.destination_currency, 'rate', v_o.quoted_destination_rate,
                                     'status', v_o.status);
      EXIT flow;
    END IF;

    -- A human fixed it: leave it to the team. A lock the automation itself left does not count.
    SELECT k INTO v_campo
      FROM unnest(ARRAY['delivery_method', 'service_type', 'quoted_destination_amount']) AS k
     WHERE coalesce(v_o.admin_locked_fields, '{}'::jsonb) ? k
       AND coalesce(v_o.admin_locked_fields -> k ->> 'by', '') NOT LIKE 'automation:%'
     LIMIT 1;
    IF v_campo IS NOT NULL THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'bloqueado_por_humano', 'campo', v_campo, 'operation_id', v_op);
      EXIT flow;
    END IF;

    -- The change, with the minimum of the NEW service checked on the changed operation; a failure rolls the sub-block back.
    v_prev_origin := coalesce(current_setting('wacrm.origin', true), '');
    v_prev_actor  := coalesce(current_setting('wacrm.actor', true), '');
    BEGIN
      PERFORM set_config('wacrm.origin', 'admin', true);
      PERFORM set_config('wacrm.actor', c_actor, true);
      v_core := _cambiar_servicio_core(v_op, v_servicio, 'automation_service_change', c_actor,
                                       'n8n execution ' || coalesce(nullif(btrim(p_execution_id), ''), 'unknown'));
      PERFORM set_config('wacrm.origin', v_prev_origin, true);
      PERFORM set_config('wacrm.actor', v_prev_actor, true);
      SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
      v_min := cerebro_minimo_gyd(v_op);
      IF coalesce(v_o.quoted_source_amount, 0) > 0 AND v_min IS NOT NULL AND v_o.quoted_source_amount < v_min THEN
        RAISE EXCEPTION '%', v_min USING ERRCODE = 'WC230';
      END IF;
    EXCEPTION
      WHEN SQLSTATE 'WC230' THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        v_result := jsonb_build_object('ok', false, 'reason', 'por_debajo_del_minimo', 'servicio', v_servicio, 'operation_id', v_op,
                                       'minimo_gyd', SQLERRM::numeric, 'source_amount_gyd', v_o.quoted_source_amount);
      WHEN SQLSTATE '22023' THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        IF SQLERRM NOT LIKE 'several recipients%' THEN RAISE; END IF;
        v_result := jsonb_build_object('ok', false, 'reason', 'varios_destinatarios', 'operation_id', v_op);
      WHEN OTHERS THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        RAISE;
    END;
    IF v_result IS NOT NULL THEN
      EXIT flow;
    END IF;

    SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
    v_result := jsonb_build_object('ok', true, 'changed', true, 'operation_id', v_op, 'servicio', v_servicio,
                                   'source_amount_gyd', v_o.quoted_source_amount, 'destination_amount', v_o.quoted_destination_amount,
                                   'destination_currency', v_o.destination_currency, 'rate', v_o.quoted_destination_rate,
                                   'previous', v_prev,
                                   'retired_recipients', jsonb_array_length(v_core -> 'retired'),
                                   'retyped_recipients', jsonb_array_length(v_core -> 'retyped'),
                                   'status', v_o.status);
  END;

  v_key := coalesce(nullif(btrim(p_execution_id), ''), gen_random_uuid()::text) || ':cambiar_servicio:' || md5(coalesce(v_servicio, ''));
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments, outcome)
  VALUES (v_key, 'cambiar_servicio', p_execution_id, p_conversation_id, v_op, jsonb_build_array(to_jsonb(p_servicio)),
          CASE WHEN (v_result ->> 'ok')::boolean THEN CASE WHEN (v_result ->> 'changed')::boolean THEN 'changed' ELSE 'unchanged' END
               ELSE v_result ->> 'reason' END)
  ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN v_result;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_cambiar_servicio(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_cambiar_servicio(uuid, text, text) TO service_role;
