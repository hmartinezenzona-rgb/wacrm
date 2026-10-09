-- =====================================================================
-- Assertion for migration 218 (a quoted USD amount keeps its own tier price). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Fixtures build their own contacts, conversations and operations; never deals.
--
-- odd/tasks/zelle-tiered-rate.md (T3c). In the real flow the bot quotes with calcular_usd BEFORE the customer gives the Zelle
-- account, so no objective exists (cerebro_fijar_objetivo needs a beneficiary) but cerebro_registrar_cotizacion has recorded the
-- quote in cerebro_ultima_cotizacion. With no open USD objective, a USD quote X whose deposit lies in [X*p, (X+1)*p),
-- p = cerebro_tasa_zelle(X), is X USD at p. An open USD objective wins over the quote. Recency follows B1.1 (153): younger than
-- 24 hours (counted from the operation's creation) and newer than the last OTHER closed remesa of the conversation.
-- Run it as: BEGIN; \i zelle-quote-tier.sql; ROLLBACK;
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.zq_conv(p_tag text, OUT o_user uuid, OUT o_acc uuid, OUT o_conv uuid, OUT o_ct uuid)
LANGUAGE plpgsql AS $$
BEGIN
  SELECT p.user_id, p.account_id INTO o_user, o_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (o_user, o_acc, '59900218' || p_tag, 'test218' || p_tag) RETURNING id INTO o_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (o_user, o_acc, o_ct) RETURNING id INTO o_conv;
END $$;

-- Like the real flow: the quote is recorded first (as calcular_usd does), then the beneficiary arrives, then the deposit lands.
-- p_obj_usd (optional) fixes an objective once the beneficiary exists. p_moneda/p_quote_at let a case record other quotes.
CREATE OR REPLACE FUNCTION pg_temp.zq_op(p_tag text, p_gyd numeric, p_quote_usd numeric DEFAULT NULL, p_obj_usd numeric DEFAULT NULL,
                                        p_moneda text DEFAULT 'USD', p_quote_ago interval DEFAULT interval '0',
                                        OUT o_op uuid, OUT o_conv uuid)
LANGUAGE plpgsql AS $$
DECLARE c record; v_r record;
BEGIN
  SELECT * INTO c FROM pg_temp.zq_conv(p_tag);
  o_conv := c.o_conv;
  IF p_quote_usd IS NOT NULL THEN
    PERFORM cerebro_registrar_cotizacion(c.o_conv, p_gyd, p_quote_usd, p_moneda, 'calcular_usd');
    UPDATE cerebro_ultima_cotizacion SET cotizado_en = now() - p_quote_ago WHERE conversation_id = c.o_conv;
  END IF;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency)
  VALUES (c.o_acc, c.o_conv, c.o_ct, 'ready_to_transfer', 'remesa', 'GYD') RETURNING id INTO o_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (o_op, 'zelle', 'Quote Z ' || p_tag, 'quoz' || p_tag || '@example.com', 1, 1, 'manual', 'vigente');
  IF p_obj_usd IS NOT NULL THEN
    SELECT * INTO v_r FROM cerebro_fijar_objetivo(c.o_conv, p_obj_usd, 'usd');
    IF v_r.objetivo_gyd IS NULL THEN RAISE EXCEPTION 'fixture: the objective was not fixed (%)', v_r.accion; END IF;
  END IF;
  UPDATE remittance_operations SET quoted_source_amount = p_gyd WHERE id = o_op;
  PERFORM crm_calcular_monto_destino(o_op);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.zq_got(p_op uuid, OUT o_usd numeric, OUT o_rate numeric)
LANGUAGE sql AS $$ SELECT quoted_destination_amount, quoted_destination_rate FROM remittance_operations WHERE id = p_op $$;

DO $$
DECLARE
  v_op uuid; v_conv uuid; v_acc uuid; v_admin uuid; v_r record; v_e record; v_n numeric;
