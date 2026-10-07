\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 224 (an operation with NO recipient is quoted from its rail).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs (ON_ERROR_STOP aborts and the connection
-- closes, so nothing is kept). Each passing case NOTICEs.
-- Staging 2026-10-07 (operation 094eb6d6): crm_cambiar_servicio(op, 'zelle') retires the card, and with no recipient
-- crm_calcular_monto_destino (only quoted a lone recipient) left the destination NULL, so the panel showed no amount
-- for a 26,000 GYD Zelle. The operation's own rail (delivery_method) is enough to price it: same rates, same whole-USD
-- rounding down, Zelle by tier of the deposit.
-- Rates are read from crm_tasa_vigente / cerebro_zelle_tiers, so the expectations follow staging's rates.
-- =====================================================================
BEGIN;

CREATE FUNCTION pg_temp.t224_conv(p_tag text, OUT o_user uuid, OUT o_acc uuid, OUT o_ct uuid, OUT o_conv uuid)
LANGUAGE plpgsql AS $f$
BEGIN
  SELECT p.user_id, p.account_id INTO o_user, o_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (o_user, o_acc, '5990224' || p_tag, 'test224' || p_tag) RETURNING id INTO o_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (o_user, o_acc, o_ct) RETURNING id INTO o_conv;
END $f$;

-- An operation made by the current function, then given its rail (the way the bot / the panel sets it).
CREATE FUNCTION pg_temp.t224_op(p_tag text, p_dm text, p_amount numeric, p_service text DEFAULT 'remesa',
                                p_currency text DEFAULT 'GYD') RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE c record; v_op uuid;
BEGIN
  SELECT * INTO c FROM pg_temp.t224_conv(p_tag);
  v_op := cerebro_crear_operacion(c.o_conv, 0, p_currency);
  IF p_service <> 'remesa' THEN UPDATE remittance_operations SET service_type = p_service WHERE id = v_op; END IF;
  IF p_dm IS NOT NULL THEN UPDATE remittance_operations SET delivery_method = p_dm WHERE id = v_op; END IF;
  IF p_amount IS NOT NULL THEN UPDATE remittance_operations SET quoted_source_amount = p_amount WHERE id = v_op; END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t224_ben(p_op uuid, p_type text, p_pos integer DEFAULT 1, p_amount numeric DEFAULT NULL, p_cur text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, zelle_account, position, block_index, source, status, amount, currency)
  VALUES (p_op, p_type, 'Rail ' || p_pos,
          CASE WHEN p_type IN ('cuban_card', 'clasica', 'tropical') THEN '976003900124' || lpad((1000 + p_pos)::text, 4, '0') END,
          CASE WHEN p_type IN ('cuban_card', 'clasica', 'tropical') THEN '5852829' || p_pos END,
          CASE WHEN p_type = 'zelle' THEN 'rail' || p_pos || substr(md5(random()::text), 1, 6) || '@example.com' END,
          p_pos, p_pos, 'manual', 'vigente', p_amount, p_cur) RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

CREATE FUNCTION pg_temp.t224_call(p_op uuid, p_svc text, p_uid uuid) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v_r jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  v_r := crm_cambiar_servicio(p_op, p_svc);
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN v_r;
END $f$;

