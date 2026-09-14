-- =====================================================================
-- 098 — Operator correction and reassignment RPCs
--
-- Gives agents (and above) three explicit, audited ways to correct a
-- remittance operation after it has left automation's hands, instead of
-- going through a raw UPDATE:
--
--   crm_corregir_operacion(operation_id, cambios)    -- fix operation fields
--   crm_corregir_beneficiario(beneficiary_id, cambios) -- fix a beneficiary
--   crm_reasignar_beneficiario(beneficiary_id, target_operation_id)
--
-- Beneficiary corrections and reassignments are append-only: the old row
-- is marked 'reemplazado', a new 'vigente' row is inserted. Both also lock
-- the 'beneficiaries' key on remittance_operations.admin_locked_fields, so
-- cerebro_sync_beneficiarios() (042) — the automation path that parses
-- deals.notes into remittance_beneficiaries — stops touching that
-- operation's beneficiaries once a human has corrected them, mirroring how
-- 096 already protects individual remittance_operations columns.
--
-- ROLLBACK: see ROLLBACK-098-operator-corrections-rpcs.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Audit action vocabulary: add the two new human-initiated actions.
-- ---------------------------------------------------------------------

ALTER TABLE remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit
  ADD CONSTRAINT remittance_admin_audit_action_chk
  CHECK (action IN (
    'automation_write_suppressed',
    'automation_completion_suppressed',
    'automation_revert_suppressed',
    'human_correction',
    'human_reassignment'
  ));


-- ---------------------------------------------------------------------
-- 2. crm_corregir_operacion — correct operation-level fields.
-- ---------------------------------------------------------------------
-- Only the fields the 096 lock trigger already tracks may be corrected
-- here. The lock itself is applied by that existing trigger the moment
-- this function's UPDATE runs under a human JWT — this function does not
-- need to touch admin_locked_fields directly.

CREATE OR REPLACE FUNCTION crm_corregir_operacion(p_operation_id uuid, p_cambios jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id uuid;
  v_status     text;
  v_key        text;
  v_before_destination_currency       text;
  v_before_delivery_method            text;
  v_before_deposit_method             text;
  v_before_quoted_source_amount       numeric;
  v_before_quoted_destination_amount  numeric;
  v_after_destination_currency        text;
  v_after_delivery_method             text;
  v_after_deposit_method              text;
  v_after_quoted_source_amount        numeric;
  v_after_quoted_destination_amount   numeric;
BEGIN
  SELECT account_id, status,
         destination_currency, delivery_method, deposit_method,
         quoted_source_amount, quoted_destination_amount
    INTO v_account_id, v_status,
         v_before_destination_currency, v_before_delivery_method, v_before_deposit_method,
         v_before_quoted_source_amount, v_before_quoted_destination_amount
    FROM remittance_operations
   WHERE id = p_operation_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to correct this operation' USING ERRCODE = '42501';
  END IF;

  IF v_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF p_cambios IS NULL OR p_cambios = '{}'::jsonb THEN
    RAISE EXCEPTION 'no changes provided' USING ERRCODE = '22023';
  END IF;

  -- Reject unknown keys up front.
  FOR v_key IN SELECT jsonb_object_keys(p_cambios) LOOP
    IF v_key NOT IN ('destination_currency', 'delivery_method', 'deposit_method',
                      'quoted_source_amount', 'quoted_destination_amount') THEN
      RAISE EXCEPTION 'unknown field: %', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Validate provided values. None of these fields may be corrected to null.
  IF p_cambios ? 'quoted_source_amount' THEN
    IF p_cambios->>'quoted_source_amount' IS NULL
       OR (p_cambios->>'quoted_source_amount')::numeric <= 0 THEN
      RAISE EXCEPTION 'quoted_source_amount must be greater than 0' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_cambios ? 'quoted_destination_amount' THEN
    IF p_cambios->>'quoted_destination_amount' IS NULL
       OR (p_cambios->>'quoted_destination_amount')::numeric <= 0 THEN
      RAISE EXCEPTION 'quoted_destination_amount must be greater than 0' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_cambios ? 'destination_currency' THEN
    IF p_cambios->>'destination_currency' IS NULL
       OR p_cambios->>'destination_currency' !~ '^[A-Z]{3}$' THEN
      RAISE EXCEPTION 'destination_currency must be a 3-letter uppercase code' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_cambios ? 'delivery_method' THEN
    IF p_cambios->>'delivery_method' IS NULL
       OR btrim(p_cambios->>'delivery_method') = '' THEN
      RAISE EXCEPTION 'delivery_method must not be empty' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_cambios ? 'deposit_method' THEN
    IF p_cambios->>'deposit_method' IS NULL
       OR btrim(p_cambios->>'deposit_method') = '' THEN
      RAISE EXCEPTION 'deposit_method must not be empty' USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE remittance_operations
     SET destination_currency = CASE WHEN p_cambios ? 'destination_currency'
                                      THEN p_cambios->>'destination_currency'
                                      ELSE destination_currency END,
         delivery_method = CASE WHEN p_cambios ? 'delivery_method'
                                 THEN p_cambios->>'delivery_method'
                                 ELSE delivery_method END,
         deposit_method = CASE WHEN p_cambios ? 'deposit_method'
                                THEN p_cambios->>'deposit_method'
                                ELSE deposit_method END,
         quoted_source_amount = CASE WHEN p_cambios ? 'quoted_source_amount'
                                      THEN (p_cambios->>'quoted_source_amount')::numeric
                                      ELSE quoted_source_amount END,
         quoted_destination_amount = CASE WHEN p_cambios ? 'quoted_destination_amount'
                                           THEN (p_cambios->>'quoted_destination_amount')::numeric
                                           ELSE quoted_destination_amount END
   WHERE id = p_operation_id
  RETURNING destination_currency, delivery_method, deposit_method,
            quoted_source_amount, quoted_destination_amount
    INTO v_after_destination_currency, v_after_delivery_method, v_after_deposit_method,
         v_after_quoted_source_amount, v_after_quoted_destination_amount;

  -- One audit row per changed field.
  IF p_cambios ? 'destination_currency' THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_operations', p_operation_id, 'destination_currency', 'human_correction',
            wacrm_current_actor(), to_jsonb(v_before_destination_currency), to_jsonb(v_after_destination_currency));
  END IF;

  IF p_cambios ? 'delivery_method' THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_operations', p_operation_id, 'delivery_method', 'human_correction',
            wacrm_current_actor(), to_jsonb(v_before_delivery_method), to_jsonb(v_after_delivery_method));
  END IF;

  IF p_cambios ? 'deposit_method' THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_operations', p_operation_id, 'deposit_method', 'human_correction',
            wacrm_current_actor(), to_jsonb(v_before_deposit_method), to_jsonb(v_after_deposit_method));
  END IF;

  IF p_cambios ? 'quoted_source_amount' THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_operations', p_operation_id, 'quoted_source_amount', 'human_correction',
            wacrm_current_actor(), to_jsonb(v_before_quoted_source_amount), to_jsonb(v_after_quoted_source_amount));
  END IF;

  IF p_cambios ? 'quoted_destination_amount' THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_operations', p_operation_id, 'quoted_destination_amount', 'human_correction',
            wacrm_current_actor(), to_jsonb(v_before_quoted_destination_amount), to_jsonb(v_after_quoted_destination_amount));
  END IF;
