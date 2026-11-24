\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 393 (crm_registrar_numeros_recarga never opens a recarga operation while the conversation is paused).
-- Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only (contacts 'PRUEBA393', phones 59900393xx).
-- Cases:
--   A  paused + nothing open + declared recarga (agent tool, p_abrir true or declared): no operation, nothing saved, refusal text
--   B  paused + an open recarga: the numbers are added as usual
--   C  not paused + nothing open + p_abrir: the recarga opens and takes the number (as today)
--   D  paused + nothing open through the 268 branch (cerebro_guardar_beneficiario_auto, declared recarga): no operation opened
--   E  paused + an open remesa: no second operation (unchanged rule); paused + admin origin session: still no operation
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t393.fail', (coalesce(nullif(current_setting('t393.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE
    RAISE NOTICE 'ok   [%]', p_label;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.fx(p_tag text, p_paused boolean) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900393' || p_tag, 'PRUEBA393' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id, ai_autoreply_disabled) VALUES (v_user, v_acc, v_ct, p_paused) RETURNING id INTO v_conv;
  RETURN v_conv;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.nops(p_conv uuid) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM remittance_operations WHERE conversation_id = p_conv;
$$;

DO $$
DECLARE v_conv uuid; v_op uuid; v_r text; v_n int; v_out record;
BEGIN
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v', 'assert', md5('assert-vigente-393'), 'confirmada');

  -- A. paused, nothing open, the agent opens a recarga
  v_conv := pg_temp.fx('01', true);
  v_r := crm_registrar_numeros_recarga(v_conv, '53871234', true, 'agent:registrar_numeros_recarga');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 0, 'A1 paused + p_abrir: no operation opened');
  PERFORM pg_temp.chk(v_r ILIKE '%NO SE ABRIO NINGUN ENVIO%pausado%', 'A2 paused: the refusal says the bot is paused (got: ' || left(v_r, 60) || ')');
  PERFORM pg_temp.chk(NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = v_conv),
                      'A3 paused: no beneficiary saved');
  v_conv := pg_temp.fx('02', true);
  PERFORM cerebro_declarar_servicio(v_conv, 'recarga', 'test393');
  v_r := crm_registrar_numeros_recarga(v_conv, '53871234 y 63123456');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 0, 'A4 paused + declared recarga (no p_abrir): no operation opened');

  -- B. paused, recarga already open: numbers still land
  v_conv := pg_temp.fx('03', false);
  v_r := crm_registrar_numeros_recarga(v_conv, '53871234', true, 'agent:registrar_numeros_recarga');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv AND o.service_type = 'recarga';
  PERFORM pg_temp.chk(v_op IS NOT NULL, 'B0 setup: recarga opened while not paused');
  UPDATE conversations SET ai_autoreply_disabled = true WHERE id = v_conv;
  v_r := crm_registrar_numeros_recarga(v_conv, '63123456', false, 'agent:registrar_numeros_recarga');
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'recarga';
  PERFORM pg_temp.chk(v_n = 2, 'B1 paused + open recarga: the second number is added (have ' || v_n || ')');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1, 'B2 still one operation');

  -- C. not paused, nothing open: opens as today
  v_conv := pg_temp.fx('04', false);
  v_r := crm_registrar_numeros_recarga(v_conv, '53871234', true, 'agent:registrar_numeros_recarga');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'recarga'),
                      'C1 not paused: the recarga opens');
  PERFORM pg_temp.chk(v_r ILIKE 'guardados 1%', 'C2 not paused: number saved (got: ' || left(v_r, 40) || ')');

  -- D. 268 branch, paused, declared recarga, a bare mobile
  v_conv := pg_temp.fx('05', true);
  PERFORM cerebro_declarar_servicio(v_conv, 'recarga', 'test393');
  SELECT * INTO v_out FROM cerebro_guardar_beneficiario_auto(v_conv, NULL, '53871234', NULL, NULL, NULL);
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 0, 'D1 paused 268 branch: no operation opened (accion: ' || left(coalesce(v_out.accion, 'null'), 70) || ')');

  -- E. paused + an open remesa: no second operation; admin origin session does not change it
  v_conv := pg_temp.fx('06', true);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  SELECT v.account_id, v.id, v.contact_id, 'collecting_information', 'remesa', 'GYD', 0 FROM conversations v WHERE v.id = v_conv;
  PERFORM cerebro_declarar_servicio(v_conv, 'recarga', 'test393');
  v_r := crm_registrar_numeros_recarga(v_conv, '53871234', true, 'agent:registrar_numeros_recarga');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1, 'E1 paused + open remesa: still one operation');
  v_conv := pg_temp.fx('07', true);
  PERFORM set_config('wacrm.origin', 'admin', true);
  v_r := crm_registrar_numeros_recarga(v_conv, '53871234', true, 'agent:registrar_numeros_recarga');
  PERFORM set_config('wacrm.origin', '', true);
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 0, 'E2 paused + admin origin session: no operation (only service_role can call this function)');

  IF coalesce(nullif(current_setting('t393.fail', true), ''), '0')::int > 0 THEN
    RAISE EXCEPTION '% expectation(s) failed', current_setting('t393.fail', true);
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
