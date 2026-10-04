-- =====================================================================
-- 212 — Editing and moving a combo recipient from the panel
--
-- odd/tasks/combos-end-to-end.md (follow-up). crm_corregir_beneficiario and crm_reasignar_beneficiario wrote the new
-- row with the remesa columns only: a combo recipient lost its address, reference and contact phone (and a cash
-- recipient its address and ID photo), so the panel hid Edit and Move on combo cards.
--   * crm_corregir_beneficiario: accepts address, reference and contact_phone (combo; the address also for cash);
--     refuses card, Zelle, delivery method, currency and type changes on a combo recipient; carries every untouched
--     column over; keeps a combo's total = the sum of its recipients.
--   * crm_reasignar_beneficiario: a combo recipient moves only between combos (and nothing else into a combo); every
--     column moves with it; both combos' totals follow.
-- Everything else in both bodies is unchanged (see the ROLLBACK).
-- Assertion: supabase/staging/assertions/combo-edit.sql. Rollback: ROLLBACK-212-combo-edit.sql.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.crm_corregir_beneficiario(p_beneficiary_id uuid, p_cambios jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_old               remittance_beneficiaries%ROWTYPE;
  v_op_id              uuid;
  v_account_id         uuid;
  v_op_status          text;
  v_key                text;
  v_new_id             uuid;
  v_next_block_index   integer;
  v_before             jsonb := '{}'::jsonb;
  v_after              jsonb := '{}'::jsonb;
  v_field_names        text;
  v_name               text;
  v_card_number        text;
  v_phone              text;
  v_zelle_account      text;
  v_delivery_method    text;
  v_amount             numeric;
  v_currency           text;
  v_beneficiary_type   text;
BEGIN
  SELECT * INTO v_old FROM remittance_beneficiaries WHERE id = p_beneficiary_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'beneficiary not found' USING ERRCODE = 'P0002';
  END IF;
  v_op_id := v_old.operation_id;

  IF v_old.status <> 'vigente' THEN
    RAISE EXCEPTION 'beneficiary is not current' USING ERRCODE = '22023';
  END IF;

  SELECT account_id, status INTO v_account_id, v_op_status
    FROM remittance_operations
   WHERE id = v_op_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to correct this beneficiary' USING ERRCODE = '42501';
  END IF;

  IF v_op_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF p_cambios IS NULL OR p_cambios = '{}'::jsonb THEN
    RAISE EXCEPTION 'no changes provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_cambios) LOOP
    IF v_key NOT IN ('name', 'card_number', 'phone', 'zelle_account', 'delivery_method',
                      'amount', 'currency', 'beneficiary_type', 'address', 'reference', 'contact_phone') THEN
      RAISE EXCEPTION 'unknown field: %', v_key USING ERRCODE = '22023';
    END IF;
    -- (212) A combo recipient takes its own fields only: no card, Zelle, delivery method, currency or type change
    -- (a combo is GYD). Reference and contact phone belong to combo recipients; the address also to cash ones.
    IF v_old.beneficiary_type = 'combo'
       AND v_key IN ('card_number', 'zelle_account', 'delivery_method', 'currency', 'beneficiary_type') THEN
      RAISE EXCEPTION 'field % does not apply to a combo recipient', v_key USING ERRCODE = '22023';
    END IF;
    IF v_old.beneficiary_type <> 'combo' AND v_key IN ('reference', 'contact_phone') THEN
      RAISE EXCEPTION 'field % is for combo recipients', v_key USING ERRCODE = '22023';
    END IF;
    IF v_old.beneficiary_type NOT IN ('combo', 'efectivo_usd') AND v_key = 'address' THEN
      RAISE EXCEPTION 'field address is for combo and cash recipients' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  IF p_cambios ? 'contact_phone' AND p_cambios->>'contact_phone' IS NOT NULL
     AND p_cambios->>'contact_phone' !~ '^[0-9]{8,15}$' THEN
    RAISE EXCEPTION 'contact_phone must be 8 to 15 digits' USING ERRCODE = '22023';
  END IF;

  -- card_number / phone / amount / currency may be explicitly cleared to
  -- null; when present they must be well-formed. beneficiary_type may not
  -- be null and must be one of the known types.
  IF p_cambios ? 'card_number' AND p_cambios->>'card_number' IS NOT NULL
     AND p_cambios->>'card_number' !~ '^[0-9]{16}$' THEN
    RAISE EXCEPTION 'card_number must be exactly 16 digits' USING ERRCODE = '22023';
  END IF;

  IF p_cambios ? 'phone' AND p_cambios->>'phone' IS NOT NULL
     AND p_cambios->>'phone' !~ '^[0-9]{8,15}$' THEN
    RAISE EXCEPTION 'phone must be 8 to 15 digits' USING ERRCODE = '22023';
  END IF;

  IF p_cambios ? 'amount' AND p_cambios->>'amount' IS NOT NULL
     AND (p_cambios->>'amount')::numeric <= 0 THEN
    RAISE EXCEPTION 'amount must be greater than 0' USING ERRCODE = '22023';
  END IF;

  IF p_cambios ? 'currency' AND p_cambios->>'currency' IS NOT NULL
     AND p_cambios->>'currency' !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'currency must be a 3-letter uppercase code' USING ERRCODE = '22023';
  END IF;

  IF p_cambios ? 'beneficiary_type' THEN
    IF p_cambios->>'beneficiary_type' IS NULL
       OR p_cambios->>'beneficiary_type' NOT IN
          ('cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution') THEN
      RAISE EXCEPTION 'invalid beneficiary_type: %', p_cambios->>'beneficiary_type' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Resolve the new row's values: overridden by p_cambios, falling back to the old row.
  v_name             := CASE WHEN p_cambios ? 'name' THEN p_cambios->>'name' ELSE v_old.name END;
  v_card_number      := CASE WHEN p_cambios ? 'card_number' THEN p_cambios->>'card_number' ELSE v_old.card_number END;
  v_phone            := CASE WHEN p_cambios ? 'phone' THEN p_cambios->>'phone' ELSE v_old.phone END;
  v_zelle_account    := CASE WHEN p_cambios ? 'zelle_account' THEN p_cambios->>'zelle_account' ELSE v_old.zelle_account END;
  v_delivery_method  := CASE WHEN p_cambios ? 'delivery_method' THEN p_cambios->>'delivery_method' ELSE v_old.delivery_method END;
  v_amount           := CASE WHEN p_cambios ? 'amount' THEN (p_cambios->>'amount')::numeric ELSE v_old.amount END;
  v_currency         := CASE WHEN p_cambios ? 'currency' THEN p_cambios->>'currency' ELSE v_old.currency END;
  v_beneficiary_type := CASE WHEN p_cambios ? 'beneficiary_type' THEN p_cambios->>'beneficiary_type' ELSE v_old.beneficiary_type END;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = now()
   WHERE id = p_beneficiary_id;

  SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
    FROM remittance_beneficiaries WHERE operation_id = v_op_id;

  -- (212) Every column the correction does not touch is carried over: the combo's address, reference and contact
  -- phone, the cash recipient's address and ID photo, and the amount's origin when the amount is kept.
  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone, zelle_account,
    delivery_method, amount, currency, position, status, source, block_index,
    address, reference, contact_phone, id_photo_wamid, amount_origin
  ) VALUES (
    v_op_id, v_beneficiary_type, v_name, v_card_number, v_phone, v_zelle_account,
    v_delivery_method, v_amount, v_currency, v_old.position, 'vigente', 'admin_correction', v_next_block_index,
    CASE WHEN p_cambios ? 'address' THEN nullif(btrim(p_cambios->>'address'), '') ELSE v_old.address END,
    CASE WHEN p_cambios ? 'reference' THEN nullif(btrim(p_cambios->>'reference'), '') ELSE v_old.reference END,
    CASE WHEN p_cambios ? 'contact_phone' THEN p_cambios->>'contact_phone' ELSE v_old.contact_phone END,
    v_old.id_photo_wamid,
    CASE WHEN p_cambios ? 'amount' THEN 'manual' ELSE v_old.amount_origin END
  ) RETURNING id INTO v_new_id;

  -- (212) A combo's total is the sum of its recipients' amounts.
  UPDATE remittance_operations o
     SET quoted_source_amount = (SELECT coalesce(sum(b.amount), 0) FROM remittance_beneficiaries b
                                  WHERE b.operation_id = o.id AND b.status = 'vigente' AND b.beneficiary_type = 'combo')
   WHERE o.id = v_op_id AND o.service_type = 'combo';

  -- Lock beneficiaries on this operation so automation stops overwriting them.
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields ||
         jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = v_op_id;

  SELECT string_agg(k, ',' ORDER BY k) INTO v_field_names FROM jsonb_object_keys(p_cambios) AS k;

  FOR v_key IN SELECT jsonb_object_keys(p_cambios) LOOP
    v_before := v_before || jsonb_build_object(v_key,
      CASE v_key
        WHEN 'name' THEN to_jsonb(v_old.name)
        WHEN 'card_number' THEN to_jsonb(v_old.card_number)
        WHEN 'phone' THEN to_jsonb(v_old.phone)
        WHEN 'zelle_account' THEN to_jsonb(v_old.zelle_account)
        WHEN 'delivery_method' THEN to_jsonb(v_old.delivery_method)
        WHEN 'amount' THEN to_jsonb(v_old.amount)
        WHEN 'currency' THEN to_jsonb(v_old.currency)
        WHEN 'beneficiary_type' THEN to_jsonb(v_old.beneficiary_type)
        WHEN 'address' THEN to_jsonb(v_old.address)
        WHEN 'reference' THEN to_jsonb(v_old.reference)
        WHEN 'contact_phone' THEN to_jsonb(v_old.contact_phone)
      END);
    v_after := v_after || jsonb_build_object(v_key, p_cambios -> v_key);
  END LOOP;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, v_field_names, 'human_correction',
          wacrm_current_actor(), v_before, v_after);

  RETURN v_new_id;
