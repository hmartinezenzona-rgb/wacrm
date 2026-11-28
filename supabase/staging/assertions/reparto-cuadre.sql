\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 359 (cerebro_reparto_cuadre: the open reparto versus the verified deposit, for the conversation
-- context). It needs 358 (cerebro_reparto_disponible); run as  BEGIN; 358; 359; <this file>; ROLLBACK;  or with 358 applied.
-- Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Rates are pinned inside the transaction (gyd 3.6, usd 260). Cases (real 2026-11-07 shapes as synthetic fixtures):
--   1. over (2 x 36,000 CUP on 10,000 GYD): estado excede, difference -36000;
--   2. under (3 x 15,000 CUP on 15,000 GYD): estado sobra, difference 9000, equal share 18000;
--   3. exact (18,000 + 18,000): cuadra; 4. partial (a card without amount): faltan_montos, 18000 left;
--   5. unverified deposit, no reparto, a single card, a closed operation, unknown conversation: NULL;
--   6. mixed CUP + Clasica USD compared in GYD, per-slot amount and currency;
--   7. the shared arithmetic cerebro_reparto_sumas agrees with cerebro_guardar_reparto (excede <=> refused);
--   8. grants: service_role only.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t359.fail', (coalesce(nullif(current_setting('t359.fail', true), ''), '0')::int + 1)::text, true);
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
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900359' || p_tag, 'test359' || p_tag) RETURNING id INTO v_ct;
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


DO $$
DECLARE
  c1 constant text := '9238123432101987';
  c2 constant text := '9238123432101237';
  c3 constant text := '9205129978614908';
  v_acc uuid; v_conv uuid; v_op uuid; v_r text; v_j jsonb; v_s record; v_n int;
