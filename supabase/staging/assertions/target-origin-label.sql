-- =====================================================================
-- Assertion for migration 173 (the objetivo records where it came from).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Needs pg_temp.conv_prueba / depositar (split-deposit-minimums.sql) and
-- pg_temp.bot_dice (requested-amount-target.sql).
-- The Cerebro reads cerebro_objetivo_envio.pedido to tell the customer either
-- "the minimum for <rail> is X" or "you asked for X"; it must never say the
-- customer asked for an amount that is only the service minimum.
-- 2026-10-05: pg_temp.depositar (split-deposit-minimums.sql, deal-free model) now returns the OPERATION id, so the
-- objetivo is looked up by operation_id instead of deal_id; the expectations are unchanged.
-- =====================================================================
DO $$
DECLARE
  c_esp CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_conv uuid; v_d1 uuid; v_ped text;
BEGIN
  -- 1. 10,000 for a Zelle, no quote: the target is the Zelle minimum, and says so.
  v_conv := pg_temp.conv_prueba('21', 'zelle');
  v_d1 := pg_temp.depositar(v_conv, 10000, '10409990017201', c_esp);
  SELECT pedido INTO v_ped FROM cerebro_objetivo_envio WHERE operation_id = v_d1;
  IF v_ped IS DISTINCT FROM 'minimo Zelle' THEN RAISE EXCEPTION 'case 1: expected "minimo Zelle", got %', v_ped; END IF;

  -- 2. 3,000 for a CUP card, no quote: the CUP minimum.
  v_conv := pg_temp.conv_prueba('22', 'cup');
  v_d1 := pg_temp.depositar(v_conv, 3000, '10409990017202', c_esp);
  SELECT pedido INTO v_ped FROM cerebro_objetivo_envio WHERE operation_id = v_d1;
  IF v_ped IS DISTINCT FROM 'minimo tarjeta CUP' THEN RAISE EXCEPTION 'case 2: expected "minimo tarjeta CUP", got %', v_ped; END IF;

  -- 3. "100 USD" quoted, 13,000 deposited: the target is what the customer asked for.
  v_conv := pg_temp.conv_prueba('23', 'zelle');
  PERFORM pg_temp.bot_dice(v_conv, 'Para enviar *100 USD* necesita depositar *26,000 GYD*.');
  v_d1 := pg_temp.depositar(v_conv, 13000, '10409990017203', c_esp);
  SELECT pedido INTO v_ped FROM cerebro_objetivo_envio WHERE operation_id = v_d1;
  IF v_ped IS DISTINCT FROM 'cotizacion' THEN RAISE EXCEPTION 'case 3: expected "cotizacion", got %', v_ped; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