END $function$;

CREATE OR REPLACE FUNCTION public.crm_reasignar_beneficiario(p_beneficiary_id uuid, p_target_operation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_old                   remittance_beneficiaries%ROWTYPE;
  v_src_op_id              uuid;
  v_src_account_id         uuid;
  v_src_conversation_id    uuid;
  v_src_status             text;
  v_tgt_account_id         uuid;
  v_tgt_conversation_id    uuid;
  v_tgt_status             text;
  v_new_id                 uuid;
  v_next_position          integer;
  v_next_block_index       integer;
BEGIN
  SELECT * INTO v_old FROM remittance_beneficiaries WHERE id = p_beneficiary_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'beneficiary not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_old.status <> 'vigente' THEN
    RAISE EXCEPTION 'beneficiary is not current' USING ERRCODE = '22023';
  END IF;
  v_src_op_id := v_old.operation_id;

  SELECT account_id, conversation_id, status INTO v_src_account_id, v_src_conversation_id, v_src_status
    FROM remittance_operations WHERE id = v_src_op_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'source operation not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT account_id, conversation_id, status INTO v_tgt_account_id, v_tgt_conversation_id, v_tgt_status
    FROM remittance_operations WHERE id = p_target_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'target operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_tgt_account_id IS DISTINCT FROM v_src_account_id
     OR v_tgt_conversation_id IS DISTINCT FROM v_src_conversation_id THEN
    RAISE EXCEPTION 'target operation must belong to the same account and conversation' USING ERRCODE = '22023';
  END IF;

  IF v_src_status IN ('completed', 'cancelled') OR v_tgt_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF p_target_operation_id = v_src_op_id THEN
    RAISE EXCEPTION 'target operation must differ from the source operation' USING ERRCODE = '22023';
  END IF;

  -- (212) A combo recipient moves only between combos, and nothing else moves into a combo.
  IF (v_old.beneficiary_type = 'combo') <> ((SELECT service_type FROM remittance_operations WHERE id = p_target_operation_id) = 'combo') THEN
    RAISE EXCEPTION 'a combo recipient moves only between combo operations' USING ERRCODE = '22023';
  END IF;

  IF NOT is_account_member(v_src_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to reassign this beneficiary' USING ERRCODE = '42501';
  END IF;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = now()
   WHERE id = p_beneficiary_id;

  SELECT coalesce(max(position), 0) + 1 INTO v_next_position
    FROM remittance_beneficiaries WHERE operation_id = p_target_operation_id AND status = 'vigente';

  SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block_index
    FROM remittance_beneficiaries WHERE operation_id = p_target_operation_id;

  -- (212) Every column moves with it (combo and cash fields included).
  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone, zelle_account,
    delivery_method, amount, currency, position, status, source, block_index,
    address, reference, contact_phone, id_photo_wamid, amount_origin
  ) VALUES (
    p_target_operation_id, v_old.beneficiary_type, v_old.name, v_old.card_number, v_old.phone, v_old.zelle_account,
    v_old.delivery_method, v_old.amount, v_old.currency, v_next_position, 'vigente', 'admin_reassignment', v_next_block_index,
    v_old.address, v_old.reference, v_old.contact_phone, v_old.id_photo_wamid, v_old.amount_origin
  ) RETURNING id INTO v_new_id;

  -- (212) Both combos' totals follow their recipients.
  UPDATE remittance_operations o
     SET quoted_source_amount = (SELECT coalesce(sum(b.amount), 0) FROM remittance_beneficiaries b
                                  WHERE b.operation_id = o.id AND b.status = 'vigente' AND b.beneficiary_type = 'combo')
   WHERE o.id IN (v_src_op_id, p_target_operation_id) AND o.service_type = 'combo';

  -- Lock beneficiaries on both operations: the source no longer has this
  -- beneficiary because of a human decision, and the target now holds one
  -- because of a human decision too.
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields ||
         jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id IN (v_src_op_id, p_target_operation_id);

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_src_account_id, 'remittance_beneficiaries', v_new_id, 'operation_id', 'human_reassignment',
          wacrm_current_actor(), jsonb_build_object('operation_id', v_src_op_id),
          jsonb_build_object('operation_id', p_target_operation_id));

  RETURN v_new_id;
END $function$;
