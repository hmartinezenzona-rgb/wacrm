\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 358 (a multi-card reparto must add up to the verified deposit).
-- Self-reverting: run as  BEGIN; <migration 358>; <this file without BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (staging-migracion.sh does exactly that). Ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
--
-- Real cases of 2026-11-07, replayed as synthetic fixtures (no customer data):
--   * verified 10,000 GYD, 2 cards "36,000 CUP each" (72,000 CUP for a 36,000 CUP deposit);
--   * verified 15,000 GYD, 3 cards "15,000 CUP each" saved without conversion (45,000 of 54,000 CUP).
-- The rates are pinned inside the transaction (gyd 3.6, usd 260), dated far in the future so they win.
-- Cases:
--   1. over the deposit (2 x 36,000 CUP on 10,000 GYD): refused, nothing written, reply names 36000 and 72000;
--   2. 3 x 15,000 CUP on 15,000 GYD: saved, FALTA sobran 9000, never "Completo";
--   3. 18,000 + 18,000 CUP on 10,000 GYD: saved, "Completo";
--   4. partial (one amount, two cards): saved, "quedan 18000 CUP"; then the second amount completes it;
--   5. partial + an amount that overflows the rest: refused, the saved reparto is untouched;
--   6. a deposit that is not verified: today's behavior (any amounts accepted, "Completo");
--   7. a phone patch with empty amounts (cerebro_guardar_beneficiario) keeps working, also on an over-sum
--      saved before the deposit was verified (verification is never blocked);
--   8. mixed CUP + Clasica USD slots compared in GYD (within, over, under);
--   9. per-card rounding tolerance (1 CUP per CUP card) passes, 2 CUP per card does not;
--  10. the helper cerebro_reparto_disponible: verified by status, verified by covered funds, NULLs otherwise.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t358.fail', (coalesce(nullif(current_setting('t358.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE
    RAISE NOTICE 'ok   [%]', p_label;
  END IF;
END $$;

-- A conversation with one open operation of the given status and quoted deposit.
CREATE OR REPLACE FUNCTION pg_temp.fx(p_tag text, p_status text, p_base numeric, OUT o_conv uuid, OUT o_op uuid) LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900358' || p_tag, 'test358' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO o_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, o_conv, v_ct, p_status, 'remesa', 'GYD', p_base) RETURNING id INTO o_op;
END $$;

-- The tool call: three slots (card, amount); each card comes with a phone so a full reparto is "Completo".
CREATE OR REPLACE FUNCTION pg_temp.rp(p_conv uuid, p_op uuid, p_t1 text, p_m1 text, p_t2 text, p_m2 text, p_t3 text DEFAULT '', p_m3 text DEFAULT '')
RETURNS text LANGUAGE sql AS $$
  SELECT accion FROM cerebro_guardar_reparto(p_conv, p_t1, CASE WHEN p_t1 <> '' THEN '53821201' ELSE '' END, p_m1,
                                              p_t2, CASE WHEN p_t2 <> '' THEN '53821202' ELSE '' END, p_m2,
                                              p_t3, CASE WHEN p_t3 <> '' THEN '53821203' ELSE '' END, p_m3, 'x' || gen_random_uuid()::text, p_op)
$$;

CREATE OR REPLACE FUNCTION pg_temp.slots(p_op uuid) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(b.position || '=' || coalesce(b.card_number, '_') || ':' || coalesce(b.amount::text, '_') || b.currency, ' | ' ORDER BY b.position), '')
    FROM remittance_beneficiaries b WHERE b.operation_id = p_op AND b.status = 'vigente'
$$;

CREATE OR REPLACE FUNCTION pg_temp.slotsp(p_op uuid) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(b.position || '=' || coalesce(b.card_number, '_') || ':' || coalesce(b.phone, '_') || ':'
                             || coalesce(b.amount::text, '_') || b.currency, ' | ' ORDER BY b.position), '')
    FROM remittance_beneficiaries b WHERE b.operation_id = p_op AND b.status = 'vigente'
$$;

DO $$
DECLARE
  c1 constant text := '9238123432101987';
  c2 constant text := '9238123432101237';
  c3 constant text := '9205129978614908';
  v_acc uuid; v_conv uuid; v_op uuid; v_r text; v_before text; v_n int; v_h record; v_ref text;