-- 'amount/currency/rate/origin' of the operation's destination quote ('-' for NULL).
CREATE FUNCTION pg_temp.t224_q(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(quoted_destination_amount::text, '-') || '/' || coalesce(destination_currency, '-') || '/' ||
         coalesce(quoted_destination_rate::text, '-') || '/' || coalesce(quoted_destination_origin, '-')
    FROM remittance_operations WHERE id = p_op;
$f$;

DO $$
DECLARE
  v_user uuid; v_acc uuid;
  v_usd numeric := crm_tasa_vigente('usd');
  v_cup numeric := crm_tasa_vigente('gyd');
  v_cash numeric := crm_tasa_vigente('efectivo');
  v_z0 numeric; v_ztop_min numeric; v_ztop_rate numeric; v_ztop_dep numeric;
  v_op uuid; v_ben uuid; v_conv uuid; v_r record; v_o remittance_operations%ROWTYPE; v_n integer; v_svc text;
BEGIN
  IF NOT (v_usd > 0 AND v_cup > 0 AND v_cash > 0) THEN
    RAISE EXCEPTION 'setup: usd, cup and cash rates are needed (% / % / %)', v_usd, v_cup, v_cash; END IF;
  SELECT t.rate_gyd INTO v_z0 FROM cerebro_zelle_tiers() t ORDER BY t.min_usd ASC LIMIT 1;
  SELECT t.min_usd, t.rate_gyd INTO v_ztop_min, v_ztop_rate FROM cerebro_zelle_tiers() t ORDER BY t.min_usd DESC LIMIT 1;
  v_ztop_dep := v_ztop_min * v_ztop_rate;   -- exactly the top tier's USD at the top tier's price
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;

  -- ---- a. the staging scenario: a CUP card remesa, then the service changes ----
  v_op := pg_temp.t224_op('01', 'cuban_card', 26000);
  v_ben := pg_temp.t224_ben(v_op, 'cuban_card');
  IF pg_temp.t224_q(v_op) <> round(26000 * v_cup) || '/CUP/' || v_cup || '/calculated' THEN
    RAISE EXCEPTION 'setup a: the CUP card should be quoted % CUP, got %', round(26000 * v_cup), pg_temp.t224_q(v_op); END IF;
  PERFORM pg_temp.t224_call(v_op, 'zelle', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 0 THEN
    RAISE EXCEPTION 'case a1: the card must be retired'; END IF;
  IF v_o.delivery_method <> 'zelle' OR v_o.quoted_destination_amount IS DISTINCT FROM floor(26000 / v_z0)
     OR v_o.destination_currency IS DISTINCT FROM 'USD' OR v_o.quoted_destination_rate IS DISTINCT FROM v_z0
     OR v_o.quoted_destination_origin IS DISTINCT FROM 'calculated' THEN
    RAISE EXCEPTION 'case a1: zelle with no recipient must be quoted % USD at % (calculated), got %',
      floor(26000 / v_z0), v_z0, pg_temp.t224_q(v_op); END IF;
  RAISE NOTICE 'PASS a1: cuban_card -> zelle with no recipient is quoted % USD at %', floor(26000 / v_z0), v_z0;
  PERFORM pg_temp.t224_call(v_op, 'cuban_card', v_user);
  IF pg_temp.t224_q(v_op) <> round(26000 * v_cup) || '/CUP/' || v_cup || '/calculated' THEN
    RAISE EXCEPTION 'case a2: back to the CUP rail with no recipient must be % CUP at %, got %', round(26000 * v_cup), v_cup, pg_temp.t224_q(v_op); END IF;
  RAISE NOTICE 'PASS a2: zelle -> cuban_card with no recipient is quoted % CUP', round(26000 * v_cup);

  -- ---- b. no recipient, every other rail ----
  v_op := pg_temp.t224_op('02', 'clasica', 26000);
  IF pg_temp.t224_q(v_op) <> floor(26000 / v_usd) || '/USD/' || v_usd || '/calculated' THEN
    RAISE EXCEPTION 'case b1: clasica with no recipient must be % USD at %, got %', floor(26000 / v_usd), v_usd, pg_temp.t224_q(v_op); END IF;
  v_op := pg_temp.t224_op('03', 'tropical', 26000);
  IF pg_temp.t224_q(v_op) <> floor(26000 / v_usd) || '/USD/' || v_usd || '/calculated' THEN
    RAISE EXCEPTION 'case b2: tropical with no recipient must be % USD at %, got %', floor(26000 / v_usd), v_usd, pg_temp.t224_q(v_op); END IF;
  v_op := pg_temp.t224_op('04', 'efectivo_usd', 26000);
  IF pg_temp.t224_q(v_op) <> floor(26000 / v_cash) || '/USD/' || v_cash || '/calculated' THEN
    RAISE EXCEPTION 'case b3: efectivo_usd with no recipient must be % USD at %, got %', floor(26000 / v_cash), v_cash, pg_temp.t224_q(v_op); END IF;
  RAISE NOTICE 'PASS b: clasica / tropical at the USD rate %, efectivo_usd at the cash rate %, no recipient', v_usd, v_cash;

  -- ---- c. Zelle tiers and the objective / quote rule still apply with no recipient ----
  v_op := pg_temp.t224_op('05', 'zelle', v_ztop_dep);
  IF pg_temp.t224_q(v_op) <> v_ztop_min || '/USD/' || v_ztop_rate || '/calculated' THEN
    RAISE EXCEPTION 'case c1: % GYD must reach the top tier (% USD at %), got %', v_ztop_dep, v_ztop_min, v_ztop_rate, pg_temp.t224_q(v_op); END IF;
  v_op := pg_temp.t224_op('32', 'zelle', 250000);   -- the 1,000 USD tier: 1,000 USD at 250
  IF pg_temp.t224_q(v_op) <> '1000/USD/250/calculated' THEN
    RAISE EXCEPTION 'case c1b: 250,000 GYD must be 1000 USD at 250, got %', pg_temp.t224_q(v_op); END IF;
  v_op := pg_temp.t224_op('06', 'zelle', 100 * v_z0);
  IF pg_temp.t224_q(v_op) <> 100 || '/USD/' || v_z0 || '/calculated' THEN
    RAISE EXCEPTION 'case c2: % GYD must be 100 USD at the entry tier %, got %', 100 * v_z0, v_z0, pg_temp.t224_q(v_op); END IF;
  -- the USD quote the customer was told (153) that the deposit covers wins (217/218): quote 999 + 259,740 GYD -> 999 at 260
  SELECT * INTO v_r FROM pg_temp.t224_conv('07');
  v_op := cerebro_crear_operacion(v_r.o_conv, 0, 'GYD');
  PERFORM cerebro_registrar_cotizacion(v_r.o_conv, 259740, 999, 'USD', 'calcular_usd');
  UPDATE remittance_operations SET delivery_method = 'zelle' WHERE id = v_op;
  UPDATE remittance_operations SET quoted_source_amount = 259740 WHERE id = v_op;
  IF pg_temp.t224_q(v_op) <> 999 || '/USD/260/calculated' THEN
    RAISE EXCEPTION 'case c3: quote 999 + 259,740 GYD must be 999 at 260, got %', pg_temp.t224_q(v_op); END IF;
  -- an open USD objective (fixed while a Zelle recipient existed) keeps winning after the recipient is retired
  SELECT * INTO v_r FROM pg_temp.t224_conv('08');
  v_op := cerebro_crear_operacion(v_r.o_conv, 0, 'GYD');
  UPDATE remittance_operations SET delivery_method = 'zelle' WHERE id = v_op;
  v_ben := pg_temp.t224_ben(v_op, 'zelle');
  SELECT * INTO v_r FROM cerebro_fijar_objetivo(v_r.o_conv, 999, 'usd');
  IF v_r.objetivo_gyd IS NULL THEN RAISE EXCEPTION 'fixture c4: the objective was not fixed (%)', v_r.accion; END IF;
  UPDATE remittance_operations SET quoted_source_amount = 259740 WHERE id = v_op;
  UPDATE remittance_beneficiaries SET status = 'reemplazado', replaced_at = now() WHERE id = v_ben;
  IF pg_temp.t224_q(v_op) <> 999 || '/USD/260/calculated' THEN
    RAISE EXCEPTION 'case c4: objective 999 + 259,740 GYD with the recipient retired must be 999 at 260, got %', pg_temp.t224_q(v_op); END IF;
  RAISE NOTICE 'PASS c: Zelle tiers (% -> % USD at %) and the objective rule hold with no recipient', v_ztop_dep, v_ztop_min, v_ztop_rate;

  -- ---- d. changing the deposit recomputes ----
  v_op := pg_temp.t224_op('31', 'clasica', 26000);
  UPDATE remittance_operations SET quoted_source_amount = 52000 WHERE id = v_op;
  IF pg_temp.t224_q(v_op) <> floor(52000 / v_usd) || '/USD/' || v_usd || '/calculated' THEN
    RAISE EXCEPTION 'case d: a new deposit must requote to % USD, got %', floor(52000 / v_usd), pg_temp.t224_q(v_op); END IF;
  RAISE NOTICE 'PASS d: the deposit change requotes with no recipient';

  -- ---- e. the recipient arrives: the same quote, and its own amount as today ----
  v_op := pg_temp.t224_op('09', 'zelle', 26000);
  v_ben := pg_temp.t224_ben(v_op, 'zelle');
  IF pg_temp.t224_q(v_op) <> floor(26000 / v_z0) || '/USD/' || v_z0 || '/calculated'
     OR (SELECT amount FROM remittance_beneficiaries WHERE id = v_ben) IS DISTINCT FROM floor(26000 / v_z0)
     OR (SELECT currency FROM remittance_beneficiaries WHERE id = v_ben) IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'case e1: the Zelle account keeps the quote and gets % USD, got % / %', floor(26000 / v_z0), pg_temp.t224_q(v_op),
      (SELECT amount FROM remittance_beneficiaries WHERE id = v_ben); END IF;
  v_op := pg_temp.t224_op('10', 'cuban_card', 26000);
  v_ben := pg_temp.t224_ben(v_op, 'cuban_card');
  IF pg_temp.t224_q(v_op) <> round(26000 * v_cup) || '/CUP/' || v_cup || '/calculated'
     OR (SELECT amount FROM remittance_beneficiaries WHERE id = v_ben) IS DISTINCT FROM round(26000 * v_cup) THEN
    RAISE EXCEPTION 'case e2: the card keeps the quote and gets % CUP, got % / %', round(26000 * v_cup), pg_temp.t224_q(v_op),
      (SELECT amount FROM remittance_beneficiaries WHERE id = v_ben); END IF;
  RAISE NOTICE 'PASS e: adding the recipient keeps the quote and fills the recipient amount';

  -- ---- f. unchanged behaviour ----
  -- f1. no rail and no recipient: still nothing
  v_op := pg_temp.t224_op('11', NULL, 26000);
  IF pg_temp.t224_q(v_op) <> '-/-/-/-' THEN RAISE EXCEPTION 'case f1: no rail and no recipient must stay NULL, got %', pg_temp.t224_q(v_op); END IF;
  -- f2. several recipients: the rail does not quote them (existing rules)
  v_op := pg_temp.t224_op('12', 'clasica', NULL);
  PERFORM pg_temp.t224_ben(v_op, 'clasica', 1, 50, 'USD');
  PERFORM pg_temp.t224_ben(v_op, 'clasica', 2, 50, 'USD');
  UPDATE remittance_operations SET quoted_source_amount = 26000 WHERE id = v_op;
  IF pg_temp.t224_q(v_op) <> '-/-/-/-' THEN RAISE EXCEPTION 'case f2: two recipients must not be quoted from the rail, got %', pg_temp.t224_q(v_op); END IF;
  -- f3. a manual destination amount is respected when the deposit changes
  v_op := pg_temp.t224_op('13', 'clasica', 26000);
  UPDATE remittance_operations SET quoted_destination_amount = 77 WHERE id = v_op;
  UPDATE remittance_operations SET quoted_source_amount = 52000 WHERE id = v_op;
  IF pg_temp.t224_q(v_op) <> '77/USD/-/manual' THEN RAISE EXCEPTION 'case f3: a manual amount must stand, got %', pg_temp.t224_q(v_op); END IF;
  -- f4. completed / cancelled operations are untouched
  v_op := pg_temp.t224_op('14', 'clasica', NULL);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  UPDATE remittance_operations SET quoted_source_amount = 26000 WHERE id = v_op;
  IF pg_temp.t224_q(v_op) <> '-/-/-/-' THEN RAISE EXCEPTION 'case f4: a cancelled operation must not be quoted, got %', pg_temp.t224_q(v_op); END IF;
  -- f5. a non-GYD source is untouched
  v_op := pg_temp.t224_op('15', 'clasica', 100, 'remesa', 'USD');
  IF pg_temp.t224_q(v_op) <> '-/-/-/-' THEN RAISE EXCEPTION 'case f5: a USD source must not be quoted, got %', pg_temp.t224_q(v_op); END IF;
  -- f6. recarga / saldo / combo / visa never get a destination quote
  v_n := 20;
  FOREACH v_svc IN ARRAY ARRAY['recarga', 'saldo', 'combo', 'visa'] LOOP
    v_n := v_n + 1;
    v_op := pg_temp.t224_op(v_n::text, 'clasica', 26000, v_svc);
    IF pg_temp.t224_q(v_op) <> '-/-/-/-' THEN RAISE EXCEPTION 'case f6: % must not get a destination quote, got %', v_svc, pg_temp.t224_q(v_op); END IF;
  END LOOP;
  RAISE NOTICE 'PASS f: no rail, several recipients, manual lock, closed, USD source and non-remesa services stay as they were';

  -- ---- g. the bot path: the rail is marked before the card arrives ----
  SELECT * INTO v_r FROM pg_temp.t224_conv('30');
  v_conv := v_r.o_conv;
  v_op := cerebro_crear_operacion(v_conv, 26000, 'GYD');
  PERFORM 1 FROM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec224-g');
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'clasica'
     OR pg_temp.t224_q(v_op) <> floor(26000 / v_usd) || '/USD/' || v_usd || '/calculated' THEN
    RAISE EXCEPTION 'case g1: marcar_destino_usd(clasica) must show % USD before the card, got %', floor(26000 / v_usd), pg_temp.t224_q(v_op); END IF;
  v_ben := pg_temp.t224_ben(v_op, 'clasica');
  IF pg_temp.t224_q(v_op) <> floor(26000 / v_usd) || '/USD/' || v_usd || '/calculated'
     OR (SELECT amount FROM remittance_beneficiaries WHERE id = v_ben) IS DISTINCT FROM floor(26000 / v_usd) THEN
    RAISE EXCEPTION 'case g2: once the card arrives the quote stays % USD and the card gets it, got % / %', floor(26000 / v_usd), pg_temp.t224_q(v_op),
      (SELECT amount FROM remittance_beneficiaries WHERE id = v_ben); END IF;
  RAISE NOTICE 'PASS g: the bot marks clasica and the USD quote shows before the card; the card then gets the same amount';

  RAISE NOTICE 'ALL PASS: quote-from-rail';
END $$;

ROLLBACK;
