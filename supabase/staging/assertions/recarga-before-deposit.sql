-- =====================================================================
-- Assertion for migration 202 (a recharge opens when its numbers arrive, before the deposit). Self-reverting: one DO
-- block that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/panel-other-services.md. Owner test on staging, 2026-10-03 21:26: "Para poner unas recargas / A dos
-- números / 53821230 / 53456789" — the bot quoted 12,400 GYD for both, but nothing showed in the panel (the recharge
-- was only created by the deposit) and only one number was kept (in the partial-beneficiary scratch).
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_t202(p_tag text, p_texts text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_i int := 0; v_t text;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;  -- not from conversations: staging can have none after a reset
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900202' || p_tag, 'test202' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  FOREACH v_t IN ARRAY p_texts LOOP
    v_i := v_i + 1;
    INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
    VALUES (v_conv, 'customer', 'text', v_t, now() - make_interval(mins => 30 - v_i));
  END LOOP;
  RETURN v_conv;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.ops_t202(p_conv uuid) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(o.service_type || '/' || o.status || '/' || o.quoted_source_amount::int || '/' ||
           coalesce((SELECT string_agg(b.phone, ',' ORDER BY b.position) FROM remittance_beneficiaries b
                      WHERE b.operation_id = o.id AND b.status = 'vigente' AND b.beneficiary_type = 'recarga'), '-'), ';'), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$$;

DO $$
DECLARE v_conv uuid; v_out record;
BEGIN
  -- (207) A recharge opens only while a promo is running: these cases run with one running promo.
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v', 'assert', md5('assert-vigente-202'), 'confirmada');
  -- 1. The owner's test: the numbers arrive (the auto registration runs with one of them) -> a recharge opens with BOTH.
  v_conv := pg_temp.conv_t202('01', ARRAY['Hola buenos días', 'Para poner unas recargas', 'A dos números', '53821230', '53456789']);
  SELECT * INTO v_out FROM cerebro_guardar_beneficiario_auto(v_conv, '', '53821230', '', '53821230', 'test202');
  IF pg_temp.ops_t202(v_conv) <> 'recarga/collecting_information/0/53821230,53456789' THEN
    RAISE EXCEPTION 'case 1: expected one open recharge with both numbers, got %', pg_temp.ops_t202(v_conv); END IF;
  IF v_out.accion ILIKE '%tarjeta%' THEN RAISE EXCEPTION 'case 1: must not ask for a card, said %', v_out.accion; END IF;

  -- 2. The deposit lands on THAT recharge (no second operation).
  PERFORM cerebro_registrar_deposito(v_conv, 12400, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid, NULL, NULL);
  IF pg_temp.ops_t202(v_conv) <> 'recarga/deposit_verification/12400/53821230,53456789' THEN
    RAISE EXCEPTION 'case 2: the deposit must land on the open recharge, got %', pg_temp.ops_t202(v_conv); END IF;

  -- 3. The agent's tool opens it too when the numbers were said by audio (recharge asked for in text).
  v_conv := pg_temp.conv_t202('03', ARRAY['quiero una recarga']);
  PERFORM crm_registrar_numeros_recarga(v_conv, '5382 1230');
  IF pg_temp.ops_t202(v_conv) <> 'recarga/collecting_information/0/53821230' THEN
    RAISE EXCEPTION 'case 3: the tool must open the recharge, got %', pg_temp.ops_t202(v_conv); END IF;

  -- 4. No recharge asked for: a number alone opens nothing (remesa flow unchanged).
  v_conv := pg_temp.conv_t202('04', ARRAY['hola, quiero mandar dinero', '53821230']);
  SELECT * INTO v_out FROM cerebro_guardar_beneficiario_auto(v_conv, '', '53821230', '', '53821230', 'test202d');
  PERFORM crm_registrar_numeros_recarga(v_conv, '53821230');
  IF pg_temp.ops_t202(v_conv) <> '' THEN RAISE EXCEPTION 'case 4: nothing must open, got %', pg_temp.ops_t202(v_conv); END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