BEGIN
  SELECT w.account_id INTO v_acc FROM whatsapp_config w LIMIT 1;
  INSERT INTO calculator_rate_versions (account_id, cup_global_rate, usdt_sell_gyd, zelle_sell_gyd, effective_at)
  VALUES (v_acc, 3.6, 260, 260, now() + interval '1000 days');
  PERFORM pg_temp.chk(crm_tasa_vigente('gyd') = 3.6 AND crm_tasa_vigente('usd') = 260, 'setup: pinned rates 3.6 / 260');

  -- 1. Real case 96d81952: verified 10,000 GYD = 36,000 CUP, two cards asked 36,000 CUP each.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('01', 'ready_to_transfer', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '36000', c2, '36000');
  PERFORM pg_temp.chk(v_r LIKE 'NO SE GUARDO NADA%', '1a refused: ' || v_r);
  PERFORM pg_temp.chk(v_r LIKE '%10000 GYD%' AND v_r LIKE '%36000 CUP%' AND v_r LIKE '%72000 CUP%', '1b reply names deposit, available 36000 and asked 72000');
  PERFORM pg_temp.chk(v_r LIKE '%No se cambio nada%', '1c reply says nothing changed');
  PERFORM pg_temp.chk(pg_temp.slots(v_op) = '', '1d nothing written: ' || pg_temp.slots(v_op));

  -- 2. Real case f80a33a0: verified 15,000 GYD = 54,000 CUP, three cards 15,000 CUP each (45,000 CUP).
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('02', 'ready_to_transfer', 15000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '15000', c2, '15000', c3, '15000');
  PERFORM pg_temp.chk(pg_temp.slots(v_op) = '1=' || c1 || ':15000CUP | 2=' || c2 || ':15000CUP | 3=' || c3 || ':15000CUP', '2a saved as sent: ' || pg_temp.slots(v_op));
  PERFORM pg_temp.chk(v_r LIKE 'reparto guardado:%' AND v_r LIKE '%FALTA:%sobran 9000 CUP%', '2b FALTA names the 9000 CUP left: ' || v_r);
  PERFORM pg_temp.chk(v_r NOT LIKE '%Completo%', '2c never says Completo');

  -- 3. Exact: 18,000 + 18,000 CUP on 10,000 GYD.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('03', 'ready_to_transfer', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '18000', c2, '18000');
  PERFORM pg_temp.chk(v_r LIKE 'reparto guardado:%' AND v_r LIKE '%Completo.%' AND v_r NOT LIKE '%sobran%' AND v_r NOT LIKE '%quedan%', '3a Completo: ' || v_r);
  PERFORM pg_temp.chk(pg_temp.slots(v_op) = '1=' || c1 || ':18000CUP | 2=' || c2 || ':18000CUP', '3b saved: ' || pg_temp.slots(v_op));

  -- 4. Partial: one amount, the second card without amount; then the second amount completes it.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('04', 'ready_to_transfer', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '18000', c2, '');
  PERFORM pg_temp.chk(pg_temp.slots(v_op) = '1=' || c1 || ':18000CUP', '4a saved (the card without amount waits): ' || pg_temp.slots(v_op));
  PERFORM pg_temp.chk(v_r LIKE '%quedan 18000 CUP para las demas tarjetas%', '4b reply says what is left: ' || v_r);
  PERFORM pg_temp.chk(v_r LIKE '%FALTA: cuanto recibe la tarjeta 2%' AND v_r NOT LIKE '%Completo%', '4c still FALTA the amount of card 2');
  v_r := pg_temp.rp(v_conv, v_op, '', '', '', '18000');
  PERFORM pg_temp.chk(v_r LIKE '%Completo.%' AND pg_temp.slots(v_op) = '1=' || c1 || ':18000CUP | 2=' || c2 || ':18000CUP', '4d second amount completes it: ' || v_r);

  -- 5. Partial saved, then an amount that overflows the rest: refused, saved reparto untouched.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('05', 'ready_to_transfer', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', c2, '');
  v_before := pg_temp.slots(v_op);
  v_r := pg_temp.rp(v_conv, v_op, '', '', '', '20000');
  PERFORM pg_temp.chk(v_r LIKE 'NO SE GUARDO NADA%' AND v_r LIKE '%38000 CUP%', '5a overflow refused with the merged sum: ' || v_r);
  PERFORM pg_temp.chk(pg_temp.slots(v_op) = v_before, '5b saved reparto untouched');

  -- 6. Deposit not verified: today's behavior, any amounts accepted.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('06', 'collecting_information', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '36000', c2, '36000');
  PERFORM pg_temp.chk(v_r LIKE 'reparto guardado:%' AND v_r LIKE '%Completo.%' AND v_r NOT LIKE '%sobran%' AND v_r NOT LIKE '%quedan%', '6a unverified accepts: ' || v_r);
  PERFORM pg_temp.chk(pg_temp.slots(v_op) = '1=' || c1 || ':36000CUP | 2=' || c2 || ':36000CUP', '6b saved as sent');

  -- 7. Phone patch with empty amounts, on the over-sum saved above and now verified (verification is never blocked).
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op;
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, '', c1, '53821299', 'x358-7');
  PERFORM pg_temp.chk(v_r NOT LIKE 'NO SE GUARDO NADA%' AND pg_temp.slotsp(v_op) = '1=' || c1 || ':53821299:36000CUP | 2=' || c2 || ':53821202:36000CUP',
                      '7a phone patch unchanged on a verified op: ' || v_r || ' / ' || pg_temp.slotsp(v_op));
  -- same patch on a fresh verified reparto with valid amounts
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('07', 'ready_to_transfer', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', c2, '18000');
  SELECT accion INTO v_r FROM cerebro_guardar_beneficiario(v_conv, '', c2, '53821204', 'x358-7b');
  PERFORM pg_temp.chk(pg_temp.slotsp(v_op) = '1=' || c1 || ':53821201:18000CUP | 2=' || c2 || ':53821204:18000CUP', '7b amounts survive the patch: ' || pg_temp.slotsp(v_op));

  -- 8. Mixed rails compared in GYD (rates 3.6 and 260). 18000 CUP = 5000 GYD.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('08', 'ready_to_transfer', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '18000', c2, '19 USD Clasica');   -- 5000 + 4940 GYD: floor remainder below one USD
  PERFORM pg_temp.chk(v_r LIKE 'reparto guardado:%' AND v_r LIKE '%Completo.%', '8a CUP + Clasica within the deposit: ' || v_r);
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('09', 'ready_to_transfer', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '18000', c2, '38 USD Clasica');   -- 5000 + 9880 GYD > 10000
  PERFORM pg_temp.chk(v_r LIKE 'NO SE GUARDO NADA%' AND v_r LIKE '%18000 CUP%' AND v_r LIKE '%38 USD%' AND v_r LIKE '%GYD%', '8b mixed over refused: ' || v_r);
  PERFORM pg_temp.chk(pg_temp.slots(v_op) = '', '8c nothing written');
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('10', 'ready_to_transfer', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '18000', c2, '10 USD Clasica');   -- 5000 + 2600 GYD: 2400 GYD = 8640 CUP left
  PERFORM pg_temp.chk(v_r LIKE 'reparto guardado:%' AND v_r LIKE '%FALTA:%sobran 8640 CUP%' AND v_r NOT LIKE '%Completo%', '8d mixed under: FALTA sobran 8640 CUP: ' || v_r);

  -- 9. Rounding tolerance: 1 CUP per CUP card.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('11', 'ready_to_transfer', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '12001', c2, '12000', c3, '12000');   -- 36001 vs 36000
  PERFORM pg_temp.chk(v_r LIKE 'reparto guardado:%' AND v_r LIKE '%Completo.%', '9a 1 CUP over passes: ' || v_r);
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('12', 'ready_to_transfer', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '17999', c2, '18000');   -- 35999 vs 36000
  PERFORM pg_temp.chk(v_r LIKE 'reparto guardado:%' AND v_r LIKE '%Completo.%', '9b 1 CUP under passes: ' || v_r);
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('13', 'ready_to_transfer', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '18003', c2, '18003');   -- 36006 vs 36000: 3 CUP per card
  PERFORM pg_temp.chk(v_r LIKE 'NO SE GUARDO NADA%', '9c clearly over is refused: ' || v_r);

  -- 10. The helper.
  PERFORM pg_temp.chk(to_regprocedure('public.cerebro_reparto_disponible(uuid)') IS NOT NULL, '10a helper exists');
  IF to_regprocedure('public.cerebro_reparto_disponible(uuid)') IS NOT NULL THEN
    SELECT * INTO v_conv, v_op FROM pg_temp.fx('14', 'transferring', 10000);
    EXECUTE 'SELECT * FROM cerebro_reparto_disponible($1)' INTO v_h USING v_op;
    PERFORM pg_temp.chk(v_h.base_gyd = 10000 AND v_h.tasa_cup = 3.6 AND v_h.total_cup = 36000 AND v_h.tasa_usd = 260 AND v_h.total_usd = 38,
                        '10b verified by status: ' || coalesce(to_jsonb(v_h)::text, 'null'));
    SELECT * INTO v_conv, v_op FROM pg_temp.fx('15', 'collecting_information', 10000);
    EXECUTE 'SELECT * FROM cerebro_reparto_disponible($1)' INTO v_h USING v_op;
    PERFORM pg_temp.chk(v_h.base_gyd IS NULL AND v_h.total_cup IS NULL AND v_h.total_usd IS NULL, '10c NULLs when the deposit is not verified');
    v_ref := '3580' || lpad((random() * 1e9)::bigint::text, 10, '0');
    INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
    VALUES (v_ref, 10000, 'GYD', 'prueba358', now(), now(), v_op);
    EXECUTE 'SELECT * FROM cerebro_reparto_disponible($1)' INTO v_h USING v_op;
    PERFORM pg_temp.chk(v_h.base_gyd = 10000 AND v_h.total_cup = 36000, '10d verified by covered funds: ' || coalesce(to_jsonb(v_h)::text, 'null'));
    EXECUTE 'SELECT * FROM cerebro_reparto_disponible($1)' INTO v_h USING gen_random_uuid();
    PERFORM pg_temp.chk(v_h.base_gyd IS NULL, '10e unknown operation gives NULLs');
    -- and the guard follows funds too: the same op (still collecting_information) now refuses an over-sum
    v_r := pg_temp.rp(v_conv, v_op, c1, '36000', c2, '36000');
    PERFORM pg_temp.chk(v_r LIKE 'NO SE GUARDO NADA%', '10f guard applies when the funds cover the operation: ' || v_r);
  END IF;

  v_n := coalesce(nullif(current_setting('t358.fail', true), ''), '0')::int;
  IF v_n > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_n; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