BEGIN
  -- 1. Quote 999 USD (no objective) + 259,740 GYD deposit: 999 USD at 260 (not 1,038 at 250).
  SELECT * INTO v_r FROM pg_temp.zq_op('01', 259740, 999); v_op := v_r.o_op;
  IF EXISTS (SELECT 1 FROM cerebro_objetivo_envio WHERE conversation_id = v_r.o_conv) THEN
    RAISE EXCEPTION 'fixture: case 1 must have no objective'; END IF;
  SELECT * INTO v_r FROM pg_temp.zq_got(v_op);
  IF v_r.o_usd IS DISTINCT FROM 999 OR v_r.o_rate IS DISTINCT FROM 260 THEN
    RAISE EXCEPTION 'case 1: quote 999 + 259,740 GYD must be 999 USD at 260, got % at %', v_r.o_usd, v_r.o_rate; END IF;
  SELECT amount INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_n IS DISTINCT FROM 999 THEN RAISE EXCEPTION 'case 1: the beneficiary must get 999, got %', v_n; END IF;

  -- 2. Quote 1,000 + 250,000: 1,000 at 250. Quote 500 + 130,000: 500 at 260.
  SELECT * INTO v_r FROM pg_temp.zq_op('02', 250000, 1000); v_op := v_r.o_op;
  SELECT * INTO v_r FROM pg_temp.zq_got(v_op);
  IF v_r.o_usd IS DISTINCT FROM 1000 OR v_r.o_rate IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 2: quote 1000 + 250,000 GYD must be 1000 at 250, got % at %', v_r.o_usd, v_r.o_rate; END IF;
  SELECT * INTO v_r FROM pg_temp.zq_op('03', 130000, 500); v_op := v_r.o_op;
  SELECT * INTO v_r FROM pg_temp.zq_got(v_op);
  IF v_r.o_usd IS DISTINCT FROM 500 OR v_r.o_rate IS DISTINCT FROM 260 THEN
    RAISE EXCEPTION 'case 2: quote 500 + 130,000 GYD must be 500 at 260, got % at %', v_r.o_usd, v_r.o_rate; END IF;

  -- 3. No quote and no objective: 259,740 GYD stays 1,038 USD at 250.
  SELECT * INTO v_r FROM pg_temp.zq_op('04', 259740); v_op := v_r.o_op;
  SELECT * INTO v_r FROM pg_temp.zq_got(v_op);
  IF v_r.o_usd IS DISTINCT FROM 1038 OR v_r.o_rate IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 3: no quote, 259,740 GYD must be 1038 at 250, got % at %', v_r.o_usd, v_r.o_rate; END IF;

  -- 4. A quote in CUP (destino_moneda not USD) is ignored, even when its number looks like a USD amount.
  SELECT * INTO v_r FROM pg_temp.zq_op('05', 259740, 999, NULL, 'CUP'); v_op := v_r.o_op;
  SELECT * INTO v_r FROM pg_temp.zq_got(v_op);
  IF v_r.o_usd IS DISTINCT FROM 1038 OR v_r.o_rate IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 4: a CUP quote must be ignored, got % at %', v_r.o_usd, v_r.o_rate; END IF;

  -- 5. A deposit that does not match the quote keeps the best GYD tier: 999 + 300,000 -> 1,200 @250; 999 + 260,000 -> 1,040 @250;
  --    999 + 259,739 -> 1,038 @250; 999 + 200,000 -> 769 @260.
  SELECT * INTO v_r FROM pg_temp.zq_op('06', 300000, 999); SELECT * INTO v_r FROM pg_temp.zq_got(v_r.o_op);
  IF v_r.o_usd IS DISTINCT FROM 1200 OR v_r.o_rate IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 5: quote 999 + 300,000 must be 1200 at 250, got % at %', v_r.o_usd, v_r.o_rate; END IF;
  SELECT * INTO v_r FROM pg_temp.zq_op('07', 260000, 999); SELECT * INTO v_r FROM pg_temp.zq_got(v_r.o_op);
  IF v_r.o_usd IS DISTINCT FROM 1040 OR v_r.o_rate IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 5: quote 999 + 260,000 must be 1040 at 250, got % at %', v_r.o_usd, v_r.o_rate; END IF;
  SELECT * INTO v_r FROM pg_temp.zq_op('08', 259739, 999); SELECT * INTO v_r FROM pg_temp.zq_got(v_r.o_op);
  IF v_r.o_usd IS DISTINCT FROM 1038 OR v_r.o_rate IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 5: quote 999 + 259,739 must be 1038 at 250, got % at %', v_r.o_usd, v_r.o_rate; END IF;
  SELECT * INTO v_r FROM pg_temp.zq_op('09', 200000, 999); SELECT * INTO v_r FROM pg_temp.zq_got(v_r.o_op);
  IF v_r.o_usd IS DISTINCT FROM 769 OR v_r.o_rate IS DISTINCT FROM 260 THEN
    RAISE EXCEPTION 'case 5: quote 999 + 200,000 must be 769 at 260, got % at %', v_r.o_usd, v_r.o_rate; END IF;

  -- 6. An open objective wins over the quote: objective 500 + quote 999 + 259,740 -> no match with 500, best GYD tier 1,038 @250.
  SELECT * INTO v_r FROM pg_temp.zq_op('10', 259740, 999, 500); SELECT * INTO v_r FROM pg_temp.zq_got(v_r.o_op);
  IF v_r.o_usd IS DISTINCT FROM 1038 OR v_r.o_rate IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 6: objective 500 must win over quote 999 (no match, best tier 1038 at 250), got % at %', v_r.o_usd, v_r.o_rate; END IF;
  --    and the objective still applies when it matches while the quote differs: objective 999 + quote 500 + 259,740 -> 999 @260
  SELECT * INTO v_r FROM pg_temp.zq_op('11', 259740, 500, 999); SELECT * INTO v_r FROM pg_temp.zq_got(v_r.o_op);
  IF v_r.o_usd IS DISTINCT FROM 999 OR v_r.o_rate IS DISTINCT FROM 260 THEN
    RAISE EXCEPTION 'case 6: objective 999 + quote 500 must give 999 at 260, got % at %', v_r.o_usd, v_r.o_rate; END IF;

  -- 7. Recency (153): a quote older than 24 hours is ignored; a quote older than the last other closed remesa is ignored.
  SELECT * INTO v_r FROM pg_temp.zq_op('12', 259740, 999, NULL, 'USD', interval '25 hours'); SELECT * INTO v_r FROM pg_temp.zq_got(v_r.o_op);
  IF v_r.o_usd IS DISTINCT FROM 1038 THEN RAISE EXCEPTION 'case 7: a 25-hour-old quote must be ignored, got %', v_r.o_usd; END IF;
  SELECT * INTO v_r FROM pg_temp.zq_op('13', 259740, 999, NULL, 'USD', interval '23 hours'); SELECT * INTO v_r FROM pg_temp.zq_got(v_r.o_op);
  IF v_r.o_usd IS DISTINCT FROM 999 THEN RAISE EXCEPTION 'case 7: a 23-hour-old quote must apply, got %', v_r.o_usd; END IF;
  SELECT * INTO v_r FROM pg_temp.zq_conv('14');
  v_conv := v_r.o_conv;
  PERFORM cerebro_registrar_cotizacion(v_conv, 259740, 999, 'USD', 'calcular_usd');
  UPDATE cerebro_ultima_cotizacion SET cotizado_en = now() - interval '2 hours' WHERE conversation_id = v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, cancelled_at)
  VALUES (v_r.o_acc, v_conv, v_r.o_ct, 'cancelled', 'remesa', 'GYD', now() - interval '1 hour');   -- an earlier remesa closed AFTER the quote
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency)
  VALUES (v_r.o_acc, v_conv, v_r.o_ct, 'ready_to_transfer', 'remesa', 'GYD') RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Quote Z 14', 'quoz14@example.com', 1, 1, 'manual', 'vigente');
  UPDATE remittance_operations SET quoted_source_amount = 259740 WHERE id = v_op;
  PERFORM crm_calcular_monto_destino(v_op);
  SELECT * INTO v_r FROM pg_temp.zq_got(v_op);
  IF v_r.o_usd IS DISTINCT FROM 1038 THEN RAISE EXCEPTION 'case 7: a quote older than the last closed remesa must be ignored, got %', v_r.o_usd; END IF;

  -- 8. The calculator: a completed Zelle with the quote bills 259,740 (999 USD at 260); without it 1,038 x 250 = 259,500.
  SELECT account_id INTO v_acc FROM whatsapp_config LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  SELECT * INTO v_r FROM pg_temp.zq_op('15', 259740, 999); v_op := v_r.o_op;
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.service IS DISTINCT FROM 'ZELLE' OR v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 999
     OR v_e.usdt_sell_gyd IS DISTINCT FROM 260 OR v_e.facturado_gyd IS DISTINCT FROM 259740 THEN
    RAISE EXCEPTION 'case 8: ZELLE line must be 999 USD billed 259740 at 260, got % % % % %',
      v_e.service, v_e.status, v_e.amount, v_e.usdt_sell_gyd, v_e.facturado_gyd; END IF;
  SELECT * INTO v_r FROM pg_temp.zq_op('16', 259740); v_op := v_r.o_op;
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.amount IS DISTINCT FROM 1038 OR v_e.usdt_sell_gyd IS DISTINCT FROM 250 OR v_e.facturado_gyd IS DISTINCT FROM 259740 THEN
    RAISE EXCEPTION 'case 8: no quote, ZELLE line must be 1038 USD billed 259740 (235: the deposit; was 1038 x 250 = 259500) at 250, got % % %', v_e.amount, v_e.usdt_sell_gyd, v_e.facturado_gyd; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
