-- =====================================================================
-- Assertion for migration 378 (crm_crear_operacion: an agent creates an operation from scratch in a conversation, from the panel).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA378', phones 5990378xxxx.
-- The service is one of the panel's "Servicio" choices; the new operation is an open one (collecting_information) with the amount the
-- agent typed, and the service is applied by the same core the panel's "change service" uses (rail, destination currency, rail lock).
-- Cases:
--   1  zelle 13000: an open remesa with delivery_method zelle, the amount, the conversation's contact, an audit row `human_operation_created`,
--      and the new operation takes a Zelle recipient from the panel's add-recipient function
--   2  every service: cuban_card, clasica, tropical, efectivo_usd keep service_type remesa with that rail; recarga, saldo, combo, visa,
--      mexico set their service type; mexico pays out in MXN
--   3  a combo may start with no amount (its total is the sum of its recipients); any other service needs an amount greater than 0
--   4  refused: an unknown service, a zero or missing amount, an unknown conversation, a user who is not a member
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_r jsonb; v_op uuid; v_row remittance_operations%ROWTYPE; v_ok boolean; v_s text; v_a jsonb;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990378001', 'PRUEBA378 a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1 zelle
  v_r := crm_crear_operacion(v_conv, 'zelle', 13000);
  v_op := (v_r ->> 'id')::uuid;
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
  IF v_row.status <> 'collecting_information' OR v_row.service_type <> 'remesa' OR v_row.delivery_method IS DISTINCT FROM 'zelle'
     OR v_row.quoted_source_amount <> 13000 OR v_row.conversation_id <> v_conv OR v_row.contact_id IS DISTINCT FROM v_ct OR v_row.account_id <> v_acc THEN
    RAISE EXCEPTION 'case 1: the new operation is wrong: %', to_jsonb(v_row); END IF;
  SELECT after INTO v_a FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_operation_created' ORDER BY created_at DESC LIMIT 1;
  IF v_a IS NULL OR v_a ->> 'service' <> 'zelle' OR (v_a ->> 'quoted_source_amount')::numeric <> 13000 THEN
    RAISE EXCEPTION 'case 1: the audit row human_operation_created must carry the service and the amount, got %', v_a; END IF;
  PERFORM crm_agregar_beneficiario(v_op, '{"beneficiary_type":"zelle","name":"PRUEBA Titular","zelle_account":"prueba378@example.com","amount":50,"currency":"USD"}'::jsonb);
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 1 THEN
    RAISE EXCEPTION 'case 1: a Zelle recipient must be addable to the new operation'; END IF;

  -- 2 every service
  FOREACH v_s IN ARRAY ARRAY['cuban_card', 'clasica', 'tropical', 'efectivo_usd'] LOOP
    v_op := (crm_crear_operacion(v_conv, v_s, 26000) ->> 'id')::uuid;
    SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
    IF v_row.service_type <> 'remesa' OR v_row.delivery_method IS DISTINCT FROM v_s OR v_row.quoted_source_amount <> 26000 THEN
      RAISE EXCEPTION 'case 2: rail % not applied: %', v_s, to_jsonb(v_row); END IF;
  END LOOP;
  FOREACH v_s IN ARRAY ARRAY['recarga', 'saldo', 'visa', 'mexico'] LOOP
    v_op := (crm_crear_operacion(v_conv, v_s, 5000) ->> 'id')::uuid;
    SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
    IF v_row.service_type <> v_s OR v_row.quoted_source_amount <> 5000 THEN
      RAISE EXCEPTION 'case 2: service % not applied: %', v_s, to_jsonb(v_row); END IF;
    IF v_s = 'mexico' AND v_row.destination_currency IS DISTINCT FROM 'MXN' THEN
      RAISE EXCEPTION 'case 2: a mexico send pays out in MXN, got %', v_row.destination_currency; END IF;
  END LOOP;

  -- 3 combo without amount
  v_op := (crm_crear_operacion(v_conv, 'combo', NULL) ->> 'id')::uuid;
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
  IF v_row.service_type <> 'combo' OR coalesce(v_row.quoted_source_amount, 0) <> 0 THEN RAISE EXCEPTION 'case 3: a combo may start with no amount: %', to_jsonb(v_row); END IF;
  v_ok := false;
  BEGIN PERFORM crm_crear_operacion(v_conv, 'zelle', NULL);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: a Zelle operation without amount must be refused'; END IF;

  -- 4 refusals
  v_ok := false;
  BEGIN PERFORM crm_crear_operacion(v_conv, 'paloma', 1000);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4a: an unknown service must be refused'; END IF;
  v_ok := false;
  BEGIN PERFORM crm_crear_operacion(v_conv, 'zelle', 0);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4b: a zero amount must be refused'; END IF;
  v_ok := false;
  BEGIN PERFORM crm_crear_operacion(gen_random_uuid(), 'zelle', 13000);
  EXCEPTION WHEN SQLSTATE 'P0002' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4c: an unknown conversation must be refused'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN PERFORM crm_crear_operacion(v_conv, 'zelle', 13000);
  EXCEPTION WHEN SQLSTATE '42501' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4d: a user who is not a member must be refused'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
