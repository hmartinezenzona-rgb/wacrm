-- =====================================================================
-- Assertion for migration 171 (the amount the customer asked for is the remesa target).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'; any failure RAISEs
-- its own message instead. The bot's quotes are inserted as the agent messages the Cerebro
-- writes, with the exact wording seen in production (2026-09-24 .. 2026-10-01).
-- Needs pg_temp.conv_prueba and pg_temp.depositar from split-deposit-minimums.sql.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.bot_dice(p_conv uuid, p_texto text) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, ai_generated)
  VALUES (p_conv, 'agent', 'text', p_texto, true);
$$;

DO $$
DECLARE
  c_esp CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_conv uuid; v_d1 uuid; v_d2 uuid; v_n int; v_op record;
BEGIN
  -- 1. "100 Zelle" = 26,000 GYD; 13,000 arrives -> it WAITS (13,000 more to go); the next 13,000 completes it.
  v_conv := pg_temp.conv_prueba('11', 'zelle');
  PERFORM pg_temp.bot_dice(v_conv, 'Entendido, en dólares.' || chr(10) || chr(10) || 'Por *100 USD* por Zelle, Clásica o Tropical necesita depositar *26,000 GYD* (en efectivo la tasa es otra).');
  v_d1 := pg_temp.depositar(v_conv, 13000, '10409990017101', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_d1;
  IF v_op.status <> 'deposit_verification' THEN
    RAISE EXCEPTION 'case 1: 13,000 of a 26,000 remesa must wait, got status %', v_op.status;
  END IF;
  v_d2 := pg_temp.depositar(v_conv, 13000, '10409990017102', c_esp);
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv AND status <> 'cancelled';
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_d1;
  IF v_n <> 1 OR v_d2 IS DISTINCT FROM v_d1 OR v_op.quoted_source_amount <> 26000 OR v_op.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 1: 100 Zelle paid 13,000 + 13,000 -> % ops, amount %, status %', v_n, v_op.quoted_source_amount, v_op.status;
  END IF;
  RAISE NOTICE 'PASS 1: 100 USD Zelle paid as 13,000 + 13,000 is one 26,000 remesa';

  -- 2. The customer changes the amount: the last quote wins.
  v_conv := pg_temp.conv_prueba('12', 'zelle');
  PERFORM pg_temp.bot_dice(v_conv, 'Para enviar *100 USD* necesita depositar *26,000 GYD*.');
  PERFORM pg_temp.bot_dice(v_conv, 'Para enviar *50 USD* por Zelle necesita depositar *13,000 GYD*.' || chr(10) || chr(10) || '¿Me pasa los datos de quien recibe?');
  v_d1 := pg_temp.depositar(v_conv, 13000, '10409990017103', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_d1;
  IF v_op.status <> 'ready_to_transfer' THEN RAISE EXCEPTION 'case 2: the 50 USD quote replaced the 100 one, got status %', v_op.status; END IF;
  RAISE NOTICE 'PASS 2: the latest quote is the target';

  -- 3. Waiting on 100 USD, the customer settles for 50: the new quote releases the remesa.
  v_conv := pg_temp.conv_prueba('13', 'zelle');
  PERFORM pg_temp.bot_dice(v_conv, 'Para enviar *100 USD* necesita depositar *26,000 GYD*.');
  v_d1 := pg_temp.depositar(v_conv, 13000, '10409990017104', c_esp);
  PERFORM pg_temp.bot_dice(v_conv, 'Para enviar *50 USD* necesita depositar *13,000 GYD*.');
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_d1;
  IF v_op.status <> 'ready_to_transfer' THEN RAISE EXCEPTION 'case 3: lowering the quote to what was paid must release it, got %', v_op.status; END IF;
  RAISE NOTICE 'PASS 3: a lower quote covered by the deposits releases the waiting remesa';

  -- 4. The share of ONE card in a reparto is not the remesa amount (Yosvany, 2026-10-01).
  v_conv := pg_temp.conv_prueba('14', 'cup');
  PERFORM pg_temp.bot_dice(v_conv, 'Por *50,000 GYD* llegan *150,000 CUP* a Cuba.');
  PERFORM pg_temp.bot_dice(v_conv, 'Por *15,000 GYD* llegan *45,000 CUP* a esa tarjeta.' || chr(10) || chr(10) || '¿Me pasa el celular de quien recibe?');
  v_d1 := pg_temp.depositar(v_conv, 15000, '10409990017105', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_d1;
  IF v_op.status <> 'deposit_verification' THEN RAISE EXCEPTION 'case 4: a per-card share must not replace the 50,000 target, got %', v_op.status; END IF;
  RAISE NOTICE 'PASS 4: a per-card share is not a target';

  -- 5. Minimums, rates and fees are information, not what the customer asked for.
  v_conv := pg_temp.conv_prueba('15', 'cup');
  PERFORM pg_temp.bot_dice(v_conv, 'Así es, para efectivo el mínimo es *100 USD*, o sea *29,000 GYD*.');
  v_d1 := pg_temp.depositar(v_conv, 5000, '10409990017106', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_d1;
  IF v_op.status <> 'ready_to_transfer' THEN RAISE EXCEPTION 'case 5: a minimum mentioned in passing is not a target, got %', v_op.status; END IF;
  RAISE NOTICE 'PASS 5: a stated minimum is not a target';

  -- 6. A quote older than the window belongs to an earlier conversation, not this deposit.
  v_conv := pg_temp.conv_prueba('16', 'zelle');
  PERFORM pg_temp.bot_dice(v_conv, 'Para enviar *100 USD* necesita depositar *26,000 GYD*.');
  UPDATE cerebro_cotizacion SET cotizado_en = now() - interval '7 hours' WHERE conversation_id = v_conv;
  v_d1 := pg_temp.depositar(v_conv, 13000, '10409990017107', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_d1;
  IF v_op.status <> 'ready_to_transfer' THEN RAISE EXCEPTION 'case 6: a stale quote must not hold a deposit, got %', v_op.status; END IF;
  RAISE NOTICE 'PASS 6: a stale quote is ignored';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
