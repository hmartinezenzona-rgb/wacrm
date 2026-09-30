-- operation-receipts.sql — self-reverting assertion for 156
-- (remittance_operation_receipts + cerebro_parsear_comprobantes).
--
-- Proves:
--   1. the parser turns a single-receipt note (with an ALERTAS line) into
--      exactly one fully-populated row;
--   2. the parser turns a two-receipt note into exactly two rows with the
--      right comp_ids/amounts, and IGNORES the trailing
--      'TOTAL DEPOSITADO:' block ('DEPOSITADO:' does not contain 'DEPOSITO:');
--   3. cerebro_registrar_deposito's 'creado' branch dual-writes exactly one
--      receipt (comp_id, 40000, GYD, source 'bot') onto the new operation;
--   4. re-sending the same comp_id is idempotent: still one receipt row;
--   5. a SECOND receipt with a different comp_id that lands on the 'sumado'
--      branch adds a row to the SAME operation, never a second operation.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker psql against the staging URL, wrapped in BEGIN ... ROLLBACK).
-- Never COMMIT. Never run against production. Builds its own fixtures,
-- same posture as registrar-deposito-creado.sql.
--
-- Case 5 fixture: case 3's deal only qualifies for the 'sumado' branch when
-- it has an open remittance target — cerebro_saldo_envio(d).saldo is the
-- objetivo (cerebro_objetivo_envio) minus consumed MMG deposits, and the
-- fixture consumes none. Without that row the deal has no saldo and the
-- second receipt would open a brand new deal instead.
--
-- RED:   against staging WITHOUT 156 the run dies at case 1 — the parser
--        does not exist. Case 1 raises on failure on purpose (no nested
--        handler), so RED stops there instead of reporting five failures.
-- GREEN: after 156 is applied — all cases PASS.

SAVEPOINT operation_receipts;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_pipeline_owner uuid;
  v_contact_id     uuid;
  v_conv_id        uuid;

  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_incidencia     CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';

  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_fail_count     integer := 0;
  v_result         record;
  v_rows           integer;
  v_receipts       integer;
  v_deal_id        uuid;
  v_op_id          uuid;
  v_comp1          CONSTANT text := '0123456789abcdef0123';
  v_comp2          CONSTANT text := 'fedcba9876543210fedc';
  v_nota1          text;
  v_nota2          text;
  v_nota_multi     text;