END $$;


-- ---------------------------------------------------------------------
-- 3. crm_corregir_beneficiario — append-only beneficiary correction.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_corregir_beneficiario(p_beneficiary_id uuid, p_cambios jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
                      'amount', 'currency', 'beneficiary_type') THEN
      RAISE EXCEPTION 'unknown field: %', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

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

  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone, zelle_account,
    delivery_method, amount, currency, position, status, source, block_index
  ) VALUES (
    v_op_id, v_beneficiary_type, v_name, v_card_number, v_phone, v_zelle_account,
    v_delivery_method, v_amount, v_currency, v_old.position, 'vigente', 'admin_correction', v_next_block_index
  ) RETURNING id INTO v_new_id;

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
      END);
    v_after := v_after || jsonb_build_object(v_key, p_cambios -> v_key);
  END LOOP;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_beneficiaries', v_new_id, v_field_names, 'human_correction',
          wacrm_current_actor(), v_before, v_after);

  RETURN v_new_id;
END $$;


-- ---------------------------------------------------------------------
-- 4. crm_reasignar_beneficiario — move a beneficiary to another operation.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_reasignar_beneficiario(p_beneficiary_id uuid, p_target_operation_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone, zelle_account,
    delivery_method, amount, currency, position, status, source, block_index
  ) VALUES (
    p_target_operation_id, v_old.beneficiary_type, v_old.name, v_old.card_number, v_old.phone, v_old.zelle_account,
    v_old.delivery_method, v_old.amount, v_old.currency, v_next_position, 'vigente', 'admin_reassignment', v_next_block_index
  ) RETURNING id INTO v_new_id;

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
END $$;


-- ---------------------------------------------------------------------
-- 5. cerebro_sync_beneficiarios — honor the 'beneficiaries' lock.
-- ---------------------------------------------------------------------
-- Same body as 042, plus an early, audited return when a human correction
-- or reassignment has already locked this operation's beneficiaries.

CREATE OR REPLACE FUNCTION cerebro_sync_beneficiarios(p_deal_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_op uuid; v_notes text; v_max int; v_nuevos int := 0;
  v_locked boolean; v_account_id uuid;
BEGIN
  SELECT o.id, d.notes INTO v_op, v_notes
    FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
   WHERE d.id = p_deal_id;

  IF v_op IS NULL THEN RETURN 0; END IF;

  SELECT admin_locked_fields ? 'beneficiaries', account_id INTO v_locked, v_account_id
    FROM remittance_operations WHERE id = v_op;

  IF v_locked THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason)
    VALUES (v_account_id, 'remittance_beneficiaries', v_op, 'beneficiaries', 'automation_write_suppressed',
            wacrm_current_actor(), 'beneficiaries locked by operator correction');
    RETURN 0;
  END IF;

  WITH p AS (SELECT * FROM cerebro_parsear_beneficiarios(v_notes))
  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone,
    zelle_account, amount, currency, position, block_index, source, status)
  SELECT v_op, p.tipo, p.nombre, p.tarjeta, p.celular,
         p.cuenta_zelle, p.monto, p.moneda, p.posicion, p.block_index,
         'notes_parse', 'vigente'
    FROM p
  ON CONFLICT (operation_id, block_index, position) DO NOTHING;

  GET DIAGNOSTICS v_nuevos = ROW_COUNT;

  SELECT max(block_index) INTO v_max
    FROM remittance_beneficiaries WHERE operation_id = v_op;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = v_op AND block_index < v_max AND status <> 'reemplazado';

  UPDATE remittance_beneficiaries
     SET status = 'vigente', replaced_at = NULL
   WHERE operation_id = v_op AND block_index = v_max AND status <> 'vigente';

  RETURN v_nuevos;
END $$;


-- ---------------------------------------------------------------------
-- 6. Grants.
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION crm_corregir_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_corregir_operacion(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION crm_corregir_beneficiario(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_corregir_beneficiario(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION crm_reasignar_beneficiario(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_reasignar_beneficiario(uuid, uuid) TO authenticated;
