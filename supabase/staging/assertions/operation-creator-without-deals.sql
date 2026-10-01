-- =====================================================================
-- operation-creator-without-deals.sql — self-reverting assertion for 161
--
-- Proves cerebro_crear_operacion(...) creates a remittance_operations row
-- directly, with NO deals row, field-by-field equivalent to what
-- `INSERT INTO deals` + trg_sync_operacion_al_crear_deal (125) produces.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (the runner opens BEGIN; ... this file; ROLLBACK;). Never COMMIT.
-- Never run against production. RED before the migration: the function
-- does not exist and case 1 raises `function ... does not exist`.
--
-- Cases:
--   1. creates the row with deal_id NULL, no deals row, defaults right.
--   2. STRICT parity: minimal deal (no notes) vs the creator, same
--      conversation, diffed field by field.
--   3. REALISTIC parity: the exact INSERT `Registrar beneficiario auto`
--      does (notes, stage Solicitada, value 0, GYD) vs the creator.
--   4. orphan refusal: unknown conversation and NULL conversation raise,
--      and write nothing.
--   5. the creator's row is visible to cerebro_resolver_operacion.
-- =====================================================================

SAVEPOINT operation_creator_without_deals;

DO $$
DECLARE
  c_pipeline    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  c_solicitada  CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';
  v_owner       uuid := gen_random_uuid();
  v_account     uuid;
  v_contact     uuid;
  v_contact1    uuid;
  v_c1          uuid;
  v_c2          uuid;
  v_c3          uuid;
  v_op1         uuid;
  v_op2         uuid;
  v_deal_old    uuid;
  v_op_old      remittance_operations%ROWTYPE;
  v_op_new      remittance_operations%ROWTYPE;
  v_deals_before bigint;
  v_deals_after  bigint;
  v_ops_before   bigint;
  v_ops_after    bigint;
  v_n            integer;
  v_ghost        uuid := gen_random_uuid();
  v_raised       boolean;
  v_sqlstate     text;
  v_dummy        uuid;
  v_unexpected   text := '';
  v_seen_id      boolean := false;
  v_seen_deal    boolean := false;
  v_delta        numeric;
  v_ben_old      integer;
  v_ben_new      integer;
  v_diffcount    integer;
  r              record;
  v_hash        CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
