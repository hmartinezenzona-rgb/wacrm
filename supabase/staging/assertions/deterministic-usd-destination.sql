\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written (operation-receipts.sql once left staging's notify_url on a no-op this way).
-- deterministic-usd-destination.sql — self-reverting assertion for 157
-- (cerebro_destino_pendiente + cerebro_detectar_destino +
-- cerebro_registrar_destino + the BEFORE INSERT trigger + the calculator's
-- dollar branch + the close-trigger cleanup).
--
-- Proves:
--   1. the detector reads one turn of the customer's words: Clásica ->
--      'clasica', Tropical -> 'tropical', 'en CUP' -> 'cuban_card', both
--      rails named -> NULL, nothing -> NULL, and a word that merely STARTS
--      with 'clasica' is not a delivery rail;
--   2. VIA FIRST, CARD LATER: with no operation at all, registrar_destino
--      still stores the destination, and the ordinary n8n path afterwards
--      (a remesas deal carrying 'BENEFICIARIO (auto) / Tarjeta / Celular'
--      notes) ends with a 'clasica' beneficiary AND delivery_method =
--      'clasica' — no n8n change, no marcar_destino_usd call;
--   3. CARD FIRST, VIA LATER: an operation already quoted 120,000 CUP for a
--      cuban_card beneficiary is re-typed to tropical and re-quoted in USD
--      (40,000 GYD at 260 = 153 USD, floored), on both the operation and
--      the beneficiary;
--   4. a zelle beneficiary is never re-typed and never re-quoted by a
--      'Tropical' statement;
--   5. closing the remesa deletes the pending row — and still deletes the
--      partial-beneficiary accumulator 155 put there (the verbatim copy).
--
-- MUST run inside an already-open transaction that ends in ROLLBACK (docker
-- psql against the staging URL, wrapped in BEGIN ... ROLLBACK). Never
-- COMMIT. Never run against production. Builds its own fixtures, same
-- posture as operation-receipts.sql and destination-amount.sql.
--
-- Case 5 needs a HUMAN to close the remesa: 096's completion guard reverts
-- an automation write of status='completed', so the run asserts against a
-- JWT that is a real agent of the fixture account (the idiom
-- destination-amount.sql case 6 uses).
--
-- Rates are inserted at current_date + 1000 so they are always the newest
-- whatever real staging data exists, with ON CONFLICT so this file can
-- share a transaction with destination-amount.sql (tasas PK is
-- (fecha, moneda)).
--
-- RED:   against staging WITHOUT 157 the run dies at case 1 — the detector
--        does not exist. Case 1 raises on failure on purpose (no nested
--        handler), so RED stops there instead of reporting five failures.
-- GREEN: after 157 is applied — all cases PASS.

SAVEPOINT deterministic_usd_destination;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_contact_a      uuid;
  v_contact_b      uuid;
  v_contact_c      uuid;
  v_pipeline_owner uuid;
  v_conv_a         uuid;
  v_conv_b         uuid;
  v_conv_c         uuid;
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_auto_stage     CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';

  v_deal_id        uuid;
  v_op_a_id        uuid;
  v_op_b_id        uuid;
  v_op_c_id        uuid;
  v_ben_id         uuid;
  v_detected       text;
  v_tipo           text;
  v_amount         numeric;
  v_ben_amount     numeric;
  v_currency       text;
  v_ben_currency   text;
  v_rate           numeric;
  v_origin         text;
  v_ben_origin     text;
  v_method         text;
  v_card           text;
  v_phone          text;
  v_count          integer;
  v_fail_count     integer := 0;
BEGIN
  -- ---- fixtures ---------------------------------------------------------
  -- Same posture as destination-amount.sql: no reliance on the signup
  -- trigger, personas built by hand. The n8n Postgres credential is
  -- service_role, so nothing here needs a JWT to reach the internal tables.
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'destino-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'destino-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'deterministic destino test account', v_owner_user)
    RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'destino owner', 'destino-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'destino agent', 'destino-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  -- Loopback no-op notify config so a committed notify can never reach a
  -- real endpoint. Safe to overwrite: this transaction always rolls back.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/destino-noop')
    ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'destino-noop')
    ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position")
    VALUES (v_auto_stage, v_pipeline_id, 'Remesa abierta', 10) ON CONFLICT (id) DO NOTHING;

  -- Three conversations, one per case: case 3's registrar_destino only
  -- applies when the conversation has EXACTLY ONE open remesa, so the
  -- cases must not share one.
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_owner_user, '15550000701', 'Destino A', v_account_id) RETURNING id INTO v_contact_a;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_owner_user, v_contact_a, v_account_id) RETURNING id INTO v_conv_a;

  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_owner_user, '15550000702', 'Destino B', v_account_id) RETURNING id INTO v_contact_b;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_owner_user, v_contact_b, v_account_id) RETURNING id INTO v_conv_b;

  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_owner_user, '15550000703', 'Destino C', v_account_id) RETURNING id INTO v_contact_c;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_owner_user, v_contact_c, v_account_id) RETURNING id INTO v_conv_c;

  -- tasas is a view over calculator_rate_versions: the live rates are used.
  -- The expected figures below assume 260 GYD/USD and 3 CUP/GYD; case 0
  -- fails loudly if staging's rates moved.
  IF crm_tasa_vigente('usd') <> 260 OR crm_tasa_vigente('gyd') <> 3 THEN
    RAISE EXCEPTION 'FAIL [case 0] staging rates are usd=% gyd=%, the expectations assume 260 and 3',
      crm_tasa_vigente('usd'), crm_tasa_vigente('gyd');
  END IF;

  -- ---- case 1: the detector --------------------------------------------
  -- Fails hard (no nested handler): this is where RED must die.
  BEGIN
    v_detected := cerebro_detectar_destino('Es para recibir Clásica en Cuba');
    IF v_detected IS DISTINCT FROM 'clasica' THEN
      RAISE EXCEPTION 'FAIL [case 1a] ''Es para recibir Clásica en Cuba'' -> %, expected clasica', v_detected;
    END IF;

    v_detected := cerebro_detectar_destino('tropical');
    IF v_detected IS DISTINCT FROM 'tropical' THEN
      RAISE EXCEPTION 'FAIL [case 1b] ''tropical'' -> %, expected tropical', v_detected;
    END IF;

    v_detected := cerebro_detectar_destino('clasica o tropical');
    IF v_detected IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL [case 1c] ''clasica o tropical'' -> %, expected NULL (ambiguous)', v_detected;
    END IF;

    v_detected := cerebro_detectar_destino('en CUP');
    IF v_detected IS DISTINCT FROM 'cuban_card' THEN
      RAISE EXCEPTION 'FAIL [case 1d] ''en CUP'' -> %, expected cuban_card', v_detected;
    END IF;

    v_detected := cerebro_detectar_destino('hola');
    IF v_detected IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL [case 1e] ''hola'' -> %, expected NULL', v_detected;
    END IF;

    v_detected := cerebro_detectar_destino('clasicamente');
    IF v_detected IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL [case 1f] ''clasicamente'' -> %, expected NULL (not a whole word)', v_detected;
    END IF;

    -- Accent and case really are tolerated, both directions.
    v_detected := cerebro_detectar_destino('QUIERO QUE SEA CLÁSICA');
    IF v_detected IS DISTINCT FROM 'clasica' THEN
      RAISE EXCEPTION 'FAIL [case 1g] ''QUIERO QUE SEA CLÁSICA'' -> %, expected clasica', v_detected;
    END IF;

    v_detected := cerebro_detectar_destino('son pesos cubanos, no dolares');
    IF v_detected IS DISTINCT FROM 'cuban_card' THEN
      RAISE EXCEPTION 'FAIL [case 1h] ''son pesos cubanos'' -> %, expected cuban_card', v_detected;
    END IF;

    v_detected := cerebro_detectar_destino('que es mejor, Tropical o clasica?');
    IF v_detected IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL [case 1i] both rails named -> %, expected NULL', v_detected;
    END IF;

    RAISE NOTICE 'PASS [case 1] the detector reads clasica/tropical/cuban_card and refuses the ambiguous and the partial word';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'deterministic-usd-destination: %', SQLERRM;
  END;

  -- ---- case 2: via first, card later -----------------------------------
  BEGIN
    v_detected := cerebro_registrar_destino(v_conv_a, 'Es para recibir Clásica en Cuba');
    IF v_detected IS DISTINCT FROM 'clasica' THEN
      RAISE EXCEPTION 'FAIL [case 2a] registrar_destino returned %, expected clasica', v_detected;
    END IF;

    SELECT tipo INTO v_tipo FROM cerebro_destino_pendiente WHERE conversation_id = v_conv_a;
    IF v_tipo IS DISTINCT FROM 'clasica' THEN
      RAISE EXCEPTION 'FAIL [case 2b] no pending row (or wrong tipo %) for a conversation with no operation', v_tipo;
    END IF;

    SELECT count(*) INTO v_count FROM remittance_operations WHERE conversation_id = v_conv_a;
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'FAIL [case 2c] the fixture conversation should have no operations yet, found %', v_count;
    END IF;

    -- The ordinary n8n beneficiary path, byte for byte what the
    -- "Registrar beneficiario auto" node writes into deals.notes.
    INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                       stage_id, title, value, currency, notes, status)
    VALUES (v_owner_user, v_account_id, v_contact_a, v_conv_a, v_pipeline_id,
            v_auto_stage, 'Remesa +15550000701', 0, 'GYD',
            E'BENEFICIARIO (auto)\nTarjeta: 9234567890123456\nCelular: 5351234567',
            'open')
    RETURNING id INTO v_deal_id;

    SELECT id INTO v_op_a_id FROM remittance_operations WHERE deal_id = v_deal_id;
    IF v_op_a_id IS NULL THEN
      RAISE EXCEPTION 'FAIL [case 2d] deal % produced no operation', v_deal_id;
    END IF;

    SELECT count(*) INTO v_count FROM remittance_beneficiaries
     WHERE operation_id = v_op_a_id AND status = 'vigente';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'FAIL [case 2e] expected 1 vigente beneficiary, got %', v_count;
    END IF;

    SELECT beneficiary_type, card_number, phone INTO v_tipo, v_card, v_phone
      FROM remittance_beneficiaries
     WHERE operation_id = v_op_a_id AND status = 'vigente';

    IF v_tipo IS DISTINCT FROM 'clasica' THEN
      RAISE EXCEPTION 'FAIL [case 2f] beneficiary_type is %, expected clasica (the BEFORE INSERT trigger did not fire)', v_tipo;
    END IF;

    IF v_card IS DISTINCT FROM '9234567890123456' OR v_phone IS DISTINCT FROM '5351234567' THEN
      RAISE EXCEPTION 'FAIL [case 2g] re-typing the destination lost the card/phone: card=% phone=%', v_card, v_phone;
    END IF;

    SELECT delivery_method INTO v_method FROM remittance_operations WHERE id = v_op_a_id;
    IF v_method IS DISTINCT FROM 'clasica' THEN
      RAISE EXCEPTION 'FAIL [case 2h] delivery_method is %, expected clasica', v_method;
    END IF;

    RAISE NOTICE 'PASS [case 2] via first, card later: the ordinary notes path produced a clasica beneficiary and delivery_method';
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] via-first/card-later raised: % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 3: card first, via later -----------------------------------
  BEGIN
    INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type,
                                       source_currency, quoted_source_amount)
    VALUES (gen_random_uuid(), v_account_id, v_conv_b, 'deposit_verification', 'remesa', 'GYD', 40000)
    RETURNING id INTO v_op_b_id;

    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number,
                                          phone, position, status, source)
    VALUES (v_op_b_id, 'cuban_card', 'Beneficiario B', '9234567890123456', '5351234567', 1, 'vigente', 'staging_test');

    -- The bug this migration exists for, asserted first: on a cuban_card
    -- beneficiary 40,000 GYD quotes as 120,000 CUP.
    SELECT quoted_destination_amount, destination_currency INTO v_amount, v_currency
      FROM remittance_operations WHERE id = v_op_b_id;
    IF v_currency IS DISTINCT FROM 'CUP' OR v_amount IS DISTINCT FROM 120000 THEN
      RAISE EXCEPTION 'FAIL [case 3a] fixture is not in the bug state: amount=% currency=% (expected 120000 CUP)', v_amount, v_currency;
    END IF;

    v_detected := cerebro_registrar_destino(v_conv_b, 'va a ser por tropical');
    IF v_detected IS DISTINCT FROM 'tropical' THEN
      RAISE EXCEPTION 'FAIL [case 3b] registrar_destino returned %, expected tropical', v_detected;
    END IF;

    SELECT id, beneficiary_type INTO v_ben_id, v_tipo
      FROM remittance_beneficiaries WHERE operation_id = v_op_b_id AND status = 'vigente';
    IF v_tipo IS DISTINCT FROM 'tropical' THEN
      RAISE EXCEPTION 'FAIL [case 3c] beneficiary_type is %, expected tropical', v_tipo;
    END IF;

    SELECT delivery_method INTO v_method FROM remittance_operations WHERE id = v_op_b_id;
    IF v_method IS DISTINCT FROM 'tropical' THEN
      RAISE EXCEPTION 'FAIL [case 3d] delivery_method is %, expected tropical', v_method;
    END IF;

    SELECT quoted_destination_amount, destination_currency, quoted_destination_rate, quoted_destination_origin
      INTO v_amount, v_currency, v_rate, v_origin
      FROM remittance_operations WHERE id = v_op_b_id;
    SELECT amount, currency, amount_origin INTO v_ben_amount, v_ben_currency, v_ben_origin
      FROM remittance_beneficiaries WHERE id = v_ben_id;

    IF v_currency IS DISTINCT FROM 'USD' OR v_amount IS DISTINCT FROM 153
       OR v_rate IS DISTINCT FROM 260 OR v_origin IS DISTINCT FROM 'calculated' THEN
      RAISE EXCEPTION 'FAIL [case 3e] operation is not re-quoted in USD: amount=% currency=% rate=% origin=% (expected 153 USD at 260, calculated)', v_amount, v_currency, v_rate, v_origin;
    END IF;

    IF v_ben_currency IS DISTINCT FROM 'USD' OR v_ben_amount IS DISTINCT FROM 153 OR v_ben_origin IS DISTINCT FROM 'calculated' THEN
      RAISE EXCEPTION 'FAIL [case 3f] beneficiary is not re-quoted in USD: amount=% currency=% origin=%', v_ben_amount, v_ben_currency, v_ben_origin;
    END IF;

    RAISE NOTICE 'PASS [case 3] card first, via later: cuban_card/120000 CUP became tropical/153 USD on operation and beneficiary';
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] card-first/via-later raised: % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 4: a zelle beneficiary is never converted ------------------
  BEGIN
    INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type,
                                       source_currency, quoted_source_amount)
    VALUES (gen_random_uuid(), v_account_id, v_conv_c, 'deposit_verification', 'remesa', 'GYD', 26000)
    RETURNING id INTO v_op_c_id;

    -- Destination stated BEFORE the beneficiary, on a conversation whose
    -- remesa is already open: this is the 157 function's own apply path.
    v_detected := cerebro_registrar_destino(v_conv_c, 'Tropical por favor');
    IF v_detected IS DISTINCT FROM 'tropical' THEN
      RAISE EXCEPTION 'FAIL [case 4a] registrar_destino returned %, expected tropical', v_detected;
    END IF;

    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account,
                                          position, status, source)
    VALUES (v_op_c_id, 'zelle', 'Beneficiario C', '10378363543358', 1, 'vigente', 'staging_test')
    RETURNING id INTO v_ben_id;

    SELECT beneficiary_type INTO v_tipo FROM remittance_beneficiaries WHERE id = v_ben_id;
    IF v_tipo IS DISTINCT FROM 'zelle' THEN
      RAISE EXCEPTION 'FAIL [case 4b] a zelle beneficiary was re-typed to %', v_tipo;
    END IF;

    -- And the calculator still takes the zelle branch: 26,000 GYD / 260
    -- = 100 USD. A converted beneficiary would have changed nothing here,
    -- but a re-ROUTED one would show a different figure.
    SELECT quoted_destination_amount, destination_currency INTO v_amount, v_currency
      FROM remittance_operations WHERE id = v_op_c_id;
    IF v_currency IS DISTINCT FROM 'USD' OR v_amount IS DISTINCT FROM 100 THEN
      RAISE EXCEPTION 'FAIL [case 4c] the zelle quote moved: amount=% currency=% (expected 100 USD)', v_amount, v_currency;
    END IF;

    RAISE NOTICE 'PASS [case 4] a zelle beneficiary is never re-typed and keeps its own 100 USD quote';
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] the zelle case raised: % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 5: closing the remesa clears the pending row ----------------
  IF v_op_b_id IS NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] skipped: case 3 did not produce the operation to close';
  ELSE
    BEGIN
      -- The accumulator 155 clears, so the verbatim copy is regression
      -- tested in the same breath as the line 157 added next to it.
      INSERT INTO cerebro_beneficiario_parcial (conversation_id, tarjeta, celular, actualizado)
        VALUES (v_conv_b, '9234567890123456', '5351234567', now());

      -- A human closing the remesa: 096's completion guard reverts an
      -- automation write of 'completed', so the JWT has to be a real agent.
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
      UPDATE remittance_operations SET status = 'completed' WHERE id = v_op_b_id;
      PERFORM set_config('request.jwt.claims', '', true);

      SELECT status INTO v_tipo FROM remittance_operations WHERE id = v_op_b_id;
      IF v_tipo IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'FAIL [case 5a] the operation did not close (status=%), so the cleanup trigger never ran', v_tipo;
      END IF;

      SELECT count(*) INTO v_count FROM cerebro_destino_pendiente WHERE conversation_id = v_conv_b;
      IF v_count <> 0 THEN
        RAISE EXCEPTION 'FAIL [case 5b] the pending destination survived the close of the remesa (% row(s) left)', v_count;
      END IF;

      SELECT count(*) INTO v_count FROM cerebro_beneficiario_parcial WHERE conversation_id = v_conv_b;
      IF v_count <> 0 THEN
        RAISE EXCEPTION 'FAIL [case 5c] 155''s own accumulator survived the close (% row(s) left) — the verbatim copy regressed', v_count;
      END IF;

      RAISE NOTICE 'PASS [case 5] closing the remesa deleted the pending destination (and 155''s accumulator)';
    EXCEPTION WHEN OTHERS THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 5] the close cleanup raised: % (%)', SQLERRM, SQLSTATE;
    END;
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'deterministic-usd-destination: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'deterministic-usd-destination: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT deterministic_usd_destination;
