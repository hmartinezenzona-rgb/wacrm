-- =====================================================================
-- deal-free-panel-verification.sql — self-reverting assertion for 165
--
-- Proves, against the live staging catalog:
--
--   0. the catalog exit criterion: the deals-referencing function set
--      shrinks by exactly one — crm_comprobantes_de_operacion — from nine
--      to eight. crm_verificar_deposito and crm_forzar_verificacion MUST
--      remain in it, because their notes writes were kept;
--   1. the live ACL of all three functions is untouched: PUBLIC and anon
--      revoked, authenticated keeps EXECUTE (the panel calls as
--      authenticated), service_role kept;
--   2. a genuinely deal-free operation (created by the 161 path,
--      cerebro_crear_operacion, so deal_id IS NULL) can be deposit-verified
--      and force-verified from the panel, end to end: the RPCs return JSON,
--      the operation status advances, a remittance_admin_audit row is
--      written, and no deals row is created;
--   3. crm_comprobantes_de_operacion stops hiding a deal-free operation's
--      depositado and consumed_deposits behind the old
--      IF v_deal_id IS NOT NULL guard;
--   4. a deal-LINKED operation keeps its behaviour: same saldo invariant,
--      same consumed deposits selected by deal_id and by operation_id, same
--      returned JSON, and — the field most likely to drift silently — the
--      same deals.notes text;
--   5. source: both RPCs still carry their UPDATE on deals, gated on a deal
--      existing. This is what keeps them in the deals-referencing set.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (the runner opens BEGIN; ... this file; ROLLBACK;). Never COMMIT.
-- Never run against production.
--
-- RED before 165: part 2's crm_verificar_deposito /
-- crm_forzar_verificacion calls raise `operation has no linked deal`
-- (SQLSTATE 22023), and part 3's deal-free read comes back can_verify =
-- false with an empty consumed_deposits. Parts 1/4/5 pass before 165.
--
-- NOT asserted here (measured by the before/after diff in the WU6b report
-- instead): the `UPDATE deals SET updated_at` ELSIF branch, which needs an
-- overpaid operation with an objective to reach.
-- =====================================================================

SAVEPOINT deal_free_panel_verification;

-- Does a body name the `deals` table in a position only a real reference
-- can occupy? Comment lines are stripped first: prosrc keeps the comments,
-- and a comment that merely mentions a deals write must not count as one.
CREATE FUNCTION pg_temp.wu6b_strip_comments(p_src text) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT regexp_replace(p_src, '--[^' || chr(10) || ']*', '', 'g');
$fn$;