BEGIN
  -- ---------------------------------------------------------------- fixtures
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ocwd-' || v_owner || '@test.invalid', v_hash, now(), now(), now(),
          '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id)
  VALUES (gen_random_uuid(), 'operation creator without deals test', v_owner)
  RETURNING id INTO v_account;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner, 'ocwd owner',
          'ocwd-' || v_owner || '@test.invalid', v_account, 'owner');

  -- conversations has a UNIQUE (account_id, contact_id): one contact per
  -- conversation (ux_conversations_account_contact).
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner, '15550000999', 'Operation Creator WOD', v_account)
  RETURNING id INTO v_contact;
  v_contact1 := v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner, v_contact, v_account) RETURNING id INTO v_c1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner, '15550000998', 'Operation Creator WOD 2', v_account)
  RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner, v_contact, v_account) RETURNING id INTO v_c2;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner, '15550000997', 'Operation Creator WOD 3', v_account)
  RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner, v_contact, v_account) RETURNING id INTO v_c3;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- ---------------------------------------------- case 1: creator, defaults
  SELECT count(*) INTO v_deals_before FROM deals;
  v_op1 := cerebro_crear_operacion(v_c1);
  SELECT count(*) INTO v_deals_after FROM deals;

  IF v_op1 IS NULL THEN
    RAISE EXCEPTION 'FAIL [1] creator returned NULL';
  END IF;
  IF v_deals_after <> v_deals_before THEN
    RAISE EXCEPTION 'FAIL [1] creator created % deals row(s)', v_deals_after - v_deals_before;
  END IF;
  SELECT * INTO v_op_new FROM remittance_operations WHERE id = v_op1;
  IF v_op_new.deal_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1] deal_id is not NULL: %', v_op_new.deal_id;
  END IF;
  IF v_op_new.conversation_id <> v_c1 OR v_op_new.account_id <> v_account
     OR v_op_new.contact_id <> v_contact1 THEN
    RAISE EXCEPTION 'FAIL [1] wrong ids: conv=% acc=% con=%',
      v_op_new.conversation_id, v_op_new.account_id, v_op_new.contact_id;
  END IF;
  IF v_op_new.status <> 'collecting_information' THEN
    RAISE EXCEPTION 'FAIL [1] expected collecting_information, got %', v_op_new.status;
  END IF;
  IF v_op_new.service_type <> 'remesa' THEN
    RAISE EXCEPTION 'FAIL [1] expected service_type remesa, got %', v_op_new.service_type;
  END IF;
  IF v_op_new.source_currency <> 'GYD' THEN
    RAISE EXCEPTION 'FAIL [1] expected source_currency GYD, got %', v_op_new.source_currency;
  END IF;
  IF v_op_new.quoted_source_amount IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [1] expected quoted_source_amount 0, got %', v_op_new.quoted_source_amount;
  END IF;
  IF v_op_new.completed_at IS NOT NULL OR v_op_new.cancelled_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1] completed_at/cancelled_at should be NULL';
  END IF;
  RAISE NOTICE 'PASS [1] creator builds the row with deal_id NULL and no deals row';

  -- ------------------------- case 2: STRICT parity, minimal deal (no notes)
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                     stage_id, title, value, currency, notes, status)
  SELECT v.user_id, v.account_id, v.contact_id, v.id, c_pipeline, c_solicitada,
         'Remesa +ocwd', 0, 'GYD', NULL, 'open'
    FROM conversations v WHERE v.id = v_c2
  RETURNING id INTO v_deal_old;

  SELECT count(*) INTO v_n FROM remittance_operations WHERE deal_id = v_deal_old;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'FAIL [2] old deal path should have made 1 operation, got %', v_n;
  END IF;
  SELECT * INTO v_op_old FROM remittance_operations WHERE deal_id = v_deal_old;
  -- The creator call is its own statement on purpose. Called inside the
  -- WHERE clause of the SELECT below, the row it inserts is invisible to
  -- that same statement's snapshot (the function runs during the scan,
  -- and the new tuple is newer than the snapshot), so the SELECT would
  -- silently return zero rows and read back an all-NULL record.
  v_op2 := cerebro_crear_operacion(v_c2);
  SELECT * INTO v_op_new FROM remittance_operations WHERE id = v_op2;
  IF v_op_new.id IS NULL THEN
    RAISE EXCEPTION 'FAIL [2] creator returned % but no row was found for it', v_op2;
  END IF;

  v_diffcount := 0;
  v_unexpected := '';
  v_seen_id := false;
  v_seen_deal := false;
  FOR r IN
    SELECT o.key AS k, o.value AS old_v, n.value AS new_v
      FROM jsonb_each(to_jsonb(v_op_old)) o
      JOIN jsonb_each(to_jsonb(v_op_new)) n ON n.key = o.key
     WHERE o.value IS DISTINCT FROM n.value
     ORDER BY o.key
  LOOP
    v_diffcount := v_diffcount + 1;
    RAISE NOTICE 'DIFF[2] %: old=% new=%', r.k, r.old_v, r.new_v;
    IF r.k = 'id' THEN v_seen_id := true; END IF;
    IF r.k = 'deal_id' THEN v_seen_deal := true; END IF;
    -- The only fields allowed to differ are the ones that CANNOT be
    -- equal by construction: id (independent gen_random_uuid), deal_id
    -- (NULL by design — it is the point of the unit), and created_at /
    -- updated_at, which are each row's own now(). now() is the
    -- transaction start time, so those two may legitimately come out
    -- equal; the exact count is therefore not asserted, only the set.
    IF r.k NOT IN ('id', 'deal_id', 'created_at', 'updated_at') THEN
      v_unexpected := v_unexpected || r.k || ' ';
    END IF;
  END LOOP;
  IF v_unexpected <> '' THEN
    RAISE EXCEPTION 'FAIL [2] unexpected field divergence: %', v_unexpected;
  END IF;
  IF NOT v_seen_id OR NOT v_seen_deal THEN
    RAISE EXCEPTION 'FAIL [2] id and deal_id must differ but did not (id=%, deal=%)',
      v_seen_id, v_seen_deal;
  END IF;
  -- Both rows take now(), which is the transaction start time, so they are
  -- normally equal; this only catches a creator that used clock_timestamp().
  v_delta := abs(extract(epoch FROM (v_op_new.created_at - v_op_old.created_at)));
  IF v_delta > 60 THEN
    RAISE EXCEPTION 'FAIL [2] created_at delta too large: % seconds', v_delta;
  END IF;
  RAISE NOTICE 'PASS [2] strict parity: % field(s) differ, all inside id/deal_id/created_at/updated_at (created_at delta % s)',
    v_diffcount, v_delta;

  -- ---- case 3: REALISTIC parity, exactly what `Registrar beneficiario auto` inserts
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                     stage_id, title, value, currency, notes, status)
  SELECT v.user_id, v.account_id, v.contact_id, v.id, c_pipeline, c_solicitada,
         'Remesa +ocwd', 0, 'GYD',
         'BENEFICIARIO (auto)' || E'\nTarjeta: 9224069996859118' || E'\nCelular: 56430816',
         'open'
    FROM conversations v WHERE v.id = v_c3
  RETURNING id INTO v_deal_old;

  SELECT * INTO v_op_old FROM remittance_operations WHERE deal_id = v_deal_old;
  v_op2 := cerebro_crear_operacion(v_c3);   -- own statement: see case 2
  SELECT * INTO v_op_new FROM remittance_operations WHERE id = v_op2;
  IF v_op_new.id IS NULL THEN
    RAISE EXCEPTION 'FAIL [3] creator returned % but no row was found for it', v_op2;
  END IF;

  -- The strong claim first, by name: every column the 125 trigger writes
  -- itself must be equal. This is what WU4a is responsible for, and it is
  -- asserted before any exemption is applied, so a regression in one of
  -- these columns can never hide behind the beneficiary-cascade set below.
  IF v_op_new.account_id          IS DISTINCT FROM v_op_old.account_id
  OR v_op_new.conversation_id     IS DISTINCT FROM v_op_old.conversation_id
  OR v_op_new.contact_id          IS DISTINCT FROM v_op_old.contact_id
  OR v_op_new.status              IS DISTINCT FROM v_op_old.status
  OR v_op_new.service_type        IS DISTINCT FROM v_op_old.service_type
  OR v_op_new.quoted_source_amount IS DISTINCT FROM v_op_old.quoted_source_amount
  OR v_op_new.source_currency     IS DISTINCT FROM v_op_old.source_currency
  OR v_op_new.source_country      IS DISTINCT FROM v_op_old.source_country
  OR v_op_new.completed_at        IS DISTINCT FROM v_op_old.completed_at
  OR v_op_new.cancelled_at        IS DISTINCT FROM v_op_old.cancelled_at THEN
    RAISE EXCEPTION 'FAIL [3] a column the 125 trigger writes diverged from the creator row';
  END IF;
  IF v_op_new.deal_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [3] creator row has a deal_id: %', v_op_new.deal_id;
  END IF;

  v_diffcount := 0;
  v_unexpected := '';
  FOR r IN
    SELECT o.key AS k, o.value AS old_v, n.value AS new_v
      FROM jsonb_each(to_jsonb(v_op_old)) o
      JOIN jsonb_each(to_jsonb(v_op_new)) n ON n.key = o.key
     WHERE o.value IS DISTINCT FROM n.value
     ORDER BY o.key
  LOOP
    v_diffcount := v_diffcount + 1;
    RAISE NOTICE 'DIFF[3] %: old=% new=%', r.k, r.old_v, r.new_v;
    -- delivery_method / version / admin_locked_fields are NOT written by
    -- the 125 trigger. They are written by a SECOND, deal-keyed trigger
    -- that fires on the same deal INSERT: trg_sync_z_benef_desde_deal ->
    -- cerebro_sync_benef_trigger (042/151), which parses the notes into
    -- remittance_beneficiaries and then does
    --   UPDATE remittance_operations SET delivery_method = ... WHERE deal_id = NEW.id
    -- That UPDATE is what bumps version (cerebro_op_touch) and what the
    -- lock guard records in admin_locked_fields. It cannot run for a
    -- deal-free operation: it is keyed on deal_id, which is NULL here by
    -- design, and beneficiary writing is WU4b/WU4c scope. These three
    -- columns are therefore the honest, measured size of that gap — see
    -- the NOTICE below. Any OTHER column diverging still fails.
    IF r.k NOT IN ('id', 'deal_id', 'created_at', 'updated_at',
                   'delivery_method', 'version', 'admin_locked_fields') THEN
      v_unexpected := v_unexpected || r.k || ' ';
    END IF;
  END LOOP;
  IF v_unexpected <> '' THEN
    RAISE EXCEPTION 'FAIL [3] unexpected field divergence: %', v_unexpected;
  END IF;

  -- Known, documented structural gap: the deal path also parses the notes
  -- into remittance_beneficiaries; the WU4a creator does not (WU4b/WU4c own
  -- beneficiary writing). Record it, do NOT hide it.
  SELECT count(*) INTO v_ben_old FROM remittance_beneficiaries WHERE operation_id = v_op_old.id;
  SELECT count(*) INTO v_ben_new FROM remittance_beneficiaries WHERE operation_id = v_op_new.id;
  RAISE NOTICE 'PASS [3] trigger-written columns all equal; % field(s) differ in total', v_diffcount;
  RAISE NOTICE 'KNOWN GAP [3] beneficiaries: old path=%, creator=% (WU4b/WU4c scope)', v_ben_old, v_ben_new;
  RAISE NOTICE 'KNOWN GAP [3] cascade columns old->new: delivery_method % -> %, version % -> %, admin_locked_fields % -> %',
    v_op_old.delivery_method, v_op_new.delivery_method,
    v_op_old.version, v_op_new.version,
    v_op_old.admin_locked_fields, v_op_new.admin_locked_fields;

  -- ---------------------------------------- case 4: orphan refusal, no row
  SELECT count(*) INTO v_ops_before FROM remittance_operations;

  v_raised := false; v_sqlstate := NULL;
  BEGIN
    v_dummy := cerebro_crear_operacion(v_ghost);
  EXCEPTION WHEN OTHERS THEN
    v_raised := true; v_sqlstate := SQLSTATE;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'FAIL [4] unknown conversation did NOT raise (wrote orphan %)', v_dummy;
  END IF;
  IF v_sqlstate <> '23503' THEN
    RAISE EXCEPTION 'FAIL [4] expected SQLSTATE 23503, got %', v_sqlstate;
  END IF;

  v_raised := false; v_sqlstate := NULL;
  BEGIN
    v_dummy := cerebro_crear_operacion(NULL::uuid);
  EXCEPTION WHEN OTHERS THEN
    v_raised := true; v_sqlstate := SQLSTATE;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'FAIL [4] NULL conversation did NOT raise';
  END IF;

  SELECT count(*) INTO v_ops_after FROM remittance_operations;
  IF v_ops_after <> v_ops_before THEN
    RAISE EXCEPTION 'FAIL [4] orphan refusal wrote % row(s)', v_ops_after - v_ops_before;
  END IF;
  RAISE NOTICE 'PASS [4] unknown/NULL conversation raises and writes nothing';

  -- ------------------------------- case 5: discoverable from the conversation
  -- The resolver RPC is deliberately NOT called. On staging a one-argument
  -- call is ambiguous: the live-only cerebro_resolver_operacion(uuid, text[])
  -- (drift documented at 097:38-53) has p_estados DEFAULT NULL, so both
  -- candidates match and PostgreSQL refuses with 42725. The two-argument
  -- form is absent from the working tree and from all reachable git
  -- history, so depending on it would make this assertion unreproducible.
  -- A repo-rebuildable check instead: the row the creator wrote is the only
  -- deal-free, non-terminal operation for that conversation.
  SELECT count(*) INTO v_n
    FROM remittance_operations o
   WHERE o.conversation_id = v_c1
     AND o.deal_id IS NULL
     AND o.status NOT IN ('completed', 'cancelled');
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'FAIL [5] expected 1 deal-free non-terminal operation for the conversation, got %', v_n;
  END IF;
  SELECT count(*) INTO v_n
    FROM remittance_operations o
   WHERE o.id = v_op1 AND o.conversation_id = v_c1 AND o.deal_id IS NULL;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'FAIL [5] the id the creator returned is not that row';
  END IF;
  RAISE NOTICE 'PASS [5] creator row is discoverable by conversation alone (deal-free, non-terminal)';

  RAISE NOTICE 'operation-creator-without-deals: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT operation_creator_without_deals;
