-- operation-incident-reason.sql — self-reverting assertion for 167
--
-- Proves:
--   0. the catalog exit criterion: the positional deals-referencing
--      function set is exactly 5 and notify_operation_incidencia is gone
--      from it (the non-empty guard runs first);
--   1. cerebro_registrar_deposito's REFERENCIA IMPOSIBLE branch persists
--      the reason and the notification MOTIVO carries it;
--   2. an incident with a NULL incident_reason renders the honest
--      fallback 'Un envío necesita revisión manual.' — driven through the
--      real BEFORE guard (automated completed insert coerced to incident);
--   3. cerebro_cruzar_deposito's SIN VERIFICAR / ALERTA CASE persists;
--   4. cerebro_cruzar_depositos' v_fallo persists;
--   5. same-statement proof: the notification body is built from the row
--      version that already carries the reason (the AFTER trigger fires
--      on UPDATE OF status), so a non-NULL MOTIVO is only reachable when
--      status + reason were written in one SET;
--   6. the invariant: a redefined writer moving a row OUT of incident
--      clears the reason to NULL;
--   7. the frozen contract: signature, argument names, return type and
--      ACL of the four touched functions are unchanged.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK:
--   BEGIN; \i operation-incident-reason.sql ROLLBACK;
-- (or the whole file wrapped in BEGIN ... ROLLBACK). Never COMMIT. Never
-- run against production. Builds its own fixtures.

SAVEPOINT operation_incident_reason;

CREATE FUNCTION pg_temp.wu6e_strip_comments(p_src text) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT regexp_replace(p_src, '--[^' || chr(10) || ']*', '', 'g');
$fn$;

