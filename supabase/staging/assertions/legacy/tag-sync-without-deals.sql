\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- =====================================================================
-- tag-sync-without-deals.sql — self-reverting assertion for
-- 168_tags_off_delivered_operations.sql (WU6f of the eliminate-deals
-- feature on WaCRM).
--
-- 168 re-keys sync_tags_cliente(uuid) off DELIVERED OPERATIONS instead of
-- delivered deals. It has no defining migration: the live body was
-- captured from pg_get_functiondef (md5(prosrc) =
-- d0a05822c5116cd69e97c58721846724, length 1351) and this migration is
-- the first repository definition of it. Only the count block changes.
--
-- WHAT THIS FILE PROVES (against the live staging catalog)
--
--   Part 0  The catalog exit criterion: the positional deals-referencing
--           function set shrinks by exactly one — sync_tags_cliente — from
--           five to four, and the non-empty guard runs first. It also
--           prints BOTH counting definitions (positional reference vs any
--           word mention) so no reader has to guess which one is asserted.
--   Part 1  The four fixtures, each printing the OLD predicate count and
--           the NEW predicate count side by side, plus the tag the
--           function actually assigns:
--             1 deal at Entregada + linked op completed ....... 1 / 1
--             3 such deals + 3 linked ops completed .......... 3 / 3
--             1 deal at Entregada, linked op NOT completed ... 1 / 0
--             1 deal-free op at completed .................... 0 / 1
--           The last two are the intended divergences of dropping
--           trg_sync_operacion_desde_deal in 114. They are behaviour, not
--           defects, and they are asserted as behaviour.
--   Part 2  The tag actually moves: a contact that was Cliente becomes
--           Recurrentes on the third delivery AND loses its stale Cliente
--           row (the delete ... is distinct from v_objetivo branch).
--   Part 3  contacts_sync_tags still fires: a NEW contact gets Nuevo with
--           no explicit call.
--   Part 4  The v_es_admin early return still short-circuits: an
--           Admin-tagged contact keeps its tags and gains none.
--   Part 5  n8n's binding still works: `select public.sync_tags_cliente(
--           <uuid>::uuid)` returns, and the identity arguments are
--           unchanged.
--   Part 6  The frozen contract, before and after: signature, argument
--           name, defaults, return type, language, SECURITY DEFINER,
--           volatility, owner, search_path and ACL — PUBLIC absent.
--   Part 7  The body freeze: md5(prosrc) = 4c79ab4579d24a55b85418d78347e6c1
--           / length 1278, the preserved logic markers are all present,
--           and the trigger that calls this function is untouched.
--
-- RED before 168: Part 0 shows a five-element set (sync_tags_cliente
-- still in it), Part 7's md5 is still d0a05822c5116cd69e97c58721846724,
-- and fixtures 3 and 4 tag the OLD way (Cliente instead of Nuevo, Nuevo
-- instead of Cliente). The trap this file exists to avoid: on staging the
-- live count of deals at Entregada and of operations at completed is 0, so
-- a naive old-vs-new comparison returns 0 = 0 and proves nothing. Every
-- count below rests on fixtures built here, and every fixture set is
-- non-empty by construction.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK:
--   BEGIN; \i tag-sync-without-deals.sql ROLLBACK;
-- (or the whole file wrapped in BEGIN ... ROLLBACK). Never COMMIT.
-- An unwrapped run makes SAVEPOINT fail in autocommit and commits the
-- fixtures. Never run against production.
-- =====================================================================

SAVEPOINT tag_sync_without_deals;

-- Does a body name the `deals` table in a position only a real reference
-- can occupy? Comment lines are stripped first: prosrc keeps the comments,
-- and a comment that merely mentions a deals write must not count as one.
-- Word boundaries use \m / \M — in PostgreSQL ARE, \b is not a word
-- boundary and silently matches nothing.
CREATE FUNCTION pg_temp.wu6f_strip_comments(p_src text) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT regexp_replace(p_src, '--[^' || chr(10) || ']*', '', 'g');
$fn$;

CREATE FUNCTION pg_temp.wu6f_names_deals(p_src text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT pg_temp.wu6f_strip_comments(p_src)
         ~* '(from|join|update|into|table)[[:space:]]+(public\.)?deals\M';
$fn$;

-- Any word mention of `deals`, comments stripped. Informational: this is
-- the looser counting definition, reported beside the positional one.
CREATE FUNCTION pg_temp.wu6f_mentions_deals(p_src text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT pg_temp.wu6f_strip_comments(p_src) ~* '\mdeals\M';
$fn$;

-- Fixture plumbing: a contact + its conversation, and a deal that goes
-- through the real INSERT path (the 125 trigger creates the operation).
CREATE FUNCTION pg_temp.wu6f_seed_contact(
  p_contact uuid, p_conv uuid, p_user uuid, p_acct uuid, p_phone text, p_name text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (p_contact, p_user, p_phone, p_name, p_acct);
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (p_conv, p_user, p_contact, p_acct);
END $fn$;

CREATE FUNCTION pg_temp.wu6f_add_deal(
  p_deal uuid, p_contact uuid, p_conv uuid, p_user uuid, p_acct uuid,
  p_pipe uuid, p_stage uuid, p_title text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  INSERT INTO deals (id, user_id, account_id, contact_id, conversation_id,
                     pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (p_deal, p_user, p_acct, p_contact, p_conv, p_pipe, p_stage,
          p_title, 1000, 'GYD', 'wu6f fixture', 'open');
END $fn$;

CREATE FUNCTION pg_temp.wu6f_old_count(p_contact uuid, p_pipe uuid, p_stage uuid)
RETURNS integer LANGUAGE sql STABLE AS $fn$
  SELECT count(*)::integer FROM deals d
   WHERE d.contact_id = p_contact
     AND d.pipeline_id = p_pipe
     AND d.stage_id = p_stage;
$fn$;

CREATE FUNCTION pg_temp.wu6f_new_count(p_contact uuid)
RETURNS integer LANGUAGE sql STABLE AS $fn$
  SELECT count(*)::integer FROM remittance_operations ro
   WHERE ro.contact_id = p_contact
     AND ro.status = 'completed';
$fn$;

CREATE FUNCTION pg_temp.wu6f_tags_of(p_contact uuid)
RETURNS text[] LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(array_agg(t.name ORDER BY t.name), ARRAY[]::text[])
    FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id
   WHERE ct.contact_id = p_contact;
$fn$;

DO $$
DECLARE
  c_user  CONSTANT uuid := 'cccccccc-1111-4111-8111-111111111101';
  c_acct  CONSTANT uuid := 'cccccccc-2222-4222-8222-222222222202';
  c_pipe  CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  c_entr  CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';

  v_nuevo uuid; v_cliente uuid; v_rec uuid; v_admin uuid;

  -- fixture contacts / conversations
  va_c uuid := 'cccccccc-3333-4333-8333-333333333301'; va_v uuid := 'cccccccc-4444-4444-8444-444444444401';
  vb_c uuid := 'cccccccc-3333-4333-8333-333333333302'; vb_v uuid := 'cccccccc-4444-4444-8444-444444444402';
  vc_c uuid := 'cccccccc-3333-4333-8333-333333333303'; vc_v uuid := 'cccccccc-4444-4444-8444-444444444403';
  vd_c uuid := 'cccccccc-3333-4333-8333-333333333304'; vd_v uuid := 'cccccccc-4444-4444-8444-444444444404';
  ve_c uuid := 'cccccccc-3333-4333-8333-333333333305'; ve_v uuid := 'cccccccc-4444-4444-8444-444444444405';
  vf_c uuid := 'cccccccc-3333-4333-8333-333333333306'; vf_v uuid := 'cccccccc-4444-4444-8444-444444444406';

  v_da uuid := 'cccccccc-5555-4555-8555-555555555501';
  v_db1 uuid := 'cccccccc-5555-4555-8555-555555555502';
  v_db2 uuid := 'cccccccc-5555-4555-8555-555555555503';
  v_db3 uuid := 'cccccccc-5555-4555-8555-555555555504';
  v_dc uuid := 'cccccccc-5555-4555-8555-555555555505';

  v_opd uuid;                                   -- deal-free operation (fixture D)
  v_old integer; v_new integer;
  v_tag text; v_expect text;
  v_before text[]; v_after text[];
  v_set text[]; v_mention text[];
  v_n integer;
  v_src text; v_md5 text; v_len integer;
  v_ident_args text; v_args text; v_ret text; v_lang text;
  v_secdef boolean; v_vol text; v_owner text; v_config text;
  v_acl text; v_defaults integer;
  v_trg text;
  v_fail integer := 0;
BEGIN
  SELECT id INTO v_nuevo   FROM tags WHERE lower(name) = 'nuevo'       LIMIT 1;
  SELECT id INTO v_cliente FROM tags WHERE lower(name) = 'cliente'     LIMIT 1;
  SELECT id INTO v_rec     FROM tags WHERE lower(name) = 'recurrentes' LIMIT 1;
  SELECT id INTO v_admin   FROM tags WHERE lower(name) = 'admin'       LIMIT 1;
  IF v_nuevo IS NULL OR v_cliente IS NULL OR v_rec IS NULL OR v_admin IS NULL THEN
    RAISE EXCEPTION 'wu6f: the four tag rows (Nuevo/Cliente/Recurrentes/Admin) must exist on staging';
  END IF;

  ------------------------------------------------------------------
  -- Part 0 — catalog exit criterion.
  ------------------------------------------------------------------
  SELECT coalesce(array_agg(p.proname ORDER BY p.proname), ARRAY[]::text[]) INTO v_set
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND pg_temp.wu6f_names_deals(p.prosrc);

  SELECT coalesce(array_agg(p.proname ORDER BY p.proname), ARRAY[]::text[]) INTO v_mention
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND pg_temp.wu6f_mentions_deals(p.prosrc);

  RAISE NOTICE 'MEASURED positional deals-reference set: %', v_set;
  RAISE NOTICE 'MEASURED any-word-mention deals set  : %', v_mention;

  -- Non-empty guard before believing anything about the set.
  IF v_set IS NULL OR array_length(v_set, 1) IS NULL OR array_length(v_set, 1) = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0] the deals-referencing function set is EMPTY — the probe is broken, not the catalog';
  ELSIF v_set IS DISTINCT FROM ARRAY[
       'cerebro_aplicar_nombre_confirmado',
       'cerebro_sync_beneficiarios',
       'crm_forzar_verificacion',
       'crm_verificar_deposito']::text[] THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0] the positional deals-referencing function set is % — expected the four left after WU6f (WU6c/WU6e kept five; 168 removes sync_tags_cliente)', v_set;
  ELSE
    RAISE NOTICE 'PASS [0] exactly four functions reference deals in a real position (5 -> 4: sync_tags_cliente left on operations)';
  END IF;

  IF NOT ('sync_tags_cliente' = ANY (v_set)) THEN
    RAISE NOTICE 'PASS [0.1] sync_tags_cliente no longer references deals in a real position';
  ELSE
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0.1] sync_tags_cliente STILL references deals in a real position — 168 is not applied';
  END IF;

  IF NOT (pg_temp.wu6f_names_deals(
        (SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND p.proname = 'sync_tags_cliente'))) THEN
    RAISE NOTICE 'PASS [0.2] the sync_tags_cliente body names no `deals` table';
  ELSE
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0.2] the sync_tags_cliente body still names `deals`';
  END IF;

  ------------------------------------------------------------------
  -- Fixtures. Built BEFORE the counts, driven through the real INSERT
  -- path: the deal insert fires cerebro_crear_operacion_al_crear_deal,
  -- which creates the linked operation with the status mapped from the
  -- stage by cerebro_estado_desde_etapa.
  ------------------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data,
    is_sso_user, is_anonymous)
  VALUES (c_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'wu6f-asrt@test.invalid','$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ',
    now(),now(),now(),'{}'::jsonb,'{}'::jsonb,false,false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (c_acct,'wu6f assertion account',c_user);
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), c_user, 'wu6f assertion', 'wu6f-asrt@test.invalid', c_acct, 'owner');

  -- A human actor: the Entregada-completion guard (deals + operations) only
  -- lets a human member write 'completed' / reach Entregada.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', c_user, 'role', 'authenticated')::text, true);

  PERFORM pg_temp.wu6f_seed_contact(va_c, va_v, c_user, c_acct, '15550007001', 'wu6f A');
  PERFORM pg_temp.wu6f_seed_contact(vb_c, vb_v, c_user, c_acct, '15550007002', 'wu6f B');
  PERFORM pg_temp.wu6f_seed_contact(vc_c, vc_v, c_user, c_acct, '15550007003', 'wu6f C');
  PERFORM pg_temp.wu6f_seed_contact(vd_c, vd_v, c_user, c_acct, '15550007004', 'wu6f D');
  PERFORM pg_temp.wu6f_seed_contact(ve_c, ve_v, c_user, c_acct, '15550007005', 'wu6f E');
  PERFORM pg_temp.wu6f_seed_contact(vf_c, vf_v, c_user, c_acct, '15550007006', 'wu6f F');

  -- A: one deal sitting at Entregada -> the 125 trigger makes its op 'completed'.
  PERFORM pg_temp.wu6f_add_deal(v_da, va_c, va_v, c_user, c_acct, c_pipe, c_entr, 'wu6f A');
  -- B: starts with one, grows to three (Part 2 drives the tag move).
  PERFORM pg_temp.wu6f_add_deal(v_db1, vb_c, vb_v, c_user, c_acct, c_pipe, c_entr, 'wu6f B1');
  -- C: one deal at Entregada whose linked op is moved off completed.
  PERFORM pg_temp.wu6f_add_deal(v_dc, vc_c, vc_v, c_user, c_acct, c_pipe, c_entr, 'wu6f C');
  UPDATE remittance_operations
     SET status = 'incident', incident_reason = 'wu6f divergence A'
   WHERE deal_id = v_dc;
  -- D: no deal at all — a genuinely deal-free operation driven to completed
  -- through the real creator (cerebro_crear_operacion, the 161 path).
  v_opd := cerebro_crear_operacion(vd_v, 1000, 'GYD', c_entr);
  -- E: trigger-only contact (Part 3). F: admin contact (Part 4).

  ------------------------------------------------------------------
  -- Part 1 — the four fixtures, both counts side by side.
  ------------------------------------------------------------------
  -- Fixture 1: 1 deal at Entregada + linked op completed -> 1 / 1
  v_old := pg_temp.wu6f_old_count(va_c, c_pipe, c_entr);
  v_new := pg_temp.wu6f_new_count(va_c);
  RAISE NOTICE 'FIXTURE 1 (1 deal Entregada + linked op completed) old=% new=%', v_old, v_new;
  IF v_old <> 1 OR v_new <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1.1] expected 1 / 1, measured % / %', v_old, v_new;
  END IF;
  PERFORM public.sync_tags_cliente(va_c);
  SELECT t.name INTO v_tag FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id
   WHERE ct.contact_id = va_c AND lower(t.name) IN ('nuevo','cliente','recurrentes');
  IF v_tag IS DISTINCT FROM 'Cliente' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1.1] contact A tagged % — expected Cliente at new count 1', v_tag;
  ELSE
    RAISE NOTICE 'PASS [1.1] contact A tagged Cliente on 1 completed operation';
  END IF;

  -- Fixture 2: 3 such deals + 3 linked ops completed -> 3 / 3 (the >2 boundary)
  PERFORM pg_temp.wu6f_add_deal(v_db2, vb_c, vb_v, c_user, c_acct, c_pipe, c_entr, 'wu6f B2');
  PERFORM pg_temp.wu6f_add_deal(v_db3, vb_c, vb_v, c_user, c_acct, c_pipe, c_entr, 'wu6f B3');
  v_old := pg_temp.wu6f_old_count(vb_c, c_pipe, c_entr);
  v_new := pg_temp.wu6f_new_count(vb_c);
  RAISE NOTICE 'FIXTURE 2 (3 deals Entregada + 3 linked ops completed) old=% new=%', v_old, v_new;
  IF v_old <> 3 OR v_new <> 3 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1.2] expected 3 / 3, measured % / %', v_old, v_new;
  END IF;

  -- Fixture 3: deal at Entregada whose linked op is NOT completed -> 1 / 0
  v_old := pg_temp.wu6f_old_count(vc_c, c_pipe, c_entr);
  v_new := pg_temp.wu6f_new_count(vc_c);
  RAISE NOTICE 'FIXTURE 3 (deal Entregada, linked op NOT completed) old=% new=%  [divergence A]', v_old, v_new;
  IF v_old <> 1 OR v_new <> 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1.3] expected 1 / 0, measured % / %', v_old, v_new;
  END IF;
  PERFORM public.sync_tags_cliente(vc_c);
  SELECT t.name INTO v_tag FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id
   WHERE ct.contact_id = vc_c AND lower(t.name) IN ('nuevo','cliente','recurrentes');
  IF v_tag IS DISTINCT FROM 'Nuevo' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1.3] contact C tagged % — expected Nuevo: the delivered predicate no longer counts a deal whose operation is not completed', v_tag;
  ELSE
    RAISE NOTICE 'PASS [1.3] divergence A holds: deal at Entregada with a non-completed op counts 0, contact is Nuevo';
  END IF;

  -- Fixture 4: deal-free op (deal_id IS NULL) at completed -> 0 / 1
  IF NOT EXISTS (SELECT 1 FROM remittance_operations WHERE id = v_opd AND deal_id IS NULL) THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1.4] the deal-free fixture operation is not deal-free';
  END IF;
  v_old := pg_temp.wu6f_old_count(vd_c, c_pipe, c_entr);
  v_new := pg_temp.wu6f_new_count(vd_c);
  RAISE NOTICE 'FIXTURE 4 (deal-free op at completed) old=% new=%  [divergence B]', v_old, v_new;
  IF v_old <> 0 OR v_new <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1.4] expected 0 / 1, measured % / %', v_old, v_new;
  END IF;
  PERFORM public.sync_tags_cliente(vd_c);
  SELECT t.name INTO v_tag FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id
   WHERE ct.contact_id = vd_c AND lower(t.name) IN ('nuevo','cliente','recurrentes');
  IF v_tag IS DISTINCT FROM 'Cliente' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1.4] contact D tagged % — expected Cliente: a deal-free completed operation now counts', v_tag;
  ELSE
    RAISE NOTICE 'PASS [1.4] divergence B holds: a deal-free completed operation counts 1, contact is Cliente';
  END IF;

  ------------------------------------------------------------------
  -- Part 2 — the tag actually moves, and the stale tag row is deleted.
  -- Contact B is at three delivered operations now.
  ------------------------------------------------------------------
  -- Rebuild B's history honestly: undo B to one deal first, sync, then
  -- grow to three and sync again.
  DELETE FROM remittance_operations WHERE deal_id IN (v_db2, v_db3);
  DELETE FROM deals WHERE id IN (v_db2, v_db3);
  PERFORM public.sync_tags_cliente(vb_c);
  v_before := pg_temp.wu6f_tags_of(vb_c);

  PERFORM pg_temp.wu6f_add_deal(v_db2, vb_c, vb_v, c_user, c_acct, c_pipe, c_entr, 'wu6f B2');
  PERFORM pg_temp.wu6f_add_deal(v_db3, vb_c, vb_v, c_user, c_acct, c_pipe, c_entr, 'wu6f B3');
  PERFORM public.sync_tags_cliente(vb_c);
  v_after := pg_temp.wu6f_tags_of(vb_c);

  RAISE NOTICE 'TAG MOVE contact B: before=% after=%', v_before, v_after;
  IF NOT (v_before @> ARRAY['Cliente']) THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2.1] contact B was % before the third delivery — expected Cliente among them', v_before;
  ELSE
    RAISE NOTICE 'PASS [2.1] contact B was Cliente on one delivered operation';
  END IF;
  IF NOT (v_after @> ARRAY['Recurrentes']) THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2.2] contact B is % after the third delivery — expected Recurrentes', v_after;
  ELSE
    RAISE NOTICE 'PASS [2.2] contact B became Recurrentes on the third delivered operation';
  END IF;
  IF 'Cliente' = ANY (v_after) THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2.3] contact B kept its stale Cliente row: %', v_after;
  ELSE
    RAISE NOTICE 'PASS [2.3] contact B lost its stale Cliente row (the delete ... is distinct from v_objetivo branch)';
  END IF;

  -- Fixture 2's numbers, re-measured after the growth, to keep the pair
  -- honest rather than asserted twice.
  v_old := pg_temp.wu6f_old_count(vb_c, c_pipe, c_entr);
  v_new := pg_temp.wu6f_new_count(vb_c);
  RAISE NOTICE 'FIXTURE 2 (re-measured after growth) old=% new=%', v_old, v_new;
  IF v_old <> 3 OR v_new <> 3 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1.2] expected 3 / 3, measured % / %', v_old, v_new;
  END IF;

  ------------------------------------------------------------------
  -- Part 3 — contacts_sync_tags still fires on contact insert.
  ------------------------------------------------------------------
  v_after := pg_temp.wu6f_tags_of(ve_c);
  RAISE NOTICE 'TRIGGER contact E (no explicit call): %', v_after;
  IF NOT (v_after @> ARRAY['Nuevo']) THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] contacts_sync_tags did not tag the new contact Nuevo: %', v_after;
  ELSE
    RAISE NOTICE 'PASS [3] the contact insert produced Nuevo with no explicit call';
  END IF;

  ------------------------------------------------------------------
  -- Part 4 — the admin early return still short-circuits.
  ------------------------------------------------------------------
  DELETE FROM contact_tags WHERE contact_id = vf_c;
  INSERT INTO contact_tags (id, contact_id, tag_id)
  VALUES (gen_random_uuid(), vf_c, v_admin);
  v_before := pg_temp.wu6f_tags_of(vf_c);
  PERFORM public.sync_tags_cliente(vf_c);
  v_after := pg_temp.wu6f_tags_of(vf_c);
  RAISE NOTICE 'ADMIN contact F: before=% after=%', v_before, v_after;
  IF v_before IS DISTINCT FROM v_after OR v_after IS DISTINCT FROM ARRAY['Admin']::text[] THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] the admin contact changed: before=% after=%', v_before, v_after;
  ELSE
    RAISE NOTICE 'PASS [4] the Admin-tagged contact kept its tag and gained none (early return)';
  END IF;

  ------------------------------------------------------------------
  -- Part 5 — n8n's binding: the direct call still returns.
  ------------------------------------------------------------------
  PERFORM public.sync_tags_cliente(va_c);
  RAISE NOTICE 'PASS [5] select public.sync_tags_cliente(<uuid>::uuid) returned cleanly (n8n calls it as service_role)';

  ------------------------------------------------------------------
  -- Part 6 — the frozen contract.
  ------------------------------------------------------------------
  SELECT pg_get_function_identity_arguments(p.oid), pg_get_function_arguments(p.oid),
         p.prorettype::regtype::text, l.lanname, p.prosecdef, p.provolatile,
         p.proowner::regrole::text, p.proconfig::text, p.proacl::text, p.pronargdefaults
    INTO v_ident_args, v_args, v_ret, v_lang, v_secdef, v_vol, v_owner, v_config, v_acl, v_defaults
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_language l ON l.oid = p.prolang
   WHERE n.nspname = 'public' AND p.proname = 'sync_tags_cliente';

  RAISE NOTICE 'CONTRACT sync_tags_cliente(%): returns % lang % secdef % volatile % owner % config % acl %',
    v_args, v_ret, v_lang, v_secdef, v_vol, v_owner, v_config, v_acl;

  IF v_ident_args IS DISTINCT FROM 'p_contact_id uuid' THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [6] identity arguments changed: %', v_ident_args;
  END IF;
  IF v_ret <> 'void' OR v_lang <> 'plpgsql' OR NOT v_secdef OR v_vol <> 'v' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [6] contract drift: ret=% lang=% secdef=% volatile=%', v_ret, v_lang, v_secdef, v_vol;
  END IF;
  IF v_defaults <> 0 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [6] pronargdefaults is % — expected 0', v_defaults;
  END IF;
  IF v_owner <> 'postgres' THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [6] owner is % — expected postgres', v_owner;
  END IF;
  IF v_config IS DISTINCT FROM '{search_path=public}' THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [6] proconfig is % — expected {search_path=public}', v_config;
  END IF;
  IF v_acl IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [6] ACL changed: % — expected {postgres=X/postgres,service_role=X/postgres}', v_acl;
  END IF;
  IF v_acl ~ '(^|\{|,)X/' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [6] an empty-grantee (PUBLIC) entry is present in the ACL: %', v_acl;
  END IF;
  IF v_acl IS NOT DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
    RAISE NOTICE 'PASS [6] signature, return type, language, SECURITY DEFINER, volatility, owner, search_path and ACL unchanged; PUBLIC absent';
  END IF;

  ------------------------------------------------------------------
  -- Part 7 — body freeze: only the count block changed.
  ------------------------------------------------------------------
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'sync_tags_cliente';
  v_md5 := md5(v_src); v_len := length(v_src);
  RAISE NOTICE 'BODY md5=% length=%', v_md5, v_len;
  IF v_md5 IS DISTINCT FROM '4c79ab4579d24a55b85418d78347e6c1' OR v_len <> 1278 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [7] sync_tags_cliente body is md5=% length=% — expected 4c79ab4579d24a55b85418d78347e6c1 / 1278 (168 not applied, or extra drift)', v_md5, v_len;
  ELSE
    RAISE NOTICE 'PASS [7] sync_tags_cliente body is the 168 body (md5 4c79ab4579d24a55b85418d78347e6c1 / 1278)';
  END IF;

  -- The preserved logic, byte-for-byte.
  IF position('v_es_admin' in v_src) > 0
     AND position('tag_id is distinct from v_objetivo' in v_src) > 0
     AND position('on conflict (contact_id, tag_id) do nothing' in v_src) > 0
     AND position('gen_random_uuid()' in v_src) > 0
     AND position('elsif v_entregadas <= 2 then' in v_src) > 0
     AND position('from remittance_operations ro' in v_src) > 0
     AND position('from deals' in v_src) = 0 THEN
    RAISE NOTICE 'PASS [7.1] the preserved logic markers are all present and the deals count block is gone';
  ELSE
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [7.1] the body lost a preserved marker, or still contains the deals count block';
  END IF;

  SELECT count(*) INTO v_n FROM regexp_matches(v_src, 'lower\(name\) = ', 'g');
  IF v_n <> 3 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [7.2] expected the three lower(name) tag lookups, found %', v_n;
  ELSE
    RAISE NOTICE 'PASS [7.2] the three lower(name) tag lookups are intact';
  END IF;

  -- The trigger that drives the function, and the deal trigger that 168
  -- must NOT have touched.
  SELECT pg_get_triggerdef(oid) INTO v_trg FROM pg_trigger
   WHERE tgrelid = 'public.contacts'::regclass AND tgname = 'contacts_sync_tags';
  IF v_trg IS DISTINCT FROM
     'CREATE TRIGGER contacts_sync_tags AFTER INSERT ON public.contacts FOR EACH ROW EXECUTE FUNCTION trg_sync_tags_contact()' THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [7.3] contacts_sync_tags changed: %', v_trg;
  ELSE
    RAISE NOTICE 'PASS [7.3] contacts_sync_tags is unchanged';
  END IF;

  SELECT md5(p.prosrc) INTO v_md5 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'trg_sync_tags_contact';
  IF v_md5 IS DISTINCT FROM 'e511de8089a04e2e09e851f4f3e0da35' THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [7.4] trg_sync_tags_contact body changed: %', v_md5;
  END IF;

  SELECT count(*) INTO v_n FROM pg_trigger
   WHERE tgrelid = 'public.deals'::regclass AND tgname = 'deals_sync_tags' AND NOT tgisinternal;
  IF v_n <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [7.5] deals_sync_tags is gone from `deals` — 168 must not drop it (the DROP TABLE owns that)';
  ELSE
    RAISE NOTICE 'PASS [7.4/7.5] trg_sync_tags_contact body and the deals_sync_tags trigger are untouched';
  END IF;

  ------------------------------------------------------------------
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'FAIL tag-sync-without-deals: % check(s) failed', v_fail;
  END IF;
  RAISE NOTICE 'OK tag-sync-without-deals: every check passed';
END $$;

-- Convention: reaching this point means every case above passed.
DO $$ BEGIN RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'; END $$;
