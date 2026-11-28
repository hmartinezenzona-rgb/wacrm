-- =====================================================================
-- Assertion for migration 385 (the bot's cambiar_servicio accepts Mexico).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA385 ...', phones 5990385xxxx.
-- Incident: production conversation 4afda26a (2026-11-21) called cambiar_servicio with {"servicio":"mexico"} and got
-- servicio_desconocido; _cambiar_servicio_core already supported Mexico (service_type mexico, MXN, 13,000 GYD minimum).
-- Cases:
--   a  an open remesa (15,000 GYD) changes to mexico: ok true, changed true, servicio mexico, the operation is
--      service_type mexico / destination_currency MXN and the tool_execution_log row is cambiar_servicio/changed
--   b  a mexico_cuenta recipient is saved on that operation (the end-to-end unblock)
--   c  5,000 GYD is below the 13,000 GYD minimum: por_debajo_del_minimo, minimo_gyd 13000, the operation stays remesa
--   d  the same operation changes back to zelle (ok true, changed true): the operation-type list accepts mexico
--   e  an unknown service still returns servicio_desconocido
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid;
  v_ct_a uuid; v_conv_a uuid; v_op_a uuid;
  v_ct_c uuid; v_conv_c uuid; v_op_c uuid;
  v_ct_e uuid; v_conv_e uuid;
  v_r jsonb; v_row remittance_operations%ROWTYPE; v_n int; v_log jsonb;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- case a: an open remesa, 15,000 GYD, no beneficiaries
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990385001', 'PRUEBA385 a') RETURNING id INTO v_ct_a;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct_a) RETURNING id INTO v_conv_a;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv_a, v_ct_a, 'ready_to_transfer', 'remesa', 'GYD', 15000) RETURNING id INTO v_op_a;

  v_r := cerebro_cambiar_servicio(v_conv_a, 'mexico', 'PRUEBA385');
  IF NOT coalesce((v_r ->> 'ok')::boolean, false)
     OR NOT coalesce((v_r ->> 'changed')::boolean, false)
     OR (v_r ->> 'servicio') IS DISTINCT FROM 'mexico' THEN
    RAISE EXCEPTION 'case a: cerebro_cambiar_servicio(conv, mexico) returned %', v_r;
  END IF;
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op_a;
  IF v_row.service_type IS DISTINCT FROM 'mexico' OR v_row.destination_currency IS DISTINCT FROM 'MXN' THEN
    RAISE EXCEPTION 'case a: operation not mexico/MXN (service_type %, destination_currency %)', v_row.service_type, v_row.destination_currency;
  END IF;
  SELECT count(*), coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) INTO v_n, v_log
    FROM tool_execution_log l
   WHERE l.conversation_id = v_conv_a AND l.operation_id = v_op_a
     AND l.tool_name = 'cambiar_servicio' AND l.outcome = 'changed';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'case a: expected one tool_execution_log row cambiar_servicio/changed, got %', v_n;
  END IF;
  RAISE NOTICE 'case a tool_execution_log: %', v_log;

  -- case b: save a mexico_cuenta recipient on that operation (the end-to-end unblock)
  v_r := cerebro_guardar_beneficiario_mexico(v_conv_a, 'mexico_cuenta', '722969069917903430', 'Mercado Pago', 'PRUEBA385 Destino', NULL, 'PRUEBA385', NULL, false, 50);
  IF NOT coalesce((v_r ->> 'ok')::boolean, false) THEN
    RAISE EXCEPTION 'case b: cerebro_guardar_beneficiario_mexico returned %', v_r;
  END IF;
  SELECT count(*) INTO v_n FROM remittance_beneficiaries
   WHERE operation_id = v_op_a AND status = 'vigente' AND beneficiary_type = 'mexico_cuenta'
     AND clabe = '722969069917903430';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'case b: mexico_cuenta recipient not created on the operation (%)', v_n;
  END IF;

  -- case c: below the Mexico minimum
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990385002', 'PRUEBA385 c') RETURNING id INTO v_ct_c;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct_c) RETURNING id INTO v_conv_c;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv_c, v_ct_c, 'ready_to_transfer', 'remesa', 'GYD', 5000) RETURNING id INTO v_op_c;

  v_r := cerebro_cambiar_servicio(v_conv_c, 'mexico', 'PRUEBA385');
  IF (v_r ->> 'reason') IS DISTINCT FROM 'por_debajo_del_minimo'
     OR (v_r ->> 'minimo_gyd')::numeric IS DISTINCT FROM 13000 THEN
    RAISE EXCEPTION 'case c: expected por_debajo_del_minimo / 13000, got %', v_r;
  END IF;
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op_c;
  IF v_row.service_type IS DISTINCT FROM 'remesa' THEN
    RAISE EXCEPTION 'case c: the below-minimum change must roll back, service_type is %', v_row.service_type;
  END IF;

  -- case d: change the operation of (a) back to zelle (the operation-type list accepts mexico).
  -- This assertion runs with member JWT claims, so the rail write of (b) was recorded by the 096
  -- guard as a human lock; it is unrelated to the operation-type list under test, so clear it.
  UPDATE remittance_operations SET admin_locked_fields = admin_locked_fields - 'delivery_method' WHERE id = v_op_a;
  v_r := cerebro_cambiar_servicio(v_conv_a, 'zelle', 'PRUEBA385');
  IF NOT coalesce((v_r ->> 'ok')::boolean, false) OR NOT coalesce((v_r ->> 'changed')::boolean, false) THEN
    RAISE EXCEPTION 'case d: change back from mexico to zelle returned %', v_r;
  END IF;

  -- case e: an unknown service is still rejected
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990385003', 'PRUEBA385 e') RETURNING id INTO v_ct_e;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct_e) RETURNING id INTO v_conv_e;
  v_r := cerebro_cambiar_servicio(v_conv_e, 'no_existe_385', 'PRUEBA385');
  IF (v_r ->> 'reason') IS DISTINCT FROM 'servicio_desconocido' THEN
    RAISE EXCEPTION 'case e: an unknown service must stay servicio_desconocido, got %', v_r;
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
