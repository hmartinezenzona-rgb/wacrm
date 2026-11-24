-- 394: crm_editar_reparto replaces the card shares of an operation (a multiple transfer, "reparto") in ONE atomic, audited step
-- (T1 of odd/tasks/editar-reparto.md).
--
-- Until now the panel edited the shares one by one (crm_corregir_beneficiario / crm_agregar_beneficiario / crm_quitar_beneficiario):
-- N saves for N edits, an inconsistent split in between, and nothing checked that the shares add up to the operation's destination total.
-- This function takes the whole new split and applies it in one transaction:
--   * p_partes is a JSON array of shares {id (existing current share, or null for a new one), beneficiary_type, name, card_number, phone,
--     amount, currency}; card rails only (cuban_card, clasica, tropical, multiple_distribution); at least 2 shares.
--   * The sum of the amounts must equal quoted_destination_amount exactly, otherwise nothing changes (22023, both numbers in the message).
--   * Current shares not listed are retired; listed shares whose fields changed are retired and re-inserted (source 'admin_correction',
--     amount_origin 'manual'); unchanged ones keep their row and id (their position is moved in place when the slot is free); new ones are
--     inserted (source 'admin_addition'). Positions end up 1..N in the given order.
--   * Same auth, closed-operation rule (owner/admin only, extra 'human_closed_operation_edit' audit row), lock (admin_locked_fields.beneficiaries)
--     and audit style as the sibling panel functions (377/383). One 'human_correction' audit row with the before / after of the shares.
--   * The destination recalculation (crm_calcular_monto_destino) is suspended inside the call: a transient single-share state must not
--     clear or rewrite the total the sum was checked against.
-- Zelle is not a card rail (it takes zelle_account, USD, one recipient per tier) and is refused: edit it with the single-share functions.
-- No new audit action and no table change: only a new function. Needs 383 (_crm_auditar_edicion_cerrada).

