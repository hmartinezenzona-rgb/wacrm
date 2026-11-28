\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 394 (crm_editar_reparto: replace the card shares of an operation in one atomic, audited step, the sum of the
-- shares must equal the destination total).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Synthetic fixtures only: contacts 'PRUEBA394', phones 5990394xxxx, fake cards 99903940000000nn.
-- Cases (number = label in the failure message):
--   1  owner: 4 shares of 10000 CUP (total 40000): edit 2 amounts (15000 / 5000), keep one, add one, drop one in a single call -> applied;
--      retired / created / kept in the answer, positions 1..N in the given order, the kept share keeps its id, beneficiaries locked,
--      one human_correction audit row with before / after, destination total untouched
--   2  a sum that differs from the total is refused with both numbers (22023) and nothing changes (same current ids, no new audit row)
--   3  a share of another operation, a repeated id, fewer than 2 shares, a total not set, a wrong currency, a Zelle share, bad card: refused
--   5  a calculated total: after a valid edit the origin is manual, quoted_destination_amount is locked and in the audit 'after', and a
--      later correction of one share does not clear the total
--   4  closed (completed) operation: an agent is refused, the owner is applied and leaves the human_closed_operation_edit audit row
-- =====================================================================
CREATE FUNCTION pg_temp.p_refused(p_op uuid, p_partes jsonb, p_sqlstate text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM crm_editar_reparto(p_op, p_partes);
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  IF SQLSTATE <> p_sqlstate THEN RAISE EXCEPTION 'expected SQLSTATE %, got % (%)', p_sqlstate, SQLSTATE, SQLERRM; END IF;
  RETURN SQLERRM;
END $f$;

CREATE FUNCTION pg_temp.p_ids(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(id::text, ',' ORDER BY id), '') FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente';
$f$;

DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_op2 uuid; v_op3 uuid; v_opz uuid; v_opx uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; o1 uuid; o2 uuid; z1 uuid;
  v_res jsonb; v_msg text; v_ids text; v_n int; v_audit int; v_row remittance_operations%ROWTYPE; v_aud remittance_admin_audit%ROWTYPE;
  v_pos text;
  v_op5 uuid; t1 uuid; t2 uuid; v_new uuid;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990394001', 'PRUEBA394 a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  -- op: four card shares of 10000 CUP, total 40000 CUP (manual)
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method, destination_currency, quoted_destination_amount, quoted_destination_origin)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 20000, 'multiple_distribution', 'CUP', 40000, 'manual') RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, block_index, source, status, amount_origin) VALUES
    (v_op, 'cuban_card', 'PRUEBA Uno',    '9990394000000001', '53821201', 10000, 'CUP', 1, 1, 'notes_parse', 'vigente', 'manual'),
    (v_op, 'cuban_card', 'PRUEBA Dos',    '9990394000000002', '53821202', 10000, 'CUP', 2, 2, 'notes_parse', 'vigente', 'manual'),
    (v_op, 'cuban_card', 'PRUEBA Tres',   '9990394000000003', '53821203', 10000, 'CUP', 3, 3, 'notes_parse', 'vigente', 'manual'),
    (v_op, 'cuban_card', 'PRUEBA Cuatro', '9990394000000004', '53821204', 10000, 'CUP', 4, 4, 'notes_parse', 'vigente', 'manual');
  SELECT id INTO s1 FROM remittance_beneficiaries WHERE operation_id = v_op AND position = 1;
  SELECT id INTO s2 FROM remittance_beneficiaries WHERE operation_id = v_op AND position = 2;
  SELECT id INTO s3 FROM remittance_beneficiaries WHERE operation_id = v_op AND position = 3;
  SELECT id INTO s4 FROM remittance_beneficiaries WHERE operation_id = v_op AND position = 4;
  -- another operation (foreign share), one without a total, a Zelle one, a completed one
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method, destination_currency, quoted_destination_amount, quoted_destination_origin)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 10000, 'multiple_distribution', 'CUP', 20000, 'manual') RETURNING id INTO v_op2;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, block_index, source, status, amount_origin) VALUES
    (v_op2, 'cuban_card', 'PRUEBA Otro A', '9990394000000011', '53821211', 10000, 'CUP', 1, 1, 'notes_parse', 'vigente', 'manual'),
    (v_op2, 'cuban_card', 'PRUEBA Otro B', '9990394000000012', '53821212', 10000, 'CUP', 2, 2, 'notes_parse', 'vigente', 'manual');
  SELECT id INTO o1 FROM remittance_beneficiaries WHERE operation_id = v_op2 AND position = 1;
  SELECT id INTO o2 FROM remittance_beneficiaries WHERE operation_id = v_op2 AND position = 2;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 10000, 'multiple_distribution') RETURNING id INTO v_opx;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method, destination_currency, quoted_destination_amount, quoted_destination_origin)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 10000, 'zelle', 'USD', 50, 'manual') RETURNING id INTO v_opz;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, block_index, source, status, amount_origin)
  VALUES (v_opz, 'zelle', 'PRUEBA Zelle', 'prueba394@example.com', 50, 'USD', 1, 1, 'notes_parse', 'vigente', 'manual');
  SELECT id INTO z1 FROM remittance_beneficiaries WHERE operation_id = v_opz;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method, destination_currency, quoted_destination_amount, quoted_destination_origin)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 10000, 'multiple_distribution', 'CUP', 20000, 'manual') RETURNING id INTO v_op3;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, block_index, source, status, amount_origin) VALUES
    (v_op3, 'cuban_card', 'PRUEBA Cerrada A', '9990394000000021', '53821221', 10000, 'CUP', 1, 1, 'notes_parse', 'vigente', 'manual'),
    (v_op3, 'cuban_card', 'PRUEBA Cerrada B', '9990394000000022', '53821222', 10000, 'CUP', 2, 2, 'notes_parse', 'vigente', 'manual');
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op3;
  PERFORM set_config('wacrm.origin', '', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 2 (before the edit, so "nothing changes" is measured on the fixture) a sum that differs from the total
  v_ids := pg_temp.p_ids(v_op);
  SELECT count(*) INTO v_audit FROM remittance_admin_audit WHERE row_id = v_op;
  v_msg := pg_temp.p_refused(v_op, jsonb_build_array(
      jsonb_build_object('id', s1, 'beneficiary_type', 'cuban_card', 'name', 'PRUEBA Uno', 'card_number', '9990394000000001', 'phone', '53821201', 'amount', 20000, 'currency', 'CUP'),
      jsonb_build_object('id', s2, 'beneficiary_type', 'cuban_card', 'name', 'PRUEBA Dos', 'card_number', '9990394000000002', 'phone', '53821202', 'amount', 19999, 'currency', 'CUP')), '22023');
  IF v_msg IS NULL OR v_msg NOT LIKE '%39999%' OR v_msg NOT LIKE '%40000%' THEN RAISE EXCEPTION 'case 2: the refusal must name both numbers, got [%]', v_msg; END IF;
  IF pg_temp.p_ids(v_op) <> v_ids OR (SELECT count(*) FROM remittance_admin_audit WHERE row_id = v_op) <> v_audit THEN RAISE EXCEPTION 'case 2: nothing may change on a refusal'; END IF;

  -- 3 refusals
  v_msg := pg_temp.p_refused(v_op, jsonb_build_array(
      jsonb_build_object('id', o1, 'beneficiary_type', 'cuban_card', 'card_number', '9990394000000011', 'phone', '53821211', 'amount', 20000, 'currency', 'CUP'),
      jsonb_build_object('id', s2, 'beneficiary_type', 'cuban_card', 'card_number', '9990394000000002', 'phone', '53821202', 'amount', 20000, 'currency', 'CUP')), '22023');
  IF v_msg IS NULL THEN RAISE EXCEPTION 'case 3: a share of another operation must be refused'; END IF;
  v_msg := pg_temp.p_refused(v_op, jsonb_build_array(
      jsonb_build_object('id', s1, 'beneficiary_type', 'cuban_card', 'card_number', '9990394000000001', 'amount', 20000, 'currency', 'CUP'),
      jsonb_build_object('id', s1, 'beneficiary_type', 'cuban_card', 'card_number', '9990394000000001', 'amount', 20000, 'currency', 'CUP')), '22023');
  IF v_msg IS NULL THEN RAISE EXCEPTION 'case 3: a repeated id must be refused'; END IF;
  v_msg := pg_temp.p_refused(v_op, jsonb_build_array(
      jsonb_build_object('id', s1, 'beneficiary_type', 'cuban_card', 'card_number', '9990394000000001', 'amount', 40000, 'currency', 'CUP')), '22023');
  IF v_msg IS NULL THEN RAISE EXCEPTION 'case 3: fewer than 2 shares must be refused'; END IF;
  v_msg := pg_temp.p_refused(v_opx, jsonb_build_array(
      jsonb_build_object('beneficiary_type', 'cuban_card', 'card_number', '9990394000000031', 'amount', 1, 'currency', 'CUP'),
      jsonb_build_object('beneficiary_type', 'cuban_card', 'card_number', '9990394000000032', 'amount', 1, 'currency', 'CUP')), '22023');
  IF v_msg IS NULL OR v_msg NOT ILIKE '%total%' THEN RAISE EXCEPTION 'case 3: an operation without a destination total must ask to set it first, got [%]', v_msg; END IF;
  v_msg := pg_temp.p_refused(v_op, jsonb_build_array(
      jsonb_build_object('id', s1, 'beneficiary_type', 'cuban_card', 'card_number', '9990394000000001', 'amount', 20000, 'currency', 'USD'),
      jsonb_build_object('id', s2, 'beneficiary_type', 'cuban_card', 'card_number', '9990394000000002', 'amount', 20000, 'currency', 'USD')), '22023');
  IF v_msg IS NULL THEN RAISE EXCEPTION 'case 3: a currency other than the operation''s must be refused'; END IF;
  v_msg := pg_temp.p_refused(v_op, jsonb_build_array(
      jsonb_build_object('id', s1, 'beneficiary_type', 'zelle', 'name', 'x', 'amount', 20000, 'currency', 'CUP'),
      jsonb_build_object('id', s2, 'beneficiary_type', 'cuban_card', 'card_number', '9990394000000002', 'amount', 20000, 'currency', 'CUP')), '22023');
  IF v_msg IS NULL THEN RAISE EXCEPTION 'case 3: a non-card rail must be refused'; END IF;
  v_msg := pg_temp.p_refused(v_op, jsonb_build_array(
      jsonb_build_object('id', s1, 'beneficiary_type', 'cuban_card', 'card_number', '123', 'amount', 20000, 'currency', 'CUP'),
      jsonb_build_object('id', s2, 'beneficiary_type', 'cuban_card', 'card_number', '9990394000000002', 'amount', 20000, 'currency', 'CUP')), '22023');
  IF v_msg IS NULL OR v_msg NOT ILIKE '%16 digits%' THEN RAISE EXCEPTION 'case 3: a bad card must be refused, got [%]', v_msg; END IF;
  v_msg := pg_temp.p_refused(v_opz, jsonb_build_array(
      jsonb_build_object('id', z1, 'beneficiary_type', 'cuban_card', 'card_number', '9990394000000041', 'amount', 25, 'currency', 'USD'),
      jsonb_build_object('beneficiary_type', 'cuban_card', 'card_number', '9990394000000042', 'amount', 25, 'currency', 'USD')), '22023');
  IF v_msg IS NULL THEN RAISE EXCEPTION 'case 3: an operation with a Zelle recipient must be refused'; END IF;
  IF pg_temp.p_ids(v_op) <> v_ids THEN RAISE EXCEPTION 'case 3: nothing may change on a refusal'; END IF;

  -- 1 the edit: s1 -> 15000, s2 -> 5000, s4 kept (moves from 4 to 3), one new of 10000, s3 dropped
  v_res := crm_editar_reparto(v_op, jsonb_build_array(
      jsonb_build_object('id', s1, 'beneficiary_type', 'cuban_card', 'name', 'PRUEBA Uno', 'card_number', '9990394000000001', 'phone', '53821201', 'amount', 15000, 'currency', 'CUP'),
      jsonb_build_object('id', s2, 'beneficiary_type', 'cuban_card', 'name', 'PRUEBA Dos', 'card_number', '9990394000000002', 'phone', '53821202', 'amount', 5000, 'currency', 'CUP'),
      jsonb_build_object('id', s4, 'beneficiary_type', 'cuban_card', 'name', 'PRUEBA Cuatro', 'card_number', '9990394000000004', 'phone', '53821204', 'amount', 10000, 'currency', 'CUP'),
      jsonb_build_object('id', NULL, 'beneficiary_type', 'cuban_card', 'name', 'PRUEBA Nuevo', 'card_number', '9990394000000009', 'phone', '+53 5382 1209', 'amount', 10000, 'currency', 'CUP')));
  IF v_res ->> 'operation_id' <> v_op::text THEN RAISE EXCEPTION 'case 1: operation_id missing in %', v_res; END IF;
  IF jsonb_array_length(v_res -> 'retired') <> 3 OR NOT (v_res -> 'retired') @> to_jsonb(ARRAY[s1::text, s2::text, s3::text])
     OR jsonb_array_length(v_res -> 'created') <> 3 OR (v_res -> 'kept') <> jsonb_build_array(s4) THEN
    RAISE EXCEPTION 'case 1: wrong retired / created / kept: %', v_res; END IF;
  IF jsonb_typeof(v_res -> 'complete') <> 'boolean' THEN RAISE EXCEPTION 'case 1: complete missing in %', v_res; END IF;
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_n <> 4 THEN RAISE EXCEPTION 'case 1: expected 4 current shares, got %', v_n; END IF;
  SELECT string_agg(position || ':' || name || ':' || amount::int || ':' || coalesce(phone, '-'), ' | ' ORDER BY position) INTO v_pos
    FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_pos <> '1:PRUEBA Uno:15000:53821201 | 2:PRUEBA Dos:5000:53821202 | 3:PRUEBA Cuatro:10000:53821204 | 4:PRUEBA Nuevo:10000:53821209' THEN
    RAISE EXCEPTION 'case 1: wrong shares/positions: %', v_pos; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE id = s4 AND status = 'vigente' AND position = 3 AND source = 'notes_parse') THEN
    RAISE EXCEPTION 'case 1: the unchanged share must keep its id and its row'; END IF;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE id IN (s1, s2, s3) AND status = 'reemplazado' AND replaced_at IS NOT NULL) <> 3 THEN
    RAISE EXCEPTION 'case 1: s1, s2 and s3 must be retired'; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND name = 'PRUEBA Uno' AND source = 'admin_correction' AND amount_origin = 'manual')
     OR NOT EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND name = 'PRUEBA Nuevo' AND source = 'admin_addition' AND amount_origin = 'manual') THEN
    RAISE EXCEPTION 'case 1: wrong source / amount_origin on the new rows'; END IF;
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
  IF NOT (v_row.admin_locked_fields ? 'beneficiaries') OR v_row.admin_locked_fields -> 'beneficiaries' ->> 'by' IS NULL THEN RAISE EXCEPTION 'case 1: beneficiaries must be locked with actor'; END IF;
  IF v_row.quoted_destination_amount <> 40000 OR v_row.destination_currency <> 'CUP' OR v_row.status <> 'ready_to_transfer' THEN RAISE EXCEPTION 'case 1: the operation total/status must not change: %', to_jsonb(v_row); END IF;
  SELECT * INTO v_aud FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_correction' ORDER BY created_at DESC LIMIT 1;
  IF v_aud.id IS NULL OR jsonb_array_length(v_aud.before -> 'shares') <> 4 OR jsonb_array_length(v_aud.after -> 'shares') <> 4 THEN RAISE EXCEPTION 'case 1: audit row with before/after of the shares is missing: %', to_jsonb(v_aud); END IF;
  IF (SELECT count(*) FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_correction') <> 1 THEN RAISE EXCEPTION 'case 1: exactly one audit row expected'; END IF;
  IF EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_closed_operation_edit') THEN RAISE EXCEPTION 'case 1: an open operation leaves no closed-edit row'; END IF;

  -- 4 closed operation: agent refused, owner applied
  UPDATE profiles SET account_role = 'agent' WHERE user_id = v_user;
  v_msg := pg_temp.p_refused(v_op3, '[]'::jsonb, '22023');
  IF v_msg IS DISTINCT FROM 'operation is closed' THEN RAISE EXCEPTION 'case 4: an agent must be refused on a closed operation, got [%]', v_msg; END IF;
  UPDATE profiles SET account_role = 'owner' WHERE user_id = v_user;
  SELECT id INTO s1 FROM remittance_beneficiaries WHERE operation_id = v_op3 AND position = 1;
  SELECT id INTO s2 FROM remittance_beneficiaries WHERE operation_id = v_op3 AND position = 2;
  v_res := crm_editar_reparto(v_op3, jsonb_build_array(
      jsonb_build_object('id', s1, 'beneficiary_type', 'cuban_card', 'name', 'PRUEBA Cerrada A', 'card_number', '9990394000000021', 'phone', '53821221', 'amount', 12000, 'currency', 'CUP'),
      jsonb_build_object('id', s2, 'beneficiary_type', 'cuban_card', 'name', 'PRUEBA Cerrada B', 'card_number', '9990394000000022', 'phone', '53821222', 'amount', 8000, 'currency', 'CUP')));
  IF jsonb_array_length(v_res -> 'kept') <> 0 OR jsonb_array_length(v_res -> 'created') <> 2 THEN RAISE EXCEPTION 'case 4: wrong answer %', v_res; END IF;
  IF (SELECT status FROM remittance_operations WHERE id = v_op3) <> 'completed' THEN RAISE EXCEPTION 'case 4: the operation must stay completed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op3 AND action = 'human_closed_operation_edit' AND after ->> 'via' = 'crm_editar_reparto')
     OR NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op3 AND action = 'human_correction') THEN
    RAISE EXCEPTION 'case 4: the closed-edit and the correction audit rows are missing'; END IF;

  -- 5 a calculated total becomes the operator's: manual origin + lock, and a later single-share correction keeps it
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method, destination_currency, quoted_destination_amount, quoted_destination_origin)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 10000, 'multiple_distribution', 'CUP', 20000, 'manual') RETURNING id INTO v_op5;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, block_index, source, status, amount_origin) VALUES
    (v_op5, 'cuban_card', 'PRUEBA Cinco A', '9990394000000051', '53821251', 10000, 'CUP', 1, 1, 'notes_parse', 'vigente', 'manual'),
    (v_op5, 'cuban_card', 'PRUEBA Cinco B', '9990394000000052', '53821252', 10000, 'CUP', 2, 2, 'notes_parse', 'vigente', 'manual');
  UPDATE remittance_operations SET quoted_destination_origin = 'calculated', admin_locked_fields = admin_locked_fields - 'quoted_destination_amount' WHERE id = v_op5;
  SELECT id INTO t1 FROM remittance_beneficiaries WHERE operation_id = v_op5 AND position = 1;
  SELECT id INTO t2 FROM remittance_beneficiaries WHERE operation_id = v_op5 AND position = 2;
  IF (SELECT quoted_destination_origin FROM remittance_operations WHERE id = v_op5) <> 'calculated' THEN RAISE EXCEPTION 'case 5: fixture must be calculated'; END IF;
  PERFORM crm_editar_reparto(v_op5, jsonb_build_array(
      jsonb_build_object('id', t1, 'beneficiary_type', 'cuban_card', 'name', 'PRUEBA Cinco A', 'card_number', '9990394000000051', 'phone', '53821251', 'amount', 12000, 'currency', 'CUP'),
      jsonb_build_object('id', t2, 'beneficiary_type', 'cuban_card', 'name', 'PRUEBA Cinco B', 'card_number', '9990394000000052', 'phone', '53821252', 'amount', 8000, 'currency', 'CUP')));
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op5;
  IF v_row.quoted_destination_origin <> 'manual' OR NOT (v_row.admin_locked_fields ? 'quoted_destination_amount') OR v_row.quoted_destination_amount <> 20000 THEN
    RAISE EXCEPTION 'case 5: the total must be manual, locked and unchanged: %', to_jsonb(v_row); END IF;
  SELECT * INTO v_aud FROM remittance_admin_audit WHERE row_id = v_op5 AND action = 'human_correction' ORDER BY created_at DESC LIMIT 1;
  IF v_aud.after ->> 'quoted_destination_origin' <> 'manual' OR v_aud.before ->> 'quoted_destination_origin' <> 'calculated' THEN
    RAISE EXCEPTION 'case 5: the audit after must record the manual total: %', to_jsonb(v_aud); END IF;
  SELECT id INTO v_new FROM remittance_beneficiaries WHERE operation_id = v_op5 AND status = 'vigente' AND position = 1;
  PERFORM crm_corregir_beneficiario(v_new, '{"name": "PRUEBA Cinco X"}'::jsonb);
  IF (SELECT quoted_destination_amount FROM remittance_operations WHERE id = v_op5) IS DISTINCT FROM 20000 THEN
    RAISE EXCEPTION 'case 5: a later share correction cleared the total'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
