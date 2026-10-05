-- =====================================================================
-- Assertion for migration 216 (Zelle tier prices in the calculator rate versions). Self-reverting: one DO block that
-- ends in RAISE EXCEPTION 'ALL PASS'. Builds its own contact/conversation/operation fixtures; account and user come from
-- whatsapp_config + profiles.
--
-- odd/tasks/zelle-tiered-rate.md (T1b). The tier minimums are fixed (50, 1,000, 2,000 USD); the three prices are columns
-- of calculator_rate_versions (zelle_sell_gyd, zelle_sell_gyd_1000, zelle_sell_gyd_2000). A NULL price falls back: base
-- tier -> usdt_sell_gyd, 1,000 tier -> base price, 2,000 tier -> 1,000 price. Same selection rule as 215: the best tier
-- whose floor(gyd / price) reaches its minimum USD, else the base tier.
-- Run it as: BEGIN; \i zelle-tier-prices.sql; ROLLBACK;
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.zp_op(p_tag text, p_gyd numeric) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900216' || p_tag, 'test216' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', p_gyd) RETURNING id INTO v_op;
  RETURN v_op;
END $$;

-- Appends a rate version on top of the current one: the three Zelle prices (NULL allowed) and, when given, usdt_sell_gyd.
CREATE OR REPLACE FUNCTION pg_temp.zp_version(p_acc uuid, p_z1 numeric, p_z2 numeric, p_z3 numeric, p_sell numeric DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE c calculator_rate_versions;
BEGIN
  c := calculator_rates_vigentes(p_acc);
  INSERT INTO calculator_rate_versions (account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, efectivo_usd_gyd,
                                        recarga_costo_usdt, zelle_sell_gyd, zelle_sell_gyd_1000, zelle_sell_gyd_2000)
  VALUES (p_acc, c.cup_global_rate, c.usdt_buy_gyd, coalesce(p_sell, c.usdt_sell_gyd), c.usdt_sell_cup, c.efectivo_usd_gyd,
          c.recarga_costo_usdt, p_z1, p_z2, p_z3);
END $$;

DO $$
DECLARE
  v_op uuid; v_acc uuid; v_user uuid; v_r record; v_rates calculator_rate_versions; v_new calculator_rate_versions; v_single numeric;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;

  -- 1. Seed: the current version carries the 215 prices, and the config row is gone.
  v_rates := calculator_rates_vigentes(v_acc);
  IF v_rates.zelle_sell_gyd IS DISTINCT FROM 260 OR v_rates.zelle_sell_gyd_1000 IS DISTINCT FROM 250
     OR v_rates.zelle_sell_gyd_2000 IS DISTINCT FROM 245 THEN
    RAISE EXCEPTION 'case 1: current version must be seeded 260/250/245, got %/%/%',
      v_rates.zelle_sell_gyd, v_rates.zelle_sell_gyd_1000, v_rates.zelle_sell_gyd_2000; END IF;
  IF EXISTS (SELECT 1 FROM cerebro_config WHERE clave = 'zelle_tiers') THEN
    RAISE EXCEPTION 'case 1: cerebro_config zelle_tiers must be removed (one source of truth)'; END IF;
  IF (SELECT array_agg(min_usd || ':' || rate_gyd ORDER BY min_usd) FROM cerebro_zelle_tiers()) IS DISTINCT FROM ARRAY['50:260','1000:250','2000:245'] THEN
    RAISE EXCEPTION 'case 1: cerebro_zelle_tiers must be 50:260, 1000:250, 2000:245'; END IF;

  -- 2. New prices 265/255/250 change the quotes (usdt_sell_gyd stays 260).
  PERFORM pg_temp.zp_version(v_acc, 265, 255, 250);
  v_single := crm_tasa_vigente('usd');
  -- 255,000 GYD: floor(255000/255) = 1000 -> tier 1,000 at 255.
  SELECT * INTO v_r FROM cerebro_zelle_cotizar_gyd(255000);
  IF v_r.usd IS DISTINCT FROM 1000 OR v_r.tasa IS DISTINCT FROM 255 THEN
    RAISE EXCEPTION 'case 2: 255,000 GYD must quote 1000 USD at 255, got % at %', v_r.usd, v_r.tasa; END IF;
  -- 250,000 GYD does not reach 1,000 USD at 255 (980), so it stays on the base tier: 943 at 265.
  SELECT * INTO v_r FROM cerebro_zelle_cotizar_gyd(250000);
  IF v_r.usd IS DISTINCT FROM 943 OR v_r.tasa IS DISTINCT FROM 265 THEN
    RAISE EXCEPTION 'case 2: 250,000 GYD must quote 943 USD at 265, got % at %', v_r.usd, v_r.tasa; END IF;
  SELECT * INTO v_r FROM cerebro_zelle_cotizar_gyd(254999);
  IF v_r.usd IS DISTINCT FROM 962 OR v_r.tasa IS DISTINCT FROM 265 THEN
    RAISE EXCEPTION 'case 2: 254,999 GYD must quote 962 USD at 265, got % at %', v_r.usd, v_r.tasa; END IF;
  -- 2,000 tier: 500,000 / 250 = 2000.
  SELECT * INTO v_r FROM cerebro_zelle_cotizar_gyd(500000);
  IF v_r.usd IS DISTINCT FROM 2000 OR v_r.tasa IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 2: 500,000 GYD must quote 2000 USD at 250, got % at %', v_r.usd, v_r.tasa; END IF;
  SELECT * INTO v_r FROM cerebro_zelle_cotizar_gyd(499999);
  IF v_r.usd IS DISTINCT FROM 1960 OR v_r.tasa IS DISTINCT FROM 255 THEN
    RAISE EXCEPTION 'case 2: 499,999 GYD must quote 1960 USD at 255, got % at %', v_r.usd, v_r.tasa; END IF;
  IF cerebro_tasa_zelle(49) <> 265 OR cerebro_tasa_zelle(50) <> 265 OR cerebro_tasa_zelle(999) <> 265 OR cerebro_tasa_zelle(1000) <> 255
     OR cerebro_tasa_zelle(1999) <> 255 OR cerebro_tasa_zelle(2000) <> 250 THEN
    RAISE EXCEPTION 'case 2: cerebro_tasa_zelle must follow 265/255/250'; END IF;

  -- 3. A Zelle beneficiary on the panel path follows the new prices.
  v_op := pg_temp.zp_op('03', 255000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Price A', 'pricea@example.com', 1, 1, 'manual', 'vigente');
  PERFORM crm_calcular_monto_destino(v_op);
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 1000 OR v_r.r IS DISTINCT FROM 255 THEN
    RAISE EXCEPTION 'case 3: Zelle 255,000 GYD must be 1000 USD at 255, got % at %', v_r.a, v_r.r; END IF;

  -- 4. USDT, Clasica and Tropical keep the single rate whatever the Zelle prices are.
  v_op := pg_temp.zp_op('04', 255000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'clasica', 'Price B', '4111111111111111', '5927000000', 1, 1, 'manual', 'vigente');
  PERFORM crm_calcular_monto_destino(v_op);
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM floor(255000 / v_single) OR v_r.r IS DISTINCT FROM v_single THEN
    RAISE EXCEPTION 'case 4: Clasica must keep the single rate %, got % at %', v_single, v_r.a, v_r.r; END IF;

  -- 5. NULL fallback: no Zelle prices -> every tier is the single rate (usdt_sell_gyd).
  PERFORM pg_temp.zp_version(v_acc, NULL, NULL, NULL, 262);
  IF (SELECT array_agg(min_usd || ':' || rate_gyd ORDER BY min_usd) FROM cerebro_zelle_tiers()) IS DISTINCT FROM ARRAY['50:262','1000:262','2000:262'] THEN
    RAISE EXCEPTION 'case 5: with no Zelle price every tier must fall back to usdt_sell_gyd 262'; END IF;
  SELECT * INTO v_r FROM cerebro_zelle_cotizar_gyd(500000);
  IF v_r.usd IS DISTINCT FROM floor(500000 / 262.0) OR v_r.tasa IS DISTINCT FROM 262 THEN
    RAISE EXCEPTION 'case 5: 500,000 GYD with no Zelle price must be floor(500000/262) at 262, got % at %', v_r.usd, v_r.tasa; END IF;
  -- Only the 1,000 price set: base falls back to the single rate, 2,000 follows the 1,000 price.
  PERFORM pg_temp.zp_version(v_acc, NULL, 255, NULL, 262);
  IF (SELECT array_agg(min_usd || ':' || rate_gyd ORDER BY min_usd) FROM cerebro_zelle_tiers()) IS DISTINCT FROM ARRAY['50:262','1000:255','2000:255'] THEN
    RAISE EXCEPTION 'case 5: base NULL + 1000 at 255 must give 262/255/255'; END IF;
  -- Only the 2,000 price missing: it follows the 1,000 price.
  PERFORM pg_temp.zp_version(v_acc, 265, 255, NULL, 262);
  IF (SELECT array_agg(min_usd || ':' || rate_gyd ORDER BY min_usd) FROM cerebro_zelle_tiers()) IS DISTINCT FROM ARRAY['50:265','1000:255','2000:255'] THEN
    RAISE EXCEPTION 'case 5: 2000 NULL must follow the 1000 price'; END IF;

  -- 6. crm_set_calculator_rates writes the three prices, carries them forward when absent, and validates them.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_new := crm_set_calculator_rates(v_acc, '{"zelle_sell_gyd": 270, "zelle_sell_gyd_1000": 258, "zelle_sell_gyd_2000": 251}'::jsonb);
  IF v_new.zelle_sell_gyd IS DISTINCT FROM 270 OR v_new.zelle_sell_gyd_1000 IS DISTINCT FROM 258 OR v_new.zelle_sell_gyd_2000 IS DISTINCT FROM 251 THEN
    RAISE EXCEPTION 'case 6: the RPC must store 270/258/251, got %/%/%', v_new.zelle_sell_gyd, v_new.zelle_sell_gyd_1000, v_new.zelle_sell_gyd_2000; END IF;
  v_new := crm_set_calculator_rates(v_acc, '{"usdt_buy_gyd": 241}'::jsonb);
  IF v_new.zelle_sell_gyd IS DISTINCT FROM 270 OR v_new.zelle_sell_gyd_1000 IS DISTINCT FROM 258 OR v_new.zelle_sell_gyd_2000 IS DISTINCT FROM 251
     OR v_new.usdt_buy_gyd IS DISTINCT FROM 241 THEN
    RAISE EXCEPTION 'case 6: an unrelated edit must carry the Zelle prices forward'; END IF;
  BEGIN
    PERFORM crm_set_calculator_rates(v_acc, '{"zelle_sell_gyd_1000": 0}'::jsonb);
    RAISE EXCEPTION 'case 6: a zero Zelle price must be rejected';
  EXCEPTION WHEN sqlstate '22023' THEN NULL;
  END;
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT * INTO v_r FROM cerebro_zelle_cotizar_gyd(258000);
  IF v_r.usd IS DISTINCT FROM 1000 OR v_r.tasa IS DISTINCT FROM 258 THEN
    RAISE EXCEPTION 'case 6: after the RPC 258,000 GYD must quote 1000 USD at 258, got % at %', v_r.usd, v_r.tasa; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
