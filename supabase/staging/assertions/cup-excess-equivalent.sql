-- =====================================================================
-- Regression guard: a CUP remesa paid above the quote transfers the equivalent (owner rule 2026-10-02).
-- STAGING (deal-free path). Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- No migration: measured on 2026-10-02 that both environments ALREADY behave this way (171's
-- cerebro_objetivo_minimo only keeps a target when the money does not cover it, and raises it with the total),
-- so this file pins the behaviour. The only "deposito de mas" Incidencia comes from a target fixed BEFORE the
-- deposit by calcular_usd (cerebro_fijar_objetivo), i.e. USD rails (case 4).
-- Needs pg_temp.op_libre / depositar_libre / bot_dice from deal-free-money-rules.sql: run after it in the
-- same psql session. Production (deal path) runs the same cases with split-deposit-minimums.sql's helpers.
--
-- Owner (2026-10-02): in CUP, more than quoted -> transfer the equivalent; less -> say what is missing and wait.
-- =====================================================================
DO $$
DECLARE
  c_esp CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_conv uuid; v_o1 uuid; v_o2 uuid; v_op record; v_s record; v_tasa numeric;
BEGIN
  SELECT tasa_cup INTO v_tasa FROM tasas WHERE moneda = 'gyd' ORDER BY fecha DESC, actualizada_at DESC LIMIT 1;

  -- 1. CUP card, quote 5,000 GYD (15,000 CUP), the customer deposits 7,000: complete, the equivalent goes.
  v_conv := pg_temp.op_libre('71', 'cuban');
  PERFORM pg_temp.bot_dice(v_conv, 'Para que lleguen *15,000 CUP* necesita depositar *5,000 GYD*.');
  v_o1 := pg_temp.depositar_libre(v_conv, 7000, '10409990018701', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  SELECT * INTO v_s FROM cerebro_saldo_operacion(v_o1);
  IF v_op.status <> 'ready_to_transfer' OR v_op.quoted_source_amount <> 7000 THEN
    RAISE EXCEPTION 'case 1: a CUP deposit above the quote must be complete (ready_to_transfer, 7,000), got % / % (saldo %)',
      v_op.status, v_op.quoted_source_amount, v_s.saldo;
  END IF;
  IF v_op.quoted_destination_amount IS DISTINCT FROM round(7000 * v_tasa) THEN
    RAISE EXCEPTION 'case 1: the destination must be the equivalent of 7,000 GYD (%), got %', round(7000 * v_tasa), v_op.quoted_destination_amount;
  END IF;
  IF coalesce(v_s.saldo, 0) <> 0 THEN RAISE EXCEPTION 'case 1: saldo must read 0, got %', v_s.saldo; END IF;
  RAISE NOTICE 'PASS 1: CUP quote 5,000, deposit 7,000 -> ready_to_transfer, % CUP', v_op.quoted_destination_amount;

  -- 2. CUP card, quote 10,000 GYD, deposit 6,000: waits for the rest; 4,000 more completes it (unchanged).
  v_conv := pg_temp.op_libre('72', 'cuban');
  PERFORM pg_temp.bot_dice(v_conv, 'Para que lleguen *30,000 CUP* necesita depositar *10,000 GYD*.');
  v_o1 := pg_temp.depositar_libre(v_conv, 6000, '10409990018702', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_op.status <> 'deposit_verification' THEN
    RAISE EXCEPTION 'case 2: 6,000 of a 10,000 CUP quote must wait for the rest, got %', v_op.status;
  END IF;
  v_o2 := pg_temp.depositar_libre(v_conv, 4000, '10409990018703', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_o2 IS DISTINCT FROM v_o1 OR v_op.status <> 'ready_to_transfer' OR v_op.quoted_source_amount <> 10000 THEN
    RAISE EXCEPTION 'case 2: 6,000 + 4,000 must complete the same remesa, got same=% % %', v_o2 = v_o1, v_op.status, v_op.quoted_source_amount;
  END IF;
  RAISE NOTICE 'PASS 2: CUP quote 10,000 paid 6,000 + 4,000 waits, then completes';

  -- 3. CUP card, quote 10,000, paid 6,000 + 6,000: the overshoot still completes it, 12,000 transferred.
  v_conv := pg_temp.op_libre('74', 'cuban');
  PERFORM pg_temp.bot_dice(v_conv, 'Para que lleguen *30,000 CUP* necesita depositar *10,000 GYD*.');
  v_o1 := pg_temp.depositar_libre(v_conv, 6000, '10409990018711', c_esp);
  v_o2 := pg_temp.depositar_libre(v_conv, 6000, '10409990018712', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_o2 IS DISTINCT FROM v_o1 OR v_op.status <> 'ready_to_transfer' OR v_op.quoted_source_amount <> 12000 THEN
    RAISE EXCEPTION 'case 3: 6,000 + 6,000 on a 10,000 CUP quote must complete with 12,000, got same=% % %', v_o2 = v_o1, v_op.status, v_op.quoted_source_amount;
  END IF;
  RAISE NOTICE 'PASS 3: CUP quote 10,000 paid 6,000 + 6,000 -> ready_to_transfer, 12,000';

  -- 4. Documented contrast (USD): a target fixed by calcular_usd BEFORE the deposit -> a deposit above it is an incident.
  v_conv := pg_temp.op_libre('76', 'zelle');
  PERFORM cerebro_fijar_objetivo(v_conv, 50, 'usd');
  v_o1 := pg_temp.depositar_libre(v_conv, 15000, '10409990018776', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_op.status <> 'incident' THEN
    RAISE EXCEPTION 'case 4: a Zelle target fixed by calcular_usd (13,000) paid 15,000 must stay an incident, got %', v_op.status;
  END IF;
  RAISE NOTICE 'PASS 4: Zelle target fixed by calcular_usd, deposit above it -> incident';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
