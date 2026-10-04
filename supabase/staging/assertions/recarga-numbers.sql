-- =====================================================================
-- Assertion for migration 201 (the bot collects the recharge numbers). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/panel-other-services.md (R2). One Cuban number per recharge. A recharge operation is created when its
-- deposit arrives (cerebro_registrar_deposito, keyword recarga/etecsa/cubacel); the numbers the customer TYPED since
-- asking are attached then; a number sent alone later is a recharge number (not a card's phone); the agent's tool
-- covers numbers said by audio. The panel's beneficiary lock is respected.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_t201(p_tag text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;  -- not from conversations: staging can have none after a reset
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900201' || p_tag, 'test201' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.op_t201(p_conv uuid, p_gyd numeric) RETURNS uuid
LANGUAGE sql AS $$
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  SELECT v.account_id, v.id, v.contact_id, 'deposit_verification', 'recarga', 'GYD', p_gyd FROM conversations v WHERE v.id = p_conv
  RETURNING id;
$$;
CREATE OR REPLACE FUNCTION pg_temp.nums_t201(p_op uuid) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(beneficiary_type || ':' || phone, ',' ORDER BY position), '')
    FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente';
$$;

DO $$
DECLARE v_conv uuid; v_op uuid; v_r text; v_out record;
BEGIN
  -- (211) A typed recharge needs a promo running: these cases run with one.
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v', 'assert', md5('assert-vigente-201-211'), 'confirmada');
  -- 1. The tool: a typed or dictated number lands on the open recharge; a repeat is ignored; it says what is missing.
  v_conv := pg_temp.conv_t201('01');
  v_op := pg_temp.op_t201(v_conv, 12400);
  v_r := crm_registrar_numeros_recarga(v_conv, 'el primero es el +53 5387 1234');
  IF pg_temp.nums_t201(v_op) <> 'recarga:53871234' THEN RAISE EXCEPTION 'case 1: got %', pg_temp.nums_t201(v_op); END IF;
  IF v_r NOT ILIKE '%falta%1%' THEN RAISE EXCEPTION 'case 1: must say one number is missing, said: %', v_r; END IF;
  v_r := crm_registrar_numeros_recarga(v_conv, '53871234 y 63123456, el fijo 78123456 no');
  IF pg_temp.nums_t201(v_op) <> 'recarga:53871234,recarga:63123456' THEN RAISE EXCEPTION 'case 1: repeat or landline, got %', pg_temp.nums_t201(v_op); END IF;
  IF v_r NOT ILIKE '%complet%' THEN RAISE EXCEPTION 'case 1: must say the numbers are complete, said: %', v_r; END IF;

  -- 2. No open recharge: nothing is created.
  v_conv := pg_temp.conv_t201('02');
  v_r := crm_registrar_numeros_recarga(v_conv, '53871234');
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = v_conv) THEN RAISE EXCEPTION 'case 2: no operation must be created'; END IF;

  -- 3. The panel's beneficiary lock wins.
  v_conv := pg_temp.conv_t201('03');
  v_op := pg_temp.op_t201(v_conv, 6200);
  -- the lock is set by a person (an automation write to it is suppressed by the guard)
  PERFORM set_config('request.jwt.claims', json_build_object('sub',
    (SELECT p.user_id FROM profiles p JOIN conversations c ON c.account_id = p.account_id WHERE c.id = v_conv
      AND p.account_role IN ('owner', 'admin') LIMIT 1), 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET admin_locked_fields = '{"beneficiaries": {"by": "admin"}}'::jsonb WHERE id = v_op;
  PERFORM set_config('request.jwt.claims', '', true);
  IF NOT (SELECT admin_locked_fields ? 'beneficiaries' FROM remittance_operations WHERE id = v_op) THEN
    RAISE EXCEPTION 'case 3 fixture: the lock was not set'; END IF;
  v_r := crm_registrar_numeros_recarga(v_conv, '53871234');
  IF pg_temp.nums_t201(v_op) <> '' THEN RAISE EXCEPTION 'case 3: a locked recharge must not be written'; END IF;

  -- 4. A number sent alone while a recharge is open is a recharge number, not a card's phone.
  v_conv := pg_temp.conv_t201('04');
  v_op := pg_temp.op_t201(v_conv, 6200);
  SELECT * INTO v_out FROM cerebro_guardar_beneficiario_auto(v_conv, '', '53871234', '', '53871234', 'test201');
  IF pg_temp.nums_t201(v_op) <> 'recarga:53871234' OR v_out.accion ILIKE '%tarjeta%' THEN
    RAISE EXCEPTION 'case 4: got % / %', pg_temp.nums_t201(v_op), v_out.accion; END IF;

  -- 5. The deposit creates the recharge and attaches the numbers typed since the customer asked for it.
  v_conv := pg_temp.conv_t201('05');
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', 'quiero una recarga para el 53871234', now() - interval '10 minutes'),
    (v_conv, 'customer', 'text', 'y otra para 63123456', now() - interval '9 minutes');
  SELECT * INTO v_out FROM cerebro_registrar_deposito(v_conv, 12400, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid, NULL, NULL);
  SELECT id INTO v_op FROM remittance_operations WHERE conversation_id = v_conv;
  IF (SELECT service_type FROM remittance_operations WHERE id = v_op) <> 'recarga'
     OR pg_temp.nums_t201(v_op) <> 'recarga:53871234,recarga:63123456' THEN
    RAISE EXCEPTION 'case 5: expected a recharge with both typed numbers, got % / %',
      (SELECT service_type FROM remittance_operations WHERE id = v_op), pg_temp.nums_t201(v_op); END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