CREATE FUNCTION pg_temp.wu6b_names_deals(p_src text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT pg_temp.wu6b_strip_comments(p_src)
         ~* '(from|join|update|into|table)[[:space:]]+(public\.)?deals[[:space:]]*([^_a-z0-9]|$)';
$fn$;

DO $$
DECLARE
  c_user   CONSTANT uuid := 'bbbbbbbb-1111-4111-8111-111111111111';
  c_acct   CONSTANT uuid := 'bbbbbbbb-2222-4222-8222-222222222222';
  c_cont   CONSTANT uuid := 'bbbbbbbb-3333-4333-8333-333333333331';
  c_conv   CONSTANT uuid := 'bbbbbbbb-4444-4444-8444-444444444441';
  c_deal1  CONSTANT uuid := 'bbbbbbbb-5555-4555-8555-555555555551';
  c_deal2  CONSTANT uuid := 'bbbbbbbb-5555-4555-8555-555555555552';
  c_pipe   CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  c_porver CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  c_notes  CONSTANT text := 'BENEFICIARIO (auto)' || chr(10) ||
                            'VERIFICADO: casa con el correo de MMG';

  v_opv uuid; v_opf uuid; v_opr uuid;   -- deal-free operations
  v_opl uuid; v_opl2 uuid;              -- deal-linked operations
  v_json jsonb;
  v_src  text;
  v_status text;
  v_n integer; v_n2 integer;
  v_deals_before bigint; v_deals_after bigint;
  v_set text[];
  v_one text;
  v_acl text;
  v_notes_after text;
  v_saldo_deal jsonb; v_saldo_op jsonb;
  v_fail integer := 0;
BEGIN
  ------------------------------------------------------------------
  -- Fixtures.
  ------------------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data,
    is_sso_user, is_anonymous)
  VALUES (c_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'wu6b-asrt@test.invalid','$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ',
    now(),now(),now(),'{}'::jsonb,'{}'::jsonb,false,false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (c_acct,'wu6b assertion account',c_user);
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), c_user, 'wu6b assertion', 'wu6b-asrt@test.invalid', c_acct, 'owner');
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (c_cont, c_user, '15550000666', 'wu6b assertion contact', c_acct);
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (c_conv, c_user, c_cont, c_acct);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', c_user, 'role', 'authenticated')::text, true);

  ------------------------------------------------------------------
  -- Part 0 — catalog exit criterion: the deals set shrinks by exactly one.
  ------------------------------------------------------------------
  SELECT coalesce(array_agg(p.proname ORDER BY p.proname), ARRAY[]::text[]) INTO v_set
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND pg_temp.wu6b_names_deals(p.prosrc);

  -- Non-empty guard before believing anything about the set.
  IF v_set IS NULL OR array_length(v_set, 1) IS NULL OR array_length(v_set, 1) = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0] the deals-referencing function set is EMPTY — the probe is broken, not the catalog';
  ELSIF v_set IS DISTINCT FROM ARRAY[
       'cerebro_aplicar_nombre_confirmado',
       'cerebro_avisar_envios_incompletos',
       'cerebro_avisar_envios_sin_beneficiario',
       'cerebro_sync_beneficiarios',
       'crm_forzar_verificacion',
       'crm_verificar_deposito',
       'notify_operation_incidencia',
       'sync_tags_cliente']::text[] THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0] the deals-referencing function set is % — expected the eight post-WU6b ones', v_set;
  ELSE
    RAISE NOTICE 'PASS [0] exactly eight functions reference deals (9 -> 8: crm_comprobantes_de_operacion left)';
  END IF;

  IF NOT ('crm_comprobantes_de_operacion' = ANY (v_set)) THEN
    RAISE NOTICE 'PASS [0.1] crm_comprobantes_de_operacion no longer names deals';
  ELSE
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0.1] crm_comprobantes_de_operacion still names deals';
  END IF;

  IF 'crm_verificar_deposito' = ANY (v_set) AND 'crm_forzar_verificacion' = ANY (v_set) THEN
    RAISE NOTICE 'PASS [0.2] crm_verificar_deposito and crm_forzar_verificacion REMAIN in the deals set (their notes writes were kept)';
  ELSE
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0.2] a deals write was deleted from %: the notes write had to stay', v_set;
  END IF;

  ------------------------------------------------------------------
  -- Part 1 — the live ACL of all three functions is untouched.
  ------------------------------------------------------------------
  FOR v_one, v_acl IN
    SELECT p.proname, p.proacl::text
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('crm_comprobantes_de_operacion','crm_verificar_deposito','crm_forzar_verificacion')
  LOOP
    IF v_acl IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}' THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [1] % ACL changed: %', v_one, v_acl;
    END IF;
    IF v_acl ~ '(^|[{,])=' THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [1] % ACL exposes PUBLIC: %', v_one, v_acl;
    END IF;
    IF v_acl ~ 'anon=' THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [1] % ACL exposes anon: %', v_one, v_acl;
    END IF;
  END LOOP;

  FOR v_one, v_n2 IN
    SELECT p.proname, p.oid::int
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('crm_comprobantes_de_operacion','crm_verificar_deposito','crm_forzar_verificacion')
  LOOP
    IF NOT has_function_privilege('authenticated', v_n2::oid, 'EXECUTE') THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [1] authenticated lost EXECUTE on %', v_one;
    END IF;
    IF has_function_privilege('anon', v_n2::oid, 'EXECUTE') THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [1] anon regained EXECUTE on %', v_one;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS [1] ACL preserved on all three functions: PUBLIC/anon revoked, authenticated + service_role kept';

  ------------------------------------------------------------------
  -- Part 2 — RED case, now GREEN: a deal-free operation verifies.
  ------------------------------------------------------------------
  SELECT count(*) INTO v_deals_before FROM deals;

  v_opv := cerebro_crear_operacion(c_conv, 1000, 'GYD', c_porver);
  v_opf := cerebro_crear_operacion(c_conv,  500, 'GYD', c_porver);
  v_opr := cerebro_crear_operacion(c_conv,  250, 'GYD', c_porver);

  SELECT count(*) INTO v_n FROM remittance_operations
   WHERE id IN (v_opv, v_opf, v_opr) AND deal_id IS NULL;
  IF v_n <> 3 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] the fixture operations are not deal-free (% of 3)', v_n;
  END IF;

  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en)
  VALUES ('888000111222', 1000, 'GYD', 'wu6b assertion', now() - interval '1 hour');

  -- The call that used to raise 22023 'operation has no linked deal'.
  v_json := crm_verificar_deposito(v_opv, '[{"ref":"888000111222","amount":1000}]'::jsonb);
  IF v_json ->> 'resultado' <> 'verificado'
     OR v_json ->> 'new_status' <> 'ready_to_transfer'
     OR (v_json ->> 'stage_changed')::boolean IS NOT TRUE THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] deal-free deposit verification returned %', v_json;
  ELSE
    RAISE NOTICE 'PASS [2] crm_verificar_deposito returned % on a deal-free operation', v_json ->> 'resultado';
  END IF;

  SELECT status INTO v_status FROM remittance_operations WHERE id = v_opv;
  IF v_status <> 'ready_to_transfer' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] deal-free operation status is % after verification', v_status;
  END IF;

  v_json := crm_forzar_verificacion(v_opf, 'motivo de prueba suficientemente largo');
  IF v_json ->> 'new_status' <> 'ready_to_transfer' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] deal-free force verification returned %', v_json;
  ELSE
    RAISE NOTICE 'PASS [2] crm_forzar_verificacion returned % on a deal-free operation', v_json ->> 'new_status';
  END IF;

  SELECT count(*) INTO v_n FROM remittance_admin_audit
   WHERE row_id = v_opv AND action = 'human_deposit_verification';
  SELECT count(*) INTO v_n2 FROM remittance_admin_audit
   WHERE row_id = v_opf AND action = 'human_forced_verification'
     AND reason = 'motivo de prueba suficientemente largo';
  IF v_n <> 1 OR v_n2 <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] audit rows missing: verify=% force=%', v_n, v_n2;
  ELSE
    RAISE NOTICE 'PASS [2] both deal-free calls wrote their remittance_admin_audit row';
  END IF;

  SELECT count(*) INTO v_deals_after FROM deals;
  IF v_deals_after <> v_deals_before THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] the deal-free verify paths created % deals row(s)', v_deals_after - v_deals_before;
  ELSE
    RAISE NOTICE 'PASS [2] no deals row was created by any deal-free verify path (% before, % after)',
      v_deals_before, v_deals_after;
  END IF;

  ------------------------------------------------------------------
  -- Part 3 — the panel reader no longer returns the old NULL shape.
  ------------------------------------------------------------------
  INSERT INTO remittance_operation_receipts
    (operation_id, conversation_id, comp_id, amount, currency, reference, source)
  VALUES (v_opr, c_conv, 'COMP-7001', 250, 'GYD', '888000333444', 'backfill');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, operation_id, consumido_en)
  VALUES ('888000333444', 250, 'GYD', 'wu6b assertion', now() - interval '3 hours',
          v_opr, now() - interval '1 hour');

  v_json := crm_comprobantes_de_operacion(v_opr);
  IF (v_json ->> 'can_verify')::boolean IS NOT TRUE THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] deal-free panel read still says can_verify=false: %', v_json;
  END IF;
  IF jsonb_array_length(v_json -> 'consumed_deposits') <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] deal-free panel read hid consumed deposits: %', v_json -> 'consumed_deposits';
  END IF;
  IF (v_json ->> 'depositado')::numeric IS DISTINCT FROM 250 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] deal-free panel read depositado is %', v_json ->> 'depositado';
  END IF;
  RAISE NOTICE 'PASS [3] deal-free panel read: can_verify true, 1 consumed deposit, depositado 250';

  ------------------------------------------------------------------
  -- Part 4 — deal-linked behaviour: the invariants the diff proves.
  ------------------------------------------------------------------
  INSERT INTO deals (id, user_id, account_id, contact_id, conversation_id,
                     pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (c_deal1, c_user, c_acct, c_cont, c_conv, c_pipe, c_porver,
          'wu6b assertion 1', 1000, 'GYD', c_notes, 'open');
  INSERT INTO deals (id, user_id, account_id, contact_id, conversation_id,
                     pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (c_deal2, c_user, c_acct, c_cont, c_conv, c_pipe, c_porver,
          'wu6b assertion 2', 500, 'GYD', c_notes, 'open');

  SELECT id INTO v_opl  FROM remittance_operations WHERE deal_id = c_deal1;
  SELECT id INTO v_opl2 FROM remittance_operations WHERE deal_id = c_deal2;
  IF v_opl IS NULL OR v_opl2 IS NULL THEN
    RAISE EXCEPTION 'FAIL [4] the 125 trigger did not create both deal-linked operations';
  END IF;

  INSERT INTO remittance_operation_receipts
    (operation_id, conversation_id, comp_id, amount, currency, reference, source)
  VALUES (v_opl, c_conv, 'COMP-7002', 1000, 'GYD', '888000555666', 'backfill');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, deal_id)
  VALUES ('888000555666', 1000, 'GYD', 'wu6b assertion', now() - interval '1 hour', c_deal1);

  -- 4.0 the deal-keyed deposit also carries the operation id: this is what
  -- makes repointing the reader from deal_id to operation_id safe.
  SELECT operation_id INTO v_one FROM depositos_mmg WHERE trans_id = '888000555666';
  IF v_one IS DISTINCT FROM v_opl::text THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4.0] the deal-keyed deposit did not get operation_id (got %)', v_one;
  ELSE
    RAISE NOTICE 'PASS [4.0] depositos_mmg deal-keyed row also carries operation_id (158 trigger)';
  END IF;

  -- 4.1 the deal-keyed and operation-keyed saldo rows agree.
  SELECT to_jsonb(s) INTO v_saldo_deal FROM cerebro_saldo_envio(c_deal1) s;
  SELECT to_jsonb(s) INTO v_saldo_op   FROM cerebro_saldo_operacion(v_opl) s;
  IF v_saldo_deal IS DISTINCT FROM v_saldo_op THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4.1] saldo row diverges: deal=% op=%', v_saldo_deal, v_saldo_op;
  ELSE
    RAISE NOTICE 'PASS [4.1] cerebro_saldo_envio(deal) = cerebro_saldo_operacion(op) = %', v_saldo_op;
  END IF;

  -- 4.2 the panel read for the deal-linked operation, before verification.
  v_json := crm_comprobantes_de_operacion(v_opl);
  IF (v_json ->> 'deal_id') <> c_deal1::text OR (v_json ->> 'can_verify')::boolean IS NOT TRUE THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4.2] deal-linked panel read changed shape: %', v_json;
  END IF;

  -- 4.3 deposit verification of a deal-linked operation: same result, same notes write.
  v_json := crm_verificar_deposito(v_opl, '[{"ref":"888000555666","amount":1000}]'::jsonb);
  IF v_json ->> 'resultado' <> 'verificado' OR v_json ->> 'new_status' <> 'ready_to_transfer' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4.3] deal-linked verification changed: %', v_json;
  END IF;
  SELECT coalesce(notes,'<null>') INTO v_notes_after FROM deals WHERE id = c_deal1;
  IF v_notes_after NOT LIKE '%VERIFICADO EN PANEL: casa con el correo de MMG%'
     OR v_notes_after NOT LIKE '%VERIFICADO EN PANEL por un operador del CRM%' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4.3] deals.notes was NOT rewritten for a deal-linked operation: %', v_notes_after;
  ELSE
    RAISE NOTICE 'PASS [4.3] deal-linked verification kept the deals.notes rewrite (notes now % chars)',
      length(v_notes_after);
  END IF;

  -- 4.4 the consumed-deposit set is the same read by deal_id and by operation_id.
  SELECT count(*) INTO v_n FROM depositos_mmg
   WHERE deal_id = c_deal1 AND consumido_en IS NOT NULL AND anulado_en IS NULL;
  SELECT count(*) INTO v_n2 FROM depositos_mmg
   WHERE operation_id = v_opl AND consumido_en IS NOT NULL AND anulado_en IS NULL;
  IF v_n <> v_n2 OR v_n = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4.4] consumed deposits by deal=% by operation=% (must be equal and non-zero)', v_n, v_n2;
  ELSE
    RAISE NOTICE 'PASS [4.4] % consumed deposit(s) selected identically by deal_id and by operation_id', v_n;
  END IF;

  -- 4.5 force verification of a deal-linked operation: same notes write.
  v_json := crm_forzar_verificacion(v_opl2, 'forzada en la asercion de paridad');
  IF v_json ->> 'new_status' <> 'ready_to_transfer' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4.5] deal-linked force verification changed: %', v_json;
  END IF;
  SELECT coalesce(notes,'<null>') INTO v_notes_after FROM deals WHERE id = c_deal2;
  IF v_notes_after NOT LIKE '%VERIFICACION FORZADA EN PANEL: forzada en la asercion de paridad%' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4.5] deals.notes was NOT rewritten by force verification: %', v_notes_after;
  ELSE
    RAISE NOTICE 'PASS [4.5] force verification kept the deals.notes rewrite for a deal-linked operation';
  END IF;

  ------------------------------------------------------------------
  -- Part 5 — source: the notes writes are still there for both RPCs.
  ------------------------------------------------------------------
  FOR v_one, v_src IN
    SELECT p.proname, pg_temp.wu6b_strip_comments(p.prosrc)
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('crm_verificar_deposito','crm_forzar_verificacion')
  LOOP
    IF v_src !~* 'update[[:space:]]+deals' THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [5] % no longer contains an UPDATE on deals — a write that had to stay was deleted', v_one;
    END IF;
    IF v_src !~* 'if[[:space:]]+v_deal_id[[:space:]]+is[[:space:]]+not[[:space:]]+null' THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [5] % no longer gates its deal work on a deal existing', v_one;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS [5] both RPCs still carry their UPDATE on deals, gated on a deal existing';

  ------------------------------------------------------------------
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'deal-free-panel-verification: % check(s) FAILED', v_fail;
  END IF;
  RAISE NOTICE 'deal-free-panel-verification: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT deal_free_panel_verification;