CREATE FUNCTION pg_temp.wu6e_names_deals(p_src text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT pg_temp.wu6e_strip_comments(p_src)
         ~* '(from|join|update|into|table)[[:space:]]+(public\.)?deals[[:space:]]*([^_a-z0-9]|$)';
$fn$;

DO $$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_hash    CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_porver  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista   CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_incid   CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipe    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_acct    uuid;
  v_cont    uuid; v_conv uuid; v_deal uuid; v_op uuid; v_body text; v_reason text; v_status text;
  v_bodies  text; v_n integer;
  v_res     record;
  v_set     text[];
  v_fail    integer := 0;
  v_ref     text;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'wu6e-' || v_user || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'wu6e assertion', v_user) RETURNING id INTO v_acct;
  UPDATE profiles SET account_id = v_acct, account_role = 'owner' WHERE user_id = v_user;
  IF NOT FOUND THEN
    INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
    VALUES (gen_random_uuid(), v_user, 'wu6e', 'wu6e-' || v_user || '@test.invalid', v_acct, 'owner');
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  ------------------------------------------------------------------
  -- 0 — catalog exit criterion
  ------------------------------------------------------------------
  SELECT coalesce(array_agg(p.proname ORDER BY p.proname), ARRAY[]::text[]) INTO v_set
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND pg_temp.wu6e_names_deals(p.prosrc);

  IF array_length(v_set, 1) IS NULL OR array_length(v_set, 1) = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0] the deals set is EMPTY — the probe is broken, not the catalog';
  ELSIF v_set IS DISTINCT FROM ARRAY[
       'cerebro_aplicar_nombre_confirmado','cerebro_sync_beneficiarios',
       'crm_forzar_verificacion','crm_verificar_deposito']::text[] THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0] positional deals set is % — expected the four post-168', v_set;
  ELSE
    RAISE NOTICE 'PASS [0] exactly four functions reference deals in a real position (6 -> 4)';
  END IF;

  IF NOT ('notify_operation_incidencia' = ANY (v_set)) THEN
    RAISE NOTICE 'PASS [0.1] notify_operation_incidencia no longer names deals';
  ELSE
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0.1] notify_operation_incidencia still names deals';
  END IF;

  ------------------------------------------------------------------
  -- 1 — cerebro_registrar_deposito: REFERENCIA IMPOSIBLE persists
  ------------------------------------------------------------------
  BEGIN
    INSERT INTO contacts (id, user_id, phone, name, account_id)
      VALUES (gen_random_uuid(), v_user, '15550009001', 'wu6e A', v_acct) RETURNING id INTO v_cont;
    INSERT INTO conversations (id, user_id, contact_id, account_id)
      VALUES (gen_random_uuid(), v_user, v_cont, v_acct) RETURNING id INTO v_conv;
    INSERT INTO deals (id, user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
      VALUES (gen_random_uuid(), v_user, v_acct, v_cont, v_conv, v_pipe, v_porver, 'wu6e A', 1000, 'GYD',
              'BENEFICIARIO (auto)' || chr(10) || 'VERIFICADO EN PANEL por un operador del CRM', 'open')
      RETURNING id INTO v_deal;
    SELECT id INTO v_op FROM remittance_operations WHERE deal_id = v_deal;

    SELECT * INTO v_res FROM cerebro_registrar_deposito(v_conv, 40000, 'GYD', v_porver,
      'DEPOSITO: 40,000 GYD' || chr(10) || 'Via: Agente MMG' || chr(10) || 'Ref: 1', '');

    SELECT status, incident_reason INTO v_status, v_reason FROM remittance_operations WHERE id = v_op;
    SELECT body INTO v_body FROM notifications WHERE account_id = v_acct AND type = 'deal_incidencia' AND contact_id = v_cont LIMIT 1;

    IF v_status = 'incident' AND v_reason LIKE 'REFERENCIA IMPOSIBLE:%' THEN
      RAISE NOTICE 'PASS [1] registrar_deposito persisted the REFERENCIA IMPOSIBLE reason';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [1] status=% reason=% (accion=%)', v_status, v_reason, v_res.accion;
    END IF;

    IF v_body LIKE '%MOTIVO:%REFERENCIA IMPOSIBLE:%' AND v_body NOT LIKE '%Un envío necesita revisión manual.%' THEN
      RAISE NOTICE 'PASS [1.1] notification MOTIVO carries the persisted reason, not the deal notes';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [1.1] body=%', replace(v_body, chr(10), ' | ');
    END IF;

    IF v_body NOT LIKE '%VERIFICADO EN PANEL por un operador del CRM%' THEN
      RAISE NOTICE 'PASS [1.2] the stale deals.notes line is gone from the MOTIVO';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [1.2] the stale deals.notes line is still shown';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [1] % (%)', SQLERRM, SQLSTATE;
  END;

  ------------------------------------------------------------------
  -- 2 — NULL reason renders the honest fallback (BEFORE guard coerces)
  ------------------------------------------------------------------
  BEGIN
    INSERT INTO contacts (id, user_id, phone, name, account_id)
      VALUES (gen_random_uuid(), v_user, '15550009002', 'wu6e B', v_acct) RETURNING id INTO v_cont;
    INSERT INTO conversations (id, user_id, contact_id, account_id)
      VALUES (gen_random_uuid(), v_user, v_cont, v_acct) RETURNING id INTO v_conv;

    -- Non-member actor: the completion guard coerces completed -> incident.
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);

    INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id,
                                       status, service_type, quoted_source_amount, source_currency)
      VALUES (gen_random_uuid(), v_acct, v_conv, v_cont, NULL, 'completed', 'remesa', 0, 'GYD')
      RETURNING id INTO v_op;

    SELECT status, incident_reason INTO v_status, v_reason FROM remittance_operations WHERE id = v_op;
    SELECT body INTO v_body FROM notifications WHERE account_id = v_acct AND type = 'deal_incidencia' AND contact_id = v_cont LIMIT 1;

    IF v_status = 'incident' AND v_reason IS NULL AND v_body LIKE '%MOTIVO:%Un envío necesita revisión manual.%' THEN
      RAISE NOTICE 'PASS [2] guard-coerced incident has NULL reason and the fallback renders';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [2] status=% reason=% body=%', v_status, v_reason, replace(v_body, chr(10), ' | ');
    END IF;

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [2] % (%)', SQLERRM, SQLSTATE;
  END;

  ------------------------------------------------------------------
  -- 3 — cerebro_cruzar_deposito: ALERTA (monto no coincide) persists
  ------------------------------------------------------------------
  BEGIN
    INSERT INTO contacts (id, user_id, phone, name, account_id)
      VALUES (gen_random_uuid(), v_user, '15550009003', 'wu6e C', v_acct) RETURNING id INTO v_cont;
    INSERT INTO conversations (id, user_id, contact_id, account_id)
      VALUES (gen_random_uuid(), v_user, v_cont, v_acct) RETURNING id INTO v_conv;

    v_ref := (30000000000000 + (random() * 100000000)::bigint)::text;
    INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en)
      VALUES (v_ref, 999, 'GYD', 'wu6e', now());

    INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id,
                                       status, service_type, quoted_source_amount, source_currency)
      VALUES (gen_random_uuid(), v_acct, v_conv, v_cont, NULL, 'deposit_verification', 'remesa', 1000, 'GYD')
      RETURNING id INTO v_op;

    SELECT * INTO v_res FROM cerebro_cruzar_deposito(v_op, v_ref, 1000, v_lista, v_incid, v_porver, false);

    SELECT status, incident_reason INTO v_status, v_reason FROM remittance_operations WHERE id = v_op;
    SELECT body INTO v_body FROM notifications WHERE account_id = v_acct AND type = 'deal_incidencia' AND contact_id = v_cont LIMIT 1;

    IF v_res.resultado = 'monto_no_coincide' AND v_status = 'incident'
       AND v_reason = 'ALERTA: el TransID ' || v_ref || ' existe en MMG pero el monto no coincide'
       AND v_body LIKE '%MOTIVO:%ALERTA: el TransID ' || v_ref || ' existe en MMG pero el monto no coincide' THEN
      RAISE NOTICE 'PASS [3] cruzar_deposito persisted the ALERTA reason; MOTIVO matches';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [3] resultado=% status=% reason=% body=%', v_res.resultado, v_status, v_reason, replace(v_body, chr(10), ' | ');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [3] % (%)', SQLERRM, SQLSTATE;
  END;

  ------------------------------------------------------------------
  -- 4 — cerebro_cruzar_depositos: v_fallo persists on a broken burst
  ------------------------------------------------------------------
  BEGIN
    INSERT INTO contacts (id, user_id, phone, name, account_id)
      VALUES (gen_random_uuid(), v_user, '15550009004', 'wu6e D', v_acct) RETURNING id INTO v_cont;
    INSERT INTO conversations (id, user_id, contact_id, account_id)
      VALUES (gen_random_uuid(), v_user, v_cont, v_acct) RETURNING id INTO v_conv;

    INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id,
                                       status, service_type, quoted_source_amount, source_currency)
      VALUES (gen_random_uuid(), v_acct, v_conv, v_cont, NULL, 'deposit_verification', 'remesa', 1000, 'GYD')
      RETURNING id INTO v_op;

    SELECT * INTO v_res FROM cerebro_cruzar_depositos(v_op, ARRAY['111','222'], ARRAY[1000::numeric],
      v_lista, v_incid, v_porver, false);

    SELECT status, incident_reason INTO v_status, v_reason FROM remittance_operations WHERE id = v_op;
    SELECT body INTO v_body FROM notifications WHERE account_id = v_acct AND type = 'deal_incidencia' AND contact_id = v_cont LIMIT 1;

    IF v_status = 'incident'
       AND v_reason = 'las referencias y los importes no vienen emparejados'
       AND v_body LIKE '%MOTIVO:%las referencias y los importes no vienen emparejados' THEN
      RAISE NOTICE 'PASS [4] cruzar_depositos persisted v_fallo; MOTIVO matches';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [4] status=% reason=% body=%', v_status, v_reason, replace(v_body, chr(10), ' | ');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [4] % (%)', SQLERRM, SQLSTATE;
  END;

  ------------------------------------------------------------------
  -- 5 — §5A same-statement proof, as a three-step negative control
  ------------------------------------------------------------------
  BEGIN
    -- trg_notify_operation_incidencia is AFTER UPDATE OF status: it fires
    -- when the statement NAMES status in its SET list, and it reads NEW.
    -- So (a) status alone must yield the fallback, (b) a reason written by
    -- a LATER statement must produce no notification at all — the stale
    -- fallback stands, and nothing raises — and (c) status and reason in
    -- ONE SET must yield the reason. That is exactly why every write added
    -- by 167 shares the SET.
    INSERT INTO contacts (id, user_id, phone, name, account_id)
      VALUES (gen_random_uuid(), v_user, '15550009006', 'wu6e F', v_acct) RETURNING id INTO v_cont;
    INSERT INTO conversations (id, user_id, contact_id, account_id)
      VALUES (gen_random_uuid(), v_user, v_cont, v_acct) RETURNING id INTO v_conv;
    INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id,
                                       status, service_type, quoted_source_amount, source_currency)
      VALUES (gen_random_uuid(), v_acct, v_conv, v_cont, NULL, 'deposit_verification', 'remesa', 0, 'GYD')
      RETURNING id INTO v_op;

    -- (a) status named, no reason
    UPDATE remittance_operations SET status = 'incident' WHERE id = v_op;
    SELECT count(*), coalesce(string_agg(body, ' || '), '') INTO v_n, v_bodies
      FROM notifications WHERE account_id = v_acct AND contact_id = v_cont;
    IF v_n = 1 AND v_bodies LIKE '%MOTIVO:%Un envío necesita revisión manual.%' THEN
      RAISE NOTICE 'PASS [5a] a bare status change produced one notification and the fallback';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [5a] count=% bodies=%', v_n, replace(v_bodies, chr(10), ' | ');
    END IF;

    -- (b) the reason arrives in a LATER statement: no trigger, no update
    UPDATE remittance_operations SET incident_reason = 'LATE REASON' WHERE id = v_op;
    SELECT count(*), coalesce(string_agg(body, ' || '), '') INTO v_n, v_bodies
      FROM notifications WHERE account_id = v_acct AND contact_id = v_cont;
    IF v_n = 1 AND v_bodies NOT LIKE '%LATE REASON%'
       AND v_bodies LIKE '%MOTIVO:%Un envío necesita revisión manual.%' THEN
      RAISE NOTICE 'PASS [5b] a later-statement reason raised nothing and the stale fallback stands';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [5b] count=% bodies=%', v_n, replace(v_bodies, chr(10), ' | ');
    END IF;

    -- (c) status and reason in ONE SET, re-entering incident. (The 114 guard
    --     `OLD.status IS NOT DISTINCT FROM 'incident'` deliberately keeps an
    --     already-incident row from re-notifying, so leave incident first —
    --     that is also the real shape of every re-entry.)
    UPDATE remittance_operations SET status = 'deposit_verification' WHERE id = v_op;
    UPDATE remittance_operations
       SET status = 'incident', incident_reason = 'SAME STATEMENT' WHERE id = v_op;
    SELECT count(*), coalesce(string_agg(body, ' || '), '') INTO v_n, v_bodies
      FROM notifications WHERE account_id = v_acct AND contact_id = v_cont;
    IF v_n = 2 AND v_bodies LIKE '%MOTIVO:%SAME STATEMENT%' THEN
      RAISE NOTICE 'PASS [5c] status+reason in one SET reached the notification body';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [5c] count=% bodies=%', v_n, replace(v_bodies, chr(10), ' | ');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [5] % (%)', SQLERRM, SQLSTATE;
  END;

  ------------------------------------------------------------------
  -- 6 — invariant: moving OUT of incident clears the reason
  ------------------------------------------------------------------
  BEGIN
    INSERT INTO contacts (id, user_id, phone, name, account_id)
      VALUES (gen_random_uuid(), v_user, '15550009005', 'wu6e E', v_acct) RETURNING id INTO v_cont;
    INSERT INTO conversations (id, user_id, contact_id, account_id)
      VALUES (gen_random_uuid(), v_user, v_cont, v_acct) RETURNING id INTO v_conv;

    INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id,
                                       status, service_type, quoted_source_amount, source_currency,
                                       incident_reason)
      VALUES (gen_random_uuid(), v_acct, v_conv, v_cont, NULL, 'incident', 'remesa', 0, 'GYD', 'STALE')
      RETURNING id INTO v_op;

    -- A normal (plausible) deposit moves it to deposit_verification.
    PERFORM cerebro_registrar_deposito(v_conv, 40000, 'GYD', v_porver,
      'DEPOSITO: 40,000 GYD' || chr(10) || 'Via: Agente MMG' || chr(10) || 'Ref: 99999999999999999', '');

    SELECT status, incident_reason INTO v_status, v_reason FROM remittance_operations WHERE id = v_op;
    IF v_status = 'deposit_verification' AND v_reason IS NULL THEN
      RAISE NOTICE 'PASS [6] leaving incident cleared the stale reason to NULL';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [6] status=% reason=%', v_status, v_reason;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [6] % (%)', SQLERRM, SQLSTATE;
  END;

  ------------------------------------------------------------------
  -- 7 — frozen contract
  ------------------------------------------------------------------
  BEGIN
    IF (SELECT pg_get_function_identity_arguments(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public' AND p.proname='cerebro_registrar_deposito')
       = 'p_conv uuid, p_monto numeric, p_moneda text, p_stage uuid, p_nota text, p_comp_id text'
       AND (SELECT pg_get_function_result(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='public' AND p.proname='cerebro_registrar_deposito')
       = 'TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)'
       AND (SELECT pg_get_function_identity_arguments(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='public' AND p.proname='cerebro_cruzar_deposito')
       = 'p_deal uuid, p_ref text, p_monto numeric, p_stage_ok uuid, p_stage_incidencia uuid, p_stage_esperado uuid, p_simular boolean'
       AND (SELECT pg_get_function_identity_arguments(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='public' AND p.proname='cerebro_cruzar_depositos')
       = 'p_deal uuid, p_refs text[], p_montos numeric[], p_stage_ok uuid, p_stage_incidencia uuid, p_stage_esperado uuid, p_simular boolean'
       AND (SELECT pg_get_function_result(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='public' AND p.proname='notify_operation_incidencia') = 'trigger' THEN
      RAISE NOTICE 'PASS [7] signatures, argument names and return types are unchanged';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [7] a frozen signature changed';
    END IF;

    IF (SELECT p.proacl::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public' AND p.proname='cerebro_registrar_deposito')
       = '{postgres=X/postgres,service_role=X/postgres}'
       AND (SELECT p.proacl::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='public' AND p.proname='notify_operation_incidencia')
       = '{=X/postgres,postgres=X/postgres,service_role=X/postgres}'
       AND (SELECT p.proacl::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='public' AND p.proname='remittance_operations_completion_guard')
       = '{=X/postgres,postgres=X/postgres,service_role=X/postgres}' THEN
      RAISE NOTICE 'PASS [7.1] ACLs unchanged (PUBLIC EXECUTE kept on the two trigger functions)';
    ELSE
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [7.1] an ACL changed';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [7] % (%)', SQLERRM, SQLSTATE;
  END;

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'operation-incident-reason: % expectation(s) FAILED', v_fail;
  END IF;
  RAISE NOTICE 'operation-incident-reason: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT operation_incident_reason;