BEGIN
  SELECT w.account_id INTO v_acc FROM whatsapp_config w LIMIT 1;
  INSERT INTO calculator_rate_versions (account_id, cup_global_rate, usdt_sell_gyd, zelle_sell_gyd, effective_at)
  VALUES (v_acc, 3.6, 260, 260, now() + interval '1000 days');
  PERFORM pg_temp.chk(crm_tasa_vigente('gyd') = 3.6 AND crm_tasa_vigente('usd') = 260, 'setup: pinned rates 3.6 / 260');
  PERFORM pg_temp.chk(to_regprocedure('public.cerebro_reparto_cuadre(uuid)') IS NOT NULL, '0 cerebro_reparto_cuadre exists');
  IF to_regprocedure('public.cerebro_reparto_cuadre(uuid)') IS NULL THEN
    RAISE EXCEPTION '% expectation(s) failed (function missing)', coalesce(nullif(current_setting('t359.fail', true), ''), '0');
  END IF;

  -- 1. Over: saved while unverified, then the deposit is verified (verification is never blocked).
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('01', 'collecting_information', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '36000', c2, '36000');
  PERFORM pg_temp.chk(cerebro_reparto_cuadre(v_conv) IS NULL, '1a unverified deposit gives NULL');
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op;
  v_j := cerebro_reparto_cuadre(v_conv);
  PERFORM pg_temp.chk(v_j->>'estado' = 'excede', '1b estado excede: ' || coalesce(v_j::text, 'null'));
  PERFORM pg_temp.chk((v_j->>'op_id')::uuid = v_op AND (v_j->>'base_gyd')::numeric = 10000 AND (v_j->>'total_cup')::numeric = 36000
                      AND (v_j->>'total_usd')::numeric = 38, '1c op, base and totals');
  PERFORM pg_temp.chk((v_j->>'tarjetas')::int = 2 AND (v_j->>'suma_cup_equiv')::numeric = 72000 AND (v_j->>'diferencia_cup')::numeric = -36000
                      AND (v_j->>'por_tarjeta_igual_cup')::numeric = 18000, '1d tarjetas 2, suma 72000, diferencia -36000, igual 18000');
  PERFORM pg_temp.chk(v_j->'asignado' = '[{"posicion":1,"monto":36000,"moneda":"CUP"},{"posicion":2,"monto":36000,"moneda":"CUP"}]'::jsonb,
                      '1e asignado per slot: ' || coalesce((v_j->'asignado')::text, 'null'));

  -- 2. Under (real case f80a33a0): 3 x 15,000 CUP on 15,000 GYD = 54,000 CUP.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('02', 'ready_to_transfer', 15000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '15000', c2, '15000', c3, '15000');
  v_j := cerebro_reparto_cuadre(v_conv);
  PERFORM pg_temp.chk(v_j->>'estado' = 'sobra' AND (v_j->>'diferencia_cup')::numeric = 9000 AND (v_j->>'suma_cup_equiv')::numeric = 45000,
                      '2a sobra 9000: ' || coalesce(v_j::text, 'null'));
  PERFORM pg_temp.chk((v_j->>'tarjetas')::int = 3 AND (v_j->>'total_cup')::numeric = 54000 AND (v_j->>'por_tarjeta_igual_cup')::numeric = 18000,
                      '2b 3 cards, 54000 total, 18000 each');

  -- 3. Exact.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('03', 'ready_to_transfer', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', c2, '18000');
  v_j := cerebro_reparto_cuadre(v_conv);
  PERFORM pg_temp.chk(v_j->>'estado' = 'cuadra' AND (v_j->>'diferencia_cup')::numeric = 0, '3 cuadra: ' || coalesce(v_j::text, 'null'));

  -- 4. Partial: the second card has no amount yet.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('04', 'ready_to_transfer', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', c2, '');
  v_j := cerebro_reparto_cuadre(v_conv);
  PERFORM pg_temp.chk(v_j->>'estado' = 'faltan_montos' AND (v_j->>'diferencia_cup')::numeric = 18000 AND (v_j->>'tarjetas')::int = 2,
                      '4a faltan_montos, 18000 left: ' || coalesce(v_j::text, 'null'));
  PERFORM pg_temp.chk(v_j->'asignado'->1->'monto' = 'null'::jsonb, '4b the card without amount shows a null amount');

  -- 5. NULL cases.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('05', 'ready_to_transfer', 10000);
  PERFORM pg_temp.chk(cerebro_reparto_cuadre(v_conv) IS NULL, '5a verified deposit without reparto gives NULL');
  PERFORM pg_temp.rp(v_conv, v_op, c1, '36000', '', '');
  PERFORM pg_temp.chk(cerebro_reparto_cuadre(v_conv) IS NULL, '5b a single card is not a reparto: NULL');
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('06', 'ready_to_transfer', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', c2, '18000');
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_op;
  PERFORM pg_temp.chk(cerebro_reparto_cuadre(v_conv) IS NULL, '5c a cancelled operation gives NULL');
  PERFORM pg_temp.chk(cerebro_reparto_cuadre(gen_random_uuid()) IS NULL, '5d unknown conversation gives NULL');

  -- 6. Mixed rails: 18000 CUP (5000 GYD) + 19 USD Clasica (4940 GYD) on 10000 GYD.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('07', 'ready_to_transfer', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', c2, '19 USD Clasica');
  v_j := cerebro_reparto_cuadre(v_conv);
  PERFORM pg_temp.chk(v_j->>'estado' = 'cuadra', '6a mixed within tolerance cuadra: ' || coalesce(v_j::text, 'null'));
  PERFORM pg_temp.chk(v_j->'asignado'->1->>'moneda' = 'USD' AND (v_j->'asignado'->1->>'monto')::numeric = 19, '6b the Clasica slot is USD 19');
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('08', 'ready_to_transfer', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', c2, '10 USD Clasica');
  v_j := cerebro_reparto_cuadre(v_conv);
  PERFORM pg_temp.chk(v_j->>'estado' = 'sobra' AND (v_j->>'diferencia_cup')::numeric = 8640, '6c mixed under: sobra 8640: ' || coalesce(v_j::text, 'null'));

  -- 7. One arithmetic for both: the shared function and the tool agree.
  SELECT * INTO v_s FROM cerebro_reparto_sumas(ARRAY['36000 CUP', '36000 CUP', NULL], 2, 10000, 3.6, 260);
  PERFORM pg_temp.chk(v_s.estado = 'excede' AND v_s.con = 2 AND v_s.ncup = 2 AND v_s.sum_cup = 72000, '7a sumas: excede');
  SELECT * INTO v_s FROM cerebro_reparto_sumas(ARRAY['18000 CUP', NULL, NULL], 2, 10000, 3.6, 260);
  PERFORM pg_temp.chk(v_s.estado = 'faltan_montos', '7b sumas: faltan_montos');
  SELECT * INTO v_s FROM cerebro_reparto_sumas(ARRAY['15000 CUP', '15000 CUP', '15000 CUP'], 3, 15000, 3.6, 260);
  PERFORM pg_temp.chk(v_s.estado = 'sobra' AND round(v_s.rem * 3.6) = 9000, '7c sumas: sobra 9000');
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('09', 'ready_to_transfer', 10000);
  v_r := pg_temp.rp(v_conv, v_op, c1, '36000', c2, '36000');
  PERFORM pg_temp.chk(v_r LIKE 'NO SE GUARDO NADA%', '7d the tool refuses what the context calls excede');

  -- 8. Grants.
  PERFORM pg_temp.chk(has_function_privilege('service_role', 'public.cerebro_reparto_cuadre(uuid)', 'EXECUTE')
                      AND NOT has_function_privilege('anon', 'public.cerebro_reparto_cuadre(uuid)', 'EXECUTE')
                      AND NOT has_function_privilege('authenticated', 'public.cerebro_reparto_cuadre(uuid)', 'EXECUTE'), '8 grants: service_role only');

  v_n := coalesce(nullif(current_setting('t359.fail', true), ''), '0')::int;
  IF v_n > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_n; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