CREATE OR REPLACE FUNCTION public.crm_editar_reparto(p_operation_id uuid, p_partes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id   uuid;
  v_op_status    text;
  v_service      text;
  v_total        numeric;
  v_dest_cur     text;
  v_items        jsonb[] := ARRAY[]::jsonb[];
  v_item         jsonb;
  v_el           jsonb;
  v_ord          integer;
  v_key          text;
  v_id           uuid;
  v_ids          uuid[] := ARRAY[]::uuid[];
  v_type         text;
  v_name         text;
  v_card         text;
  v_phone        text;
  v_phone_norm   text;
  v_amount       numeric;
  v_currency     text;
  v_sum          numeric := 0;
  v_old          remittance_beneficiaries%ROWTYPE;
  v_new_id       uuid;
  v_next_block   integer;
  v_prev_calc    text;
  v_before       jsonb;
  v_after        jsonb;
  v_retired      uuid[] := ARRAY[]::uuid[];
  v_created      uuid[] := ARRAY[]::uuid[];
  v_kept         uuid[] := ARRAY[]::uuid[];
  v_changed      boolean;
  v_row          record;
BEGIN
  SELECT account_id, status, service_type, quoted_destination_amount, destination_currency
    INTO v_account_id, v_op_status, v_service, v_total, v_dest_cur
    FROM remittance_operations
   WHERE id = p_operation_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to edit the split of this operation' USING ERRCODE = '42501';
  END IF;

  IF v_op_status IN ('completed', 'cancelled') THEN
    -- (383) An owner or an admin may edit a closed operation (its data, not the money); an agent may not.
    IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
      RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
    END IF;
    PERFORM _crm_auditar_edicion_cerrada(v_account_id, p_operation_id, 'crm_editar_reparto');
  END IF;

  IF v_service IS DISTINCT FROM 'remesa' THEN
    RAISE EXCEPTION 'the split can only be edited on a remesa operation' USING ERRCODE = '22023';
  END IF;

  IF p_partes IS NULL OR jsonb_typeof(p_partes) <> 'array' THEN
    RAISE EXCEPTION 'partes must be a JSON array of shares' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_partes) < 2 THEN
    RAISE EXCEPTION 'a split needs at least 2 shares' USING ERRCODE = '22023';
  END IF;

  IF v_total IS NULL THEN
    RAISE EXCEPTION 'the operation has no destination total: set the total first' USING ERRCODE = '22023';
  END IF;
  IF v_dest_cur IS NULL THEN
    RAISE EXCEPTION 'the operation has no destination currency: set it first' USING ERRCODE = '22023';
  END IF;

  -- Lock the current shares; a recipient that is not a card share (Zelle, cash, Mexico, ...) is out of scope for this edit.
  FOR v_row IN SELECT id, beneficiary_type FROM remittance_beneficiaries
                WHERE operation_id = p_operation_id AND status = 'vigente' FOR UPDATE LOOP
    IF v_row.beneficiary_type NOT IN ('cuban_card', 'clasica', 'tropical', 'multiple_distribution') THEN
      RAISE EXCEPTION 'the operation has a % recipient: only card splits can be edited here', v_row.beneficiary_type USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Validate and normalize every share; nothing is written yet.
  FOR v_el, v_ord IN SELECT e.value, e.ordinality::integer FROM jsonb_array_elements(p_partes) WITH ORDINALITY AS e LOOP
    IF jsonb_typeof(v_el) <> 'object' THEN
      RAISE EXCEPTION 'share % must be a JSON object', v_ord USING ERRCODE = '22023';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(v_el) LOOP
      IF v_key NOT IN ('id', 'beneficiary_type', 'name', 'card_number', 'phone', 'amount', 'currency') THEN
        RAISE EXCEPTION 'share %: unknown field: %', v_ord, v_key USING ERRCODE = '22023';
      END IF;
    END LOOP;

    v_id := NULL;
    IF v_el ? 'id' AND jsonb_typeof(v_el -> 'id') <> 'null' THEN
      IF jsonb_typeof(v_el -> 'id') <> 'string' OR (v_el ->> 'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RAISE EXCEPTION 'share %: id must be a uuid or null', v_ord USING ERRCODE = '22023';
      END IF;
      v_id := (v_el ->> 'id')::uuid;
      IF v_id = ANY (v_ids) THEN
        RAISE EXCEPTION 'share %: the same share is listed twice', v_ord USING ERRCODE = '22023';
      END IF;
      v_ids := v_ids || v_id;
      IF NOT EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE id = v_id AND operation_id = p_operation_id AND status = 'vigente') THEN
        RAISE EXCEPTION 'share %: beneficiary does not belong to this operation or is not current', v_ord USING ERRCODE = '22023';
      END IF;
    END IF;

    v_type := v_el ->> 'beneficiary_type';
    IF v_type IS NULL OR v_type NOT IN ('cuban_card', 'clasica', 'tropical', 'multiple_distribution') THEN
      RAISE EXCEPTION 'share %: invalid beneficiary_type: % (a split takes card rails only)', v_ord, v_type USING ERRCODE = '22023';
    END IF;

    v_name := nullif(btrim(coalesce(v_el ->> 'name', '')), '');

    v_card := regexp_replace(coalesce(v_el ->> 'card_number', ''), '[ -]', '', 'g');
    IF v_card !~ '^[0-9]{16}$' THEN
      RAISE EXCEPTION 'share %: card_number must be exactly 16 digits', v_ord USING ERRCODE = '22023';
    END IF;

    -- The phone is optional (190). A Cuban mobile is normalized to its 8 digits; any other phone must be 8 to 15 digits.
    v_phone := nullif(regexp_replace(coalesce(v_el ->> 'phone', ''), '[^0-9]', '', 'g'), '');
    IF v_phone IS NOT NULL THEN
      v_phone_norm := cerebro_norm_celular_cu(v_phone);
      IF coalesce(v_phone_norm, '') ~ '^[0-9]{8}$' THEN
        v_phone := v_phone_norm;
      ELSIF v_phone !~ '^[0-9]{8,15}$' THEN
        RAISE EXCEPTION 'share %: phone must be 8 to 15 digits', v_ord USING ERRCODE = '22023';
      END IF;
    END IF;

    IF NOT (v_el ? 'amount') OR jsonb_typeof(v_el -> 'amount') NOT IN ('number', 'string')
       OR (v_el ->> 'amount') !~ '^[0-9]+(\.[0-9]+)?$' OR (v_el ->> 'amount')::numeric <= 0 THEN
      RAISE EXCEPTION 'share %: amount is required and must be greater than 0', v_ord USING ERRCODE = '22023';
    END IF;
    v_amount := (v_el ->> 'amount')::numeric;

    v_currency := coalesce(nullif(v_el ->> 'currency', ''), v_dest_cur);
    IF v_currency <> v_dest_cur THEN
      RAISE EXCEPTION 'share %: currency % does not match the operation''s destination currency %', v_ord, v_currency, v_dest_cur USING ERRCODE = '22023';
    END IF;

    v_sum := v_sum + v_amount;
    v_items := v_items || jsonb_build_object('id', v_id, 'beneficiary_type', v_type, 'name', v_name, 'card_number', v_card,
                                             'phone', v_phone, 'amount', v_amount, 'currency', v_currency);
  END LOOP;

  IF v_sum <> v_total THEN
    RAISE EXCEPTION 'the shares add up to % but the operation total is % (difference %)', v_sum, v_total, v_sum - v_total USING ERRCODE = '22023';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'beneficiary_type', b.beneficiary_type, 'name', b.name, 'card_number', b.card_number,
                                               'phone', b.phone, 'amount', b.amount, 'currency', b.currency, 'position', b.position)
                            ORDER BY b.position), '[]'::jsonb)
    INTO v_before
    FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente';

  -- Suspend the destination recalculation for this transaction: the trigger on the shares would clear or rewrite the total
  -- when a transient state has a single share (crm_calcular_monto_destino, recursion guard).
  v_prev_calc := coalesce(current_setting('wacrm.calc_destino', true), 'off');
  PERFORM set_config('wacrm.calc_destino', 'on', true);

  -- Retire the current shares that are not listed.
  FOR v_row IN SELECT id FROM remittance_beneficiaries
                WHERE operation_id = p_operation_id AND status = 'vigente' AND NOT (id = ANY (v_ids)) LOOP
    UPDATE remittance_beneficiaries SET status = 'reemplazado', replaced_at = now() WHERE id = v_row.id;
    v_retired := v_retired || v_row.id;
  END LOOP;

  SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block FROM remittance_beneficiaries WHERE operation_id = p_operation_id;

  v_ord := 0;
  FOREACH v_item IN ARRAY v_items LOOP
    v_ord := v_ord + 1;
    v_id := nullif(v_item ->> 'id', '')::uuid;

    IF v_id IS NULL THEN
      INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, amount_origin,
                                            position, status, source, block_index)
      VALUES (p_operation_id, v_item ->> 'beneficiary_type', v_item ->> 'name', v_item ->> 'card_number', v_item ->> 'phone',
              (v_item ->> 'amount')::numeric, v_item ->> 'currency', 'manual', v_ord, 'vigente', 'admin_addition', v_next_block)
      RETURNING id INTO v_new_id;
      v_next_block := v_next_block + 1;
      v_created := v_created || v_new_id;
      CONTINUE;
    END IF;

    SELECT * INTO v_old FROM remittance_beneficiaries WHERE id = v_id;
    v_changed := v_old.beneficiary_type IS DISTINCT FROM (v_item ->> 'beneficiary_type')
              OR v_old.name IS DISTINCT FROM (v_item ->> 'name')
              OR v_old.card_number IS DISTINCT FROM (v_item ->> 'card_number')
              OR v_old.phone IS DISTINCT FROM (v_item ->> 'phone')
              OR v_old.amount IS DISTINCT FROM (v_item ->> 'amount')::numeric
              OR v_old.currency IS DISTINCT FROM (v_item ->> 'currency');

    IF NOT v_changed AND v_old.position = v_ord THEN
      v_kept := v_kept || v_id;
    ELSIF NOT v_changed AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b
                                         WHERE b.operation_id = p_operation_id AND b.block_index = v_old.block_index
                                           AND b.position = v_ord AND b.id <> v_id) THEN
      -- Only the position moves, and its slot is free: the row stays (same id).
      UPDATE remittance_beneficiaries SET position = v_ord WHERE id = v_id;
      v_kept := v_kept || v_id;
    ELSE
      UPDATE remittance_beneficiaries SET status = 'reemplazado', replaced_at = now() WHERE id = v_id;
      v_retired := v_retired || v_id;
      -- Columns the split does not edit are carried over from the retired row.
      INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, zelle_account, delivery_method,
                                            amount, currency, amount_origin, position, status, source, block_index,
                                            address, reference, contact_phone, id_photo_wamid, clabe, bank_name)
      VALUES (p_operation_id, v_item ->> 'beneficiary_type', v_item ->> 'name', v_item ->> 'card_number', v_item ->> 'phone',
              v_old.zelle_account, v_old.delivery_method, (v_item ->> 'amount')::numeric, v_item ->> 'currency', 'manual',
              v_ord, 'vigente', 'admin_correction', v_next_block,
              v_old.address, v_old.reference, v_old.contact_phone, v_old.id_photo_wamid, v_old.clabe, v_old.bank_name)
      RETURNING id INTO v_new_id;
      v_next_block := v_next_block + 1;
      v_created := v_created || v_new_id;
    END IF;
  END LOOP;

  PERFORM set_config('wacrm.calc_destino', v_prev_calc, true);

  -- Lock the recipients of this operation so automation does not overwrite the split (098).
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields ||
         jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = p_operation_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'beneficiary_type', b.beneficiary_type, 'name', b.name, 'card_number', b.card_number,
                                               'phone', b.phone, 'amount', b.amount, 'currency', b.currency, 'position', b.position)
                            ORDER BY b.position), '[]'::jsonb)
    INTO v_after
    FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente';

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'beneficiaries', 'human_correction', wacrm_current_actor(), v_before, v_after);

  RETURN jsonb_build_object(
    'operation_id', p_operation_id,
    'retired', to_jsonb(v_retired),
    'created', to_jsonb(v_created),
    'kept', to_jsonb(v_kept),
    'complete', crm_beneficiarios_completos(p_operation_id)
  );
END $function$;

REVOKE ALL ON FUNCTION public.crm_editar_reparto(uuid, jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.crm_editar_reparto(uuid, jsonb) TO authenticated;