BEGIN
  -- ---- fixtures ---------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'receipts-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'receipts test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'receipts owner', 'receipts-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;

  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 20) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia,    v_pipeline_id, 'Incidencia',    91) ON CONFLICT (id) DO NOTHING;

  -- Loopback no-op notify config so a committed notify can never reach a
  -- real endpoint. Safe to overwrite: this transaction always rolls back.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/receipts-noop')
    ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'receipts-noop')
    ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000333', 'Receipts Cliente', v_account_id) RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;

  -- ---- case 1: the parser, one receipt, every field -------------------
  -- Fails hard (no nested handler): this is where RED must die.
  BEGIN
    v_nota1 := E'DEPOSITO: 40,000 GYD - APROBADA\n'
           || E'Destinatario: ABC Remesas\n'
           || E'Via: Transferencia Bancaria;\n'
           || E'Ref: N/A (2026-09-29)\n'
           || E'Destino correcto: SI\n'
           || E'ALERTAS: La imagen se ve borrosa, el monto se leyo a mano.\n'
           || E'COMP-' || v_comp1;

    SELECT count(*) INTO v_rows FROM public.cerebro_parsear_comprobantes(v_nota1);
    IF v_rows <> 1 THEN
      RAISE EXCEPTION 'FAIL [case 1] expected 1 parsed receipt, got %', v_rows;
    END IF;

    SELECT * INTO v_result FROM public.cerebro_parsear_comprobantes(v_nota1);

    IF v_result.block_index <> 1
       OR v_result.comp_id IS DISTINCT FROM 'COMP-' || v_comp1
       OR v_result.amount IS DISTINCT FROM 40000::numeric
       OR v_result.currency IS DISTINCT FROM 'GYD'
       OR v_result.receipt_status IS DISTINCT FROM 'APROBADA'
       OR v_result.recipient IS DISTINCT FROM 'ABC Remesas'
       OR v_result.via IS DISTINCT FROM 'Transferencia Bancaria'
       OR v_result.reference IS DISTINCT FROM 'N/A'
       OR v_result.receipt_date IS DISTINCT FROM '2026-09-29'
       OR v_result.correct_destination IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL [case 1] parsed row wrong: idx=% comp=% amount=% cur=% status=% to=% via=% ref=% date=% dest=%',
        v_result.block_index, v_result.comp_id, v_result.amount, v_result.currency,
        v_result.receipt_status, v_result.recipient, v_result.via, v_result.reference,
        v_result.receipt_date, v_result.correct_destination;
    END IF;

    RAISE NOTICE 'PASS [case 1] parser returns one fully-parsed receipt row';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'operation-receipts: %', SQLERRM;
  END;

  -- ---- case 2: the parser, two receipts in one note --------------------
  BEGIN
    v_nota_multi :=
        E'DEPOSITO: 20,000 GYD - APROBADA\n'
     || E'Destinatario: Ana\n'
     || E'Via: Zelle;\n'
     || E'Ref: 10378363543358 (2026-09-28)\n'
     || E'Destino correcto: SI\n'
     || E'COMP-aaaaaaaaaaaaaaaaaaaa\n'
     || E'---\n'
     || E'DEPOSITO: 25,000.50 GYD - VERIFICADA\n'
     || E'Destinatario: Beto\n'
     || E'Via: MMG;\n'
     || E'Ref: N/A\n'
     || E'Destino correcto: NO\n'
     || E'COMP-bbbbbbbbbbbbbbbbbbbb\n'
     || E'---\n'
     || E'TOTAL DEPOSITADO: 45,000.50 GYD';

    SELECT count(*) INTO v_rows FROM public.cerebro_parsear_comprobantes(v_nota_multi);
    IF v_rows <> 2 THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 2] expected 2 parsed receipts (the TOTAL DEPOSITADO block is not one), got %', v_rows;
    ELSE
      PERFORM 1 FROM public.cerebro_parsear_comprobantes(v_nota_multi)
       WHERE block_index = 1
         AND comp_id = 'COMP-aaaaaaaaaaaaaaaaaaaa'
         AND amount = 20000::numeric
         AND currency = 'GYD'
         AND receipt_status = 'APROBADA'
         AND recipient = 'Ana'
         AND via = 'Zelle'
         AND reference = '10378363543358'
         AND receipt_date = '2026-09-28'
         AND correct_destination;
      IF NOT FOUND THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [case 2] the first receipt of the multi note is wrong';
      END IF;

      PERFORM 1 FROM public.cerebro_parsear_comprobantes(v_nota_multi)
       WHERE block_index = 2
         AND comp_id = 'COMP-bbbbbbbbbbbbbbbbbbbb'
         AND amount = 25000.50::numeric
         AND currency = 'GYD'
         AND receipt_status = 'VERIFICADA'
         AND recipient = 'Beto'
         AND via = 'MMG'
         AND reference = 'N/A'
         AND receipt_date IS NULL
         AND correct_destination IS FALSE;
      IF NOT FOUND THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [case 2] the second receipt of the multi note is wrong';
      END IF;

      RAISE NOTICE 'PASS [case 2] parser returns 2 receipt rows from the multi note';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] multi-receipt parse raised: % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 3: the 'creado' branch dual-writes one receipt -------------
  BEGIN
    v_nota1 := E'DEPOSITO: 40,000 GYD - APROBADA\n'
           || E'Destinatario: ABC Remesas\n'
           || E'Via: Transferencia Bancaria;\n'
           || E'Ref: 10378363543358 (2026-09-29)\n'
           || E'Destino correcto: SI\n'
           || E'COMP-' || v_comp1;

    SELECT * INTO v_result
      FROM cerebro_registrar_deposito(v_conv_id, 40000, 'GYD', v_por_verificar, v_nota1, v_comp1);

    IF v_result.accion IS DISTINCT FROM 'creado' OR v_result.deal_id IS NULL THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 3] expected accion=creado with a deal id, got accion=% deal=%', v_result.accion, v_result.deal_id;
    ELSE
      v_deal_id := v_result.deal_id;

      SELECT o.id INTO v_op_id
        FROM remittance_operations o
       WHERE o.deal_id = v_deal_id;

      IF v_op_id IS NULL THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [case 3] the created deal % has no operation to hang the receipt on', v_deal_id;
      ELSE
        SELECT count(*) INTO v_receipts
          FROM remittance_operation_receipts
         WHERE operation_id = v_op_id;

        IF v_receipts <> 1 THEN
          v_fail_count := v_fail_count + 1;
          RAISE WARNING 'FAIL [case 3] expected exactly 1 receipt row on operation %, got %', v_op_id, v_receipts;
        ELSE
          PERFORM 1 FROM remittance_operation_receipts
           WHERE operation_id = v_op_id
             AND comp_id = 'COMP-' || v_comp1
             AND amount = 40000::numeric
             AND currency = 'GYD'
             AND receipt_status = 'APROBADA'
             AND reference = '10378363543358'
             AND source = 'bot';
          IF NOT FOUND THEN
            v_fail_count := v_fail_count + 1;
            RAISE WARNING 'FAIL [case 3] the single receipt row has the wrong comp_id/amount/currency/reference/source';
          ELSE
            RAISE NOTICE 'PASS [case 3] creado dual-wrote exactly 1 bot receipt on operation %', v_op_id;
          END IF;
        END IF;
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] cerebro_registrar_deposito (creado) raised: % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- cases 4 and 5 need case 3's deal and operation -------------------
  IF v_deal_id IS NULL OR v_op_id IS NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [cases 4-5] skipped: case 3 did not produce a deal + operation';
  END IF;

  -- ---- case 4: the same comp_id again is idempotent --------------------
  IF v_deal_id IS NOT NULL AND v_op_id IS NOT NULL THEN
    BEGIN
      SELECT * INTO v_result
        FROM cerebro_registrar_deposito(v_conv_id, 40000, 'GYD', v_por_verificar, v_nota1, v_comp1);

      IF v_result.accion IS DISTINCT FROM 'ya registrado (idempotente)' THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [case 4] expected the idempotent accion, got %', v_result.accion;
      END IF;

      SELECT count(*) INTO v_receipts
        FROM remittance_operation_receipts
       WHERE operation_id = v_op_id;

      IF v_receipts <> 1 THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [case 4] re-sending the same comp_id left % receipt rows, expected 1', v_receipts;
      ELSE
        RAISE NOTICE 'PASS [case 4] the same comp_id twice is still 1 receipt row';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 4] idempotent re-send raised: % (%)', SQLERRM, SQLSTATE;
    END;
  END IF;

  -- ---- case 5: a second receipt adds a row to the SAME operation -------
  IF v_deal_id IS NOT NULL AND v_op_id IS NOT NULL THEN
    BEGIN
      -- An open remittance target on the conversation is what makes
      -- cerebro_saldo_envio(deal).saldo > 0, i.e. what makes the deal
      -- eligible for the 'sumado' branch instead of opening a new deal.
      INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, deal_id)
      VALUES (v_conv_id, 80000, 'GYD', v_deal_id);

      v_nota2 := E'DEPOSITO: 15,000 GYD - APROBADA\n'
             || E'Destinatario: XYZ Comisiones\n'
             || E'Via: Transferencia Bancaria;\n'
             || E'Ref: 10378363543359 (2026-09-29)\n'
             || E'Destino correcto: SI\n'
             || E'COMP-' || v_comp2;

      SELECT * INTO v_result
        FROM cerebro_registrar_deposito(v_conv_id, 15000, 'GYD', v_por_verificar, v_nota2, v_comp2);

      IF v_result.accion IS DISTINCT FROM 'sumado al envio abierto'
         OR v_result.deal_id IS DISTINCT FROM v_deal_id THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [case 5] expected the second receipt to be sumado onto deal %, got accion=% deal=%',
          v_deal_id, v_result.accion, v_result.deal_id;
      ELSE
        SELECT count(*) INTO v_receipts
          FROM remittance_operation_receipts
         WHERE operation_id = v_op_id;

        IF v_receipts <> 2 THEN
          v_fail_count := v_fail_count + 1;
          RAISE WARNING 'FAIL [case 5] expected 2 receipts on the SAME operation %, got %', v_op_id, v_receipts;
        ELSE
          SELECT count(*) INTO v_receipts
            FROM remittance_operation_receipts
           WHERE operation_id = v_op_id
             AND comp_id IN ('COMP-' || v_comp1, 'COMP-' || v_comp2)
             AND source = 'bot';

          IF v_receipts <> 2 THEN
            v_fail_count := v_fail_count + 1;
            RAISE WARNING 'FAIL [case 5] the two receipts are not both on operation %', v_op_id;
          ELSE
            RAISE NOTICE 'PASS [case 5] the second receipt added a row to the SAME operation %', v_op_id;
          END IF;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 5] the summed-branch second receipt raised: % (%)', SQLERRM, SQLSTATE;
    END;
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'operation-receipts: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'operation-receipts: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT operation_receipts;