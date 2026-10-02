\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written (operation-receipts.sql once left staging's notify_url on a no-op this way).
-- =====================================================================
-- rekey-shipment-alerts-onto-operations.sql — self-reverting assertion
-- for migration 166.
--
-- *** THIS FILE MUST BE RUN INSIDE A TRANSACTION. ***
-- It creates fixtures (contacts, conversations, deals, operations,
-- objectives, consumed deposits, cerebro_alertas rows). Run it as:
--
--     BEGIN;
--     \i supabase/staging/assertions/rekey-shipment-alerts-onto-operations.sql
--     ROLLBACK;
--
-- Running it unwrapped makes SAVEPOINT fail in autocommit and COMMITS
-- the fixtures into staging — that happened during WU6b's parent check
-- and had to be cleaned up by hand. Do not do it again.
--
-- What it proves:
--   [1] catalog exit criterion: the positional deals-referencing set is
--       non-empty and neither avisar function is left in it;
--   [2] live row-set equivalence: the old deal-keyed predicate and the
--       new operation-keyed predicate select the same rows, with the
--       hours window forced and a non-empty control alongside;
--   [3] clave continuity: the deal-linked key is byte-identical to the
--       old deal-keyed key;
--   [4] both functions still run and write, and a repeat call updates
--       (ON CONFLICT) instead of duplicating;
--   [5] a deal-free operation created by the 161 path is covered by the
--       new predicate and invisible to the old one;
--   [6] the two operator-visible text changes of §5 are in place, with
--       the bot warning and the amount formatting preserved;
--   [7] signature, defaults, return shape and ACL are untouched.
-- =====================================================================

SAVEPOINT rekey_shipment_alerts;

-- Comments in prosrc must not count as table reads, and \m/\M (never \b,
-- which is not a word boundary in PostgreSQL ARE) must bound the words.
CREATE FUNCTION pg_temp.wu6c_strip_comments(p_src text) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT regexp_replace(p_src, '--[^' || chr(10) || ']*', '', 'g');
$fn$;

-- The brief's positional definition: `deals` used as a real relation.
CREATE FUNCTION pg_temp.wu6c_positional_deals(p_src text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT pg_temp.wu6c_strip_comments(p_src)
         ~* '\m(from|join|into|update)\M[[:space:]]+(public\.)?deals\M';
$fn$;

-- Any mention of the bare word at all — the wider definition the brief
-- reports alongside (11 vs 8); the exit criterion is the positional one.
CREATE FUNCTION pg_temp.wu6c_mentions_deals(p_src text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT pg_temp.wu6c_strip_comments(p_src) ~* '\mdeals\M';
$fn$;

DO $$
DECLARE
  c_pipe   CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  c_porver CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  c_encurso CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';

  c_ct_a   CONSTANT uuid := 'eeeeeeee-1111-4111-8111-1111111111a1';
  c_cv_a   CONSTANT uuid := 'eeeeeeee-2222-4222-8222-2222222222a2';
  c_dl_a   CONSTANT uuid := 'eeeeeeee-3333-4333-8333-3333333333a3';
  c_ct_b   CONSTANT uuid := 'eeeeeeee-1111-4111-8111-1111111111b1';
  c_cv_b   CONSTANT uuid := 'eeeeeeee-2222-4222-8222-2222222222b2';
  c_dl_b   CONSTANT uuid := 'eeeeeeee-3333-4333-8333-3333333333b3';
  c_ct_c   CONSTANT uuid := 'eeeeeeee-1111-4111-8111-1111111111c1';
  c_cv_c   CONSTANT uuid := 'eeeeeeee-2222-4222-8222-2222222222c2';

  v_user uuid; v_acc uuid;
  v_fail int := 0;
  v_n int; v_n2 int; v_pos int; v_men int;
  v_src text; v_one text;
  v_op_a uuid; v_op_b uuid; v_op_c uuid;
  v_clave_old text; v_clave_new text; v_clave_written text;
  v_ultimo_1 timestamptz; v_ultimo_2 timestamptz; v_rows int;
  v_before int; v_res record; v_body text; v_title text;
  v_guard boolean;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM profiles p JOIN auth.users au ON au.id = p.user_id LIMIT 1;
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'rekey: no profile with an auth user on this database; cannot build fixtures';
  END IF;

  -- ==================================================================
  -- [1] catalog exit criterion
  -- ==================================================================
  SELECT count(*) INTO v_pos
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f'
     AND pg_temp.wu6c_positional_deals(p.prosrc);
  SELECT count(*) INTO v_men
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f'
     AND pg_temp.wu6c_mentions_deals(p.prosrc);
  RAISE NOTICE 'definition: positional = `deals` used as a relation; mentions = the bare word anywhere. positional=%, mentions=%', v_pos, v_men;

  -- Non-empty control: a set of zero would make the absence checks vacuous.
  IF v_pos = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1] the positional deals-referencing set is empty — the check would be vacuous';
  END IF;

  FOR v_one, v_src IN
    SELECT p.proname, p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND p.proname IN ('cerebro_avisar_envios_incompletos','cerebro_avisar_envios_sin_beneficiario')
  LOOP
    IF pg_temp.wu6c_positional_deals(v_src) THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [1] % still reads deals as a relation', v_one;
    END IF;
    IF regexp_replace(v_src, '--[^' || chr(10) || ']*', '', 'g')
         ~* '\m(pipelines|pipeline_stages)\M' THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [1] % still names pipelines/pipeline_stages', v_one;
    END IF;
  END LOOP;
  IF v_fail = 0 THEN
    RAISE NOTICE 'PASS [1] neither avisar function reads deals/pipelines/pipeline_stages (positional set %, non-empty)', v_pos;
  END IF;

  -- ==================================================================
  -- [2] live row-set equivalence, hours window forced open
  -- ==================================================================
  UPDATE cerebro_config SET valor = '00:00'
   WHERE clave IN ('envio_incompleto_desde','sin_beneficiario_desde');
  UPDATE cerebro_config SET valor = '23:59'
   WHERE clave IN ('envio_incompleto_hasta','sin_beneficiario_hasta');

  -- The Sunday branch of the guard is hardcoded and cannot be forced from
  -- config; a zero there would be the guard, not an empty row set.
  v_guard := (EXTRACT(DOW FROM now() AT TIME ZONE 'America/Guyana') = 0);
  IF v_guard THEN
    RAISE EXCEPTION 'rekey: the business-hours guard is closed today (Sunday in America/Guyana); an invocation test would return 0,0 without evaluating rows. Re-run on a weekday.';
  END IF;

  -- incompletos: old deal-keyed candidate
  SELECT count(*) INTO v_n FROM deals d
    JOIN conversations v ON v.id = d.conversation_id
    JOIN contacts      c ON c.id = v.contact_id
    LEFT JOIN cerebro_objetivo_envio o ON o.conversation_id = d.conversation_id
    CROSS JOIN LATERAL cerebro_saldo_envio(d.id) s
   WHERE d.pipeline_id = c_pipe AND d.status = 'open' AND d.stage_id = c_porver
     AND s.saldo > 0
     AND COALESCE((SELECT max(m.consumido_en) FROM depositos_mmg m
                    WHERE m.deal_id = d.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL),
                  d.created_at) < now() - make_interval(hours => 4)
     AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                      WHERE a.clave = 'envio_incompleto:' || d.id::text
                        AND a.ultimo > now() - make_interval(mins => 120));
  -- incompletos: new operation-keyed candidate
  SELECT count(*) INTO v_n2 FROM remittance_operations op
    JOIN conversations v ON v.id = op.conversation_id
    JOIN contacts      c ON c.id = v.contact_id
    LEFT JOIN cerebro_objetivo_envio o ON o.conversation_id = op.conversation_id
    CROSS JOIN LATERAL cerebro_saldo_operacion(op.id) s
   WHERE COALESCE(op.service_type,'remesa') <> 'recarga'
     AND op.status = 'deposit_verification'
     AND s.saldo > 0
     AND COALESCE((SELECT max(m.consumido_en) FROM depositos_mmg m
                    WHERE m.operation_id = op.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL),
                  op.created_at) < now() - make_interval(hours => 4)
     AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                      WHERE a.clave = 'envio_incompleto:' || coalesce(op.deal_id, op.id)::text
                        AND a.ultimo > now() - make_interval(mins => 120));
  RAISE NOTICE 'incompletos row set: old(deal-keyed)=%  new(operation-keyed)=%', v_n, v_n2;
  IF v_n <> v_n2 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] incompletos row sets differ: old=% new=%', v_n, v_n2;
  END IF;
  -- Non-empty control: the guard is open and the query evaluated rows.
  IF v_n = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] incompletos control is empty on live data; the zero would be uninterpretable';
  END IF;

  -- sin_beneficiario: old deal-keyed candidate
  SELECT count(*) INTO v_n FROM deals d
    JOIN pipeline_stages s ON s.id = d.stage_id
    JOIN conversations v ON v.id = d.conversation_id
    JOIN contacts      c ON c.id = v.contact_id
    JOIN remittance_operations o ON o.deal_id = d.id
    CROSS JOIN LATERAL (SELECT max(m.consumido_en) AS dinero_dentro FROM depositos_mmg m
                         WHERE m.deal_id = d.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) dep
   WHERE d.pipeline_id = c_pipe AND d.status = 'open'
     AND d.stage_id IN (c_porver, c_encurso)
     AND COALESCE(o.service_type,'remesa') <> 'recarga'
     AND dep.dinero_dentro IS NOT NULL
     AND dep.dinero_dentro < now() - make_interval(mins => 30)
     AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente')
     AND COALESCE(d.notes,'') NOT LIKE '%BENEFICIARIO%'
     AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = d.conversation_id
                       AND m.sender_type='agent' AND NOT COALESCE(m.ai_generated,false)
                       AND m.created_at > now() - make_interval(mins => 20))
     AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                      WHERE a.clave = 'sin_beneficiario:' || d.id::text
                        AND a.ultimo > now() - make_interval(mins => 120));
  -- sin_beneficiario: new operation-keyed candidate
  SELECT count(*) INTO v_n2 FROM remittance_operations op
    JOIN conversations v ON v.id = op.conversation_id
    JOIN contacts      c ON c.id = v.contact_id
    CROSS JOIN LATERAL (SELECT max(m.consumido_en) AS dinero_dentro FROM depositos_mmg m
                         WHERE m.operation_id = op.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) dep
   WHERE COALESCE(op.service_type,'remesa') <> 'recarga'
     AND op.status IN ('deposit_verification','ready_to_transfer')
     AND dep.dinero_dentro IS NOT NULL
     AND dep.dinero_dentro < now() - make_interval(mins => 30)
     AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = op.id AND b.status = 'vigente')
     AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = op.conversation_id
                       AND m.sender_type='agent' AND NOT COALESCE(m.ai_generated,false)
                       AND m.created_at > now() - make_interval(mins => 20))
     AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                      WHERE a.clave = 'sin_beneficiario:' || coalesce(op.deal_id, op.id)::text
                        AND a.ultimo > now() - make_interval(mins => 120));
  RAISE NOTICE 'sin_beneficiario row set: old(deal-keyed)=%  new(operation-keyed)=%', v_n, v_n2;
  IF v_n <> v_n2 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] sin_beneficiario row sets differ: old=% new=%', v_n, v_n2;
  END IF;
  -- Non-empty control for the zero: the machinery behind this predicate
  -- does evaluate rows, so a zero is an answer and not a guard.
  SELECT count(*) INTO v_n2 FROM remittance_operations op
   WHERE COALESCE(op.service_type,'remesa') <> 'recarga'
     AND op.status IN ('deposit_verification','ready_to_transfer');
  RAISE NOTICE 'sin_beneficiario non-empty control (same scope, deposit/beneficiary checks off): % operations', v_n2;
  IF v_n2 = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] sin_beneficiario control is empty; the zero cannot be distinguished from the guard';
  END IF;

  -- ==================================================================
  -- [3] signature, defaults, return shape, ACL untouched
  -- ==================================================================
  IF (SELECT pg_get_function_arguments(oid) FROM pg_proc
       WHERE proname='cerebro_avisar_envios_incompletos')
     <> 'p_horas integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] incompletos signature/defaults changed: %',
      (SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE proname='cerebro_avisar_envios_incompletos');
  END IF;
  IF (SELECT pg_get_function_arguments(oid) FROM pg_proc
       WHERE proname='cerebro_avisar_envios_sin_beneficiario')
     <> 'p_minutos integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] sin_beneficiario signature/defaults changed: %',
      (SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE proname='cerebro_avisar_envios_sin_beneficiario');
  END IF;
  IF (SELECT pg_get_function_result(oid) FROM pg_proc
       WHERE proname='cerebro_avisar_envios_sin_beneficiario')
     <> 'TABLE(sin_destino integer, avisos_creados integer)' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] sin_beneficiario return shape changed';
  END IF;

  FOR v_one, v_src IN
    SELECT p.proname, COALESCE(p.proacl::text,'') FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='public'
       AND p.proname IN ('cerebro_avisar_envios_incompletos','cerebro_avisar_envios_sin_beneficiario')
  LOOP
    -- Measured live before 166: {postgres=X/postgres,service_role=X/postgres}.
    -- 166 is CREATE OR REPLACE and adds no GRANT/REVOKE, so this must be
    -- byte-identical after it. A PUBLIC grant would show as `=X/`.
    IF v_src <> '{postgres=X/postgres,service_role=X/postgres}' THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [3] % ACL changed: expected {postgres=X/postgres,service_role=X/postgres}, got %', v_one, v_src;
    END IF;
  END LOOP;
  IF has_function_privilege('authenticated','public.cerebro_avisar_envios_incompletos(integer,integer)','EXECUTE')
     OR has_function_privilege('anon','public.cerebro_avisar_envios_incompletos(integer,integer)','EXECUTE') THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] incompletos is now executable by authenticated/anon';
  END IF;
  IF NOT has_function_privilege('service_role','public.cerebro_avisar_envios_incompletos(integer,integer)','EXECUTE')
     OR NOT has_function_privilege('service_role','public.cerebro_avisar_envios_sin_beneficiario(integer,integer)','EXECUTE') THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] service_role lost EXECUTE (n8n calls these)';
  END IF;
  IF v_fail = 0 THEN
    RAISE NOTICE 'PASS [3] signature, defaults, return shape and ACL are untouched';
  END IF;
  v_before := v_fail;

  -- ==================================================================
  -- fixtures
  -- ==================================================================
  -- A: deal-linked, INCOMPLETOS (underpaid at Por verificar, older than 4 h)
  INSERT INTO contacts (id, user_id, account_id, phone, name)
  VALUES (c_ct_a, v_user, v_acc, '59900166001', 'WU6C A');
  INSERT INTO conversations (id, user_id, account_id, contact_id)
  VALUES (c_cv_a, v_user, v_acc, c_ct_a);
  INSERT INTO deals (id, user_id, account_id, contact_id, conversation_id, pipeline_id,
                     stage_id, title, value, currency, status, notes, created_at)
  VALUES (c_dl_a, v_user, v_acc, c_ct_a, c_cv_a, c_pipe, c_porver,
          'wu6c-a', 10000, 'GYD', 'open', '', now() - interval '6 hours');
  SELECT id INTO v_op_a FROM remittance_operations WHERE deal_id = c_dl_a;
  UPDATE remittance_operations SET created_at = now() - interval '6 hours' WHERE id = v_op_a;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, pedido)
  VALUES (c_cv_a, 25000, 'GYD', NULL);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, deal_id, operation_id, consumido_en)
  VALUES ('wu6c-a', 10000, 'GYD', 'wu6c-a', now() - interval '6 hours', c_dl_a, v_op_a, now() - interval '6 hours');

  -- B: deal-linked at En curso, SIN beneficiario (renders the alert text)
  INSERT INTO contacts (id, user_id, account_id, phone, name)
  VALUES (c_ct_b, v_user, v_acc, '59900166002', 'WU6C B');
  INSERT INTO conversations (id, user_id, account_id, contact_id)
  VALUES (c_cv_b, v_user, v_acc, c_ct_b);
  INSERT INTO deals (id, user_id, account_id, contact_id, conversation_id, pipeline_id,
                     stage_id, title, value, currency, status, notes, created_at)
  VALUES (c_dl_b, v_user, v_acc, c_ct_b, c_cv_b, c_pipe, c_encurso,
          'wu6c-b', 32500, 'GYD', 'open', '', now() - interval '3 hours');
  SELECT id INTO v_op_b FROM remittance_operations WHERE deal_id = c_dl_b;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, deal_id, operation_id, consumido_en)
  VALUES ('wu6c-b', 32500, 'GYD', 'wu6c-b', now() - interval '2 hours', c_dl_b, v_op_b, now() - interval '2 hours');

  -- C: DEAL-FREE operation by the 161 path
  INSERT INTO contacts (id, user_id, account_id, phone, name)
  VALUES (c_ct_c, v_user, v_acc, '59900166003', 'WU6C C');
  INSERT INTO conversations (id, user_id, account_id, contact_id)
  VALUES (c_cv_c, v_user, v_acc, c_ct_c);
  v_op_c := cerebro_crear_operacion(c_cv_c);
  UPDATE remittance_operations
     SET status = 'deposit_verification', service_type = 'remesa',
         quoted_source_amount = 10000, source_currency = 'GYD',
         created_at = now() - interval '6 hours'
   WHERE id = v_op_c;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, pedido)
  VALUES (c_cv_c, 25000, 'GYD', NULL);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, operation_id, consumido_en)
  VALUES ('wu6c-c', 10000, 'GYD', 'wu6c-c', now() - interval '6 hours', v_op_c, now() - interval '6 hours');

  IF v_op_a IS NULL OR v_op_b IS NULL OR v_op_c IS NULL THEN
    RAISE EXCEPTION 'rekey: fixture operations not created (a=%, b=%, c=%)', v_op_a, v_op_b, v_op_c;
  END IF;
  IF (SELECT deal_id FROM remittance_operations WHERE id = v_op_c) IS NOT NULL THEN
    RAISE EXCEPTION 'rekey: fixture C is not deal-free';
  END IF;

  -- ==================================================================
  -- [5] deal-free coverage — the only row the two predicates disagree on
  --     after the fixtures is the deal-free one, and it is exactly one.
  -- ==================================================================
  IF (SELECT deal_id FROM remittance_operations WHERE id = v_op_c) IS NOT NULL THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5] the "deal-free" fixture has a deal_id';
  END IF;

  -- incompletos, both predicates, fixtures present, no alerts written yet
  SELECT count(*) INTO v_n FROM deals d
    JOIN conversations v ON v.id = d.conversation_id
    JOIN contacts      c ON c.id = v.contact_id
    LEFT JOIN cerebro_objetivo_envio o ON o.conversation_id = d.conversation_id
    CROSS JOIN LATERAL cerebro_saldo_envio(d.id) s
   WHERE d.pipeline_id = c_pipe AND d.status = 'open' AND d.stage_id = c_porver
     AND s.saldo > 0
     AND COALESCE((SELECT max(m.consumido_en) FROM depositos_mmg m
                    WHERE m.deal_id = d.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL),
                  d.created_at) < now() - make_interval(hours => 4)
     AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                      WHERE a.clave = 'envio_incompleto:' || d.id::text
                        AND a.ultimo > now() - make_interval(mins => 120));
  SELECT count(*) INTO v_n2 FROM remittance_operations op
    JOIN conversations v ON v.id = op.conversation_id
    JOIN contacts      c ON c.id = v.contact_id
    LEFT JOIN cerebro_objetivo_envio o ON o.conversation_id = op.conversation_id
    CROSS JOIN LATERAL cerebro_saldo_operacion(op.id) s
   WHERE COALESCE(op.service_type,'remesa') <> 'recarga'
     AND op.status = 'deposit_verification'
     AND s.saldo > 0
     AND COALESCE((SELECT max(m.consumido_en) FROM depositos_mmg m
                    WHERE m.operation_id = op.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL),
                  op.created_at) < now() - make_interval(hours => 4)
     AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                      WHERE a.clave = 'envio_incompleto:' || coalesce(op.deal_id, op.id)::text
                        AND a.ultimo > now() - make_interval(mins => 120));
  RAISE NOTICE 'incompletos with fixtures: old=%, new=% (expect new = old + 1, the deal-free one)', v_n, v_n2;
  IF v_n2 <> v_n + 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5] incompletos: the deal-free fixture is not the single extra row (old=% new=%)', v_n, v_n2;
  END IF;
  IF v_n < 2 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5] incompletos control too small to be meaningful: %', v_n;
  END IF;

  -- sin_beneficiario, both predicates, fixtures present
  SELECT count(*) INTO v_n FROM deals d
    JOIN pipeline_stages s ON s.id = d.stage_id
    JOIN conversations v ON v.id = d.conversation_id
    JOIN contacts      c ON c.id = v.contact_id
    JOIN remittance_operations o ON o.deal_id = d.id
    CROSS JOIN LATERAL (SELECT max(m.consumido_en) AS dinero_dentro FROM depositos_mmg m
                         WHERE m.deal_id = d.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) dep
   WHERE d.pipeline_id = c_pipe AND d.status = 'open'
     AND d.stage_id IN (c_porver, c_encurso)
     AND COALESCE(o.service_type,'remesa') <> 'recarga'
     AND dep.dinero_dentro IS NOT NULL
     AND dep.dinero_dentro < now() - make_interval(mins => 30)
     AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente')
     AND COALESCE(d.notes,'') NOT LIKE '%BENEFICIARIO%'
     AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = d.conversation_id
                       AND m.sender_type='agent' AND NOT COALESCE(m.ai_generated,false)
                       AND m.created_at > now() - make_interval(mins => 20))
     AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                      WHERE a.clave = 'sin_beneficiario:' || d.id::text
                        AND a.ultimo > now() - make_interval(mins => 120));
  SELECT count(*) INTO v_n2 FROM remittance_operations op
    JOIN conversations v ON v.id = op.conversation_id
    JOIN contacts      c ON c.id = v.contact_id
    CROSS JOIN LATERAL (SELECT max(m.consumido_en) AS dinero_dentro FROM depositos_mmg m
                         WHERE m.operation_id = op.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) dep
   WHERE COALESCE(op.service_type,'remesa') <> 'recarga'
     AND op.status IN ('deposit_verification','ready_to_transfer')
     AND dep.dinero_dentro IS NOT NULL
     AND dep.dinero_dentro < now() - make_interval(mins => 30)
     AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = op.id AND b.status = 'vigente')
     AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = op.conversation_id
                       AND m.sender_type='agent' AND NOT COALESCE(m.ai_generated,false)
                       AND m.created_at > now() - make_interval(mins => 20))
     AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                      WHERE a.clave = 'sin_beneficiario:' || coalesce(op.deal_id, op.id)::text
                        AND a.ultimo > now() - make_interval(mins => 120));
  RAISE NOTICE 'sin_beneficiario with fixtures: old=%, new=% (expect new = old + 1)', v_n, v_n2;
  IF v_n2 <> v_n + 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5] sin_beneficiario: the deal-free fixture is not the single extra row (old=% new=%)', v_n, v_n2;
  END IF;
  IF v_n < 2 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5] sin_beneficiario control too small to be meaningful: %', v_n;
  END IF;

  IF v_fail = v_before THEN
    RAISE NOTICE 'PASS [5] the deal-free operation (161 path) is the single extra row in both predicates: visible to the new ones, invisible to the old ones';
  END IF;
  v_before := v_fail;

  -- ==================================================================
  -- [3] functions run and write; [4] clave continuity; ON CONFLICT
  -- ==================================================================
  DELETE FROM cerebro_alertas WHERE clave IN
    ('envio_incompleto:' || c_dl_a::text, 'envio_incompleto:' || v_op_c::text,
     'sin_beneficiario:' || c_dl_b::text);

  SELECT * INTO v_res FROM cerebro_avisar_envios_incompletos(NULL, 120);
  RAISE NOTICE 'cerebro_avisar_envios_incompletos() -> incompletos=%, avisos_creados=%', v_res.incompletos, v_res.avisos_creados;
  IF v_res.incompletos < 2 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] incompletos did not see both fixtures, got %', v_res.incompletos;
  END IF;

  SELECT clave, count(*) INTO v_clave_written, v_rows
    FROM cerebro_alertas WHERE clave = 'envio_incompleto:' || c_dl_a::text GROUP BY clave;
  IF COALESCE(v_rows, 0) <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] no single envio_incompleto alert row for the deal-linked fixture';
  END IF;
  SELECT count(*) INTO v_rows FROM cerebro_alertas WHERE clave = 'envio_incompleto:' || v_op_c::text;
  IF COALESCE(v_rows, 0) <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] the deal-free operation was not keyed on its own operation id';
  END IF;

  -- clave continuity: the old deal-keyed string vs the new coalesce string
  v_clave_old := 'envio_incompleto:' || c_dl_a::text;
  v_clave_new := 'envio_incompleto:' || coalesce(
    (SELECT deal_id FROM remittance_operations WHERE id = v_op_a),
    v_op_a)::text;
  RAISE NOTICE 'clave continuity (incompletos): old=%  new=%', v_clave_old, v_clave_new;
  IF v_clave_old <> v_clave_new THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] clave is not byte-identical for a deal-linked operation';
  END IF;

  -- ON CONFLICT: a second call with the repeat window at zero reaches the
  -- INSERT again and must UPDATE ultimo, not duplicate the row.
  -- now() is frozen for the whole transaction, so an immediate repeat cannot
  -- show the UPDATE. Age the stamped row instead: p_repetir_min => 0 makes it
  -- eligible again, and the ON CONFLICT branch must move ultimo forward while
  -- the row count stays 1 (never a duplicate).
  UPDATE cerebro_alertas SET ultimo = '2000-01-01' WHERE clave = v_clave_old;
  SELECT ultimo INTO v_ultimo_1 FROM cerebro_alertas WHERE clave = v_clave_old;
  SELECT * INTO v_res FROM cerebro_avisar_envios_incompletos(NULL, 0);
  SELECT ultimo, count(*) INTO v_ultimo_2, v_rows FROM cerebro_alertas WHERE clave = v_clave_old GROUP BY ultimo;
  RAISE NOTICE 'ON CONFLICT (incompletos): rows=%  ultimo % -> %', v_rows, v_ultimo_1, v_ultimo_2;
  IF COALESCE(v_rows, 0) <> 1 OR v_ultimo_2 <= v_ultimo_1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] the repeat call duplicated the row or did not refresh ultimo';
  END IF;

  -- [6] sin_beneficiario text, before vs after
  SELECT * INTO v_res FROM cerebro_avisar_envios_sin_beneficiario(NULL, 120);
  RAISE NOTICE 'cerebro_avisar_envios_sin_beneficiario() -> sin_destino=%, avisos_creados=%', v_res.sin_destino, v_res.avisos_creados;
  IF v_res.sin_destino < 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [6] sin_beneficiario did not see the fixture, got %', v_res.sin_destino;
  END IF;

  SELECT title, body INTO v_title, v_body FROM notifications
   WHERE type = 'envio_sin_beneficiario' AND contact_id = c_ct_b
   ORDER BY created_at DESC LIMIT 1;
  IF v_body IS NULL THEN
    RAISE EXCEPTION 'FAIL [6] no envio_sin_beneficiario notification for the fixture';
  END IF;
  RAISE NOTICE '--- sin_beneficiario title --- %', v_title;
  RAISE NOTICE '--- sin_beneficiario body --- %', v_body;

  -- change 1: no stage claim
  IF v_body LIKE '%Esta en "%' OR v_body LIKE '%En curso%' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [6] the body still claims a pipeline stage';
  END IF;
  -- change 2: the structured path, not the deal's notes. The new text still
  -- NAMES the retired block, to say it is the wrong route — so test the
  -- instruction, not the word.
  IF v_body LIKE '%se escribe el bloque BENEFICIARIO%'
     OR v_body LIKE '%el trigger hace el resto%' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [6] the body still instructs the operator to write the deal notes + trigger';
  END IF;
  IF v_body NOT LIKE '%remittance_beneficiaries%'
     OR v_body NOT LIKE '%via estructurada%'
     OR v_body NOT LIKE '%162%' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [6] the body does not point at the structured 162 path';
  END IF;
  -- the bot warning and the amount formatting must survive
  IF v_body NOT LIKE '%OJO:%' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [6] the bot warning sentence was lost';
  END IF;
  IF v_title NOT LIKE '%32,500 GYD%' OR v_title NOT LIKE '%dentro y SIN DESTINATARIO%' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [6] the title or its amount formatting changed: %', v_title;
  END IF;

  -- clave continuity for sin_beneficiario, from the row actually written
  SELECT clave INTO v_clave_written FROM cerebro_alertas WHERE clave = 'sin_beneficiario:' || c_dl_b::text;
  v_clave_old := 'sin_beneficiario:' || c_dl_b::text;
  RAISE NOTICE 'clave continuity (sin_beneficiario): old=%  written=%', v_clave_old, v_clave_written;
  IF v_clave_written IS DISTINCT FROM v_clave_old THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] sin_beneficiario clave is not byte-identical for a deal-linked operation';
  END IF;

  -- ON CONFLICT for sin_beneficiario, same aged-row trick. Run after the text
  -- capture so the newest notification stays the one read above.
  UPDATE cerebro_alertas SET ultimo = '2000-01-01' WHERE clave = v_clave_old;
  SELECT ultimo INTO v_ultimo_1 FROM cerebro_alertas WHERE clave = v_clave_old;
  SELECT * INTO v_res FROM cerebro_avisar_envios_sin_beneficiario(NULL, 0);
  SELECT ultimo, count(*) INTO v_ultimo_2, v_rows FROM cerebro_alertas WHERE clave = v_clave_old GROUP BY ultimo;
  RAISE NOTICE 'ON CONFLICT (sin_beneficiario): rows=%  ultimo % -> %', v_rows, v_ultimo_1, v_ultimo_2;
  IF COALESCE(v_rows, 0) <> 1 OR v_ultimo_2 <= v_ultimo_1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] the repeat call duplicated the sin_beneficiario row or did not refresh ultimo';
  END IF;

  IF v_fail = v_before THEN
    RAISE NOTICE 'PASS [4][6] both functions ran and wrote; clave is byte-identical for deal-linked operations; the repeat call updated instead of duplicating; both text changes are in place';
  END IF;

  ------------------------------------------------------------------
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'rekey-shipment-alerts-onto-operations: % check(s) FAILED', v_fail;
  END IF;
  RAISE NOTICE 'rekey-shipment-alerts-onto-operations: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT rekey_shipment_alerts;
