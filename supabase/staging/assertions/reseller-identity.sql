\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 395 (reseller identity from the "Revendedor" tag).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs.
-- Run it alone on the staging catalog (wrapped by staging-migracion.sh, or
-- by hand as  BEGIN; \i this file; ROLLBACK;).
--
-- RED before 395: the first helper call fails with
--   function public.reseller_tag_name_matches(text) does not exist
-- because neither helper nor the backfill function exists yet.
--
-- Cases:
--   1 the name rule: "Revendedor", "  revendedor  ", "REVENDEDOR" match;
--     "Revendedores", "Revendedór", "", NULL and untagged do not
--   2 the allow-list backfill: an active phone with a contact is tagged
--     (reusing the account's existing matching tag; creating "Revendedor"
--     only where the account has no matching tag), an inactive row tags
--     nothing, an already-tagged contact stays idempotent, and every
--     created tag / link leaves a migration_reseller_tag_added audit row
--   3 a matching tag from another account does not count
--   4 bot parity: cerebro_es_revendedor equals the old inline allow-list
--     rule for every conversation that was a reseller, and the migration's
--     own "no reseller lost" check holds
--   5 duplicate matching tags yield one reseller, and untagging makes the
--     conversation stop being a reseller
--   6 privileges, the deprecated allow-list marker and the audit action list
-- =====================================================================
BEGIN;

DO $$
DECLARE
  v_user_a      uuid;
  v_user_b      uuid;
  v_acc_a       uuid;
  v_acc_b       uuid;
  v_tag_a       uuid;
  v_tag_b       uuid;
  v_dup_tag     uuid;
  v_a1          uuid;
  v_a2          uuid;
  v_a3          uuid;
  v_b1          uuid;
  v_b2          uuid;
  v_untagged    uuid;
  v_conv_a1     uuid;
  v_conv_a2     uuid;
  v_conv_a3     uuid;
  v_conv_b1     uuid;
  v_conv_b2     uuid;
  v_conv_u      uuid;
  v_before_tags integer;
  v_before_links integer;
  v_before_audit integer;
  v_result      jsonb;
  v_old         boolean;
  v_new         boolean;
BEGIN
  -- ---- fixtures: borrow two existing accounts with no matching tag (accounts are one-per-owner) ----
  WITH owners AS (
    SELECT DISTINCT ON (p.account_id) p.account_id, p.user_id
      FROM profiles p JOIN auth.users u ON u.id = p.user_id
     WHERE NOT EXISTS (
             SELECT 1 FROM tags t
              WHERE t.account_id = p.account_id
                AND reseller_tag_name_matches(t.name))
     ORDER BY p.account_id, p.user_id
  ), numbered AS (
    SELECT account_id, user_id, row_number() OVER (ORDER BY account_id) AS rn FROM owners
  )
  SELECT (SELECT user_id FROM numbered WHERE rn = 1), (SELECT account_id FROM numbered WHERE rn = 1),
         (SELECT user_id FROM numbered WHERE rn = 2), (SELECT account_id FROM numbered WHERE rn = 2)
    INTO v_user_a, v_acc_a, v_user_b, v_acc_b;
  IF v_user_a IS NULL OR v_user_b IS NULL OR v_acc_a = v_acc_b THEN
    RAISE EXCEPTION 'fixture: two distinct accounts without a matching tag are needed';
  END IF;

  -- A gets a matching tag (lower case) and a near-miss; B stays without one.
  INSERT INTO tags (user_id, account_id, name) VALUES (v_user_a, v_acc_a, 'revendedor') RETURNING id INTO v_tag_a;
  INSERT INTO tags (user_id, account_id, name) VALUES (v_user_a, v_acc_a, 'Revendedores');

  -- ---- 1. the name rule ----
  IF reseller_tag_name_matches('Revendedor') IS NOT TRUE
     OR reseller_tag_name_matches('  revendedor  ') IS NOT TRUE
     OR reseller_tag_name_matches('REVENDEDOR') IS NOT TRUE THEN
    RAISE EXCEPTION 'case 1: case and surrounding spaces must be ignored (Revendedor / "  revendedor  " / REVENDEDOR)';
  END IF;
  IF reseller_tag_name_matches('Revendedores') IS TRUE
     OR reseller_tag_name_matches('Revendedór') IS TRUE
     OR reseller_tag_name_matches('Revendedor extra') IS TRUE
     OR reseller_tag_name_matches('') IS TRUE
     OR reseller_tag_name_matches(NULL) IS TRUE THEN
    RAISE EXCEPTION 'case 1: plural, accented and other variants must not match';
  END IF;
  RAISE NOTICE 'PASS 1: name rule matches Revendedor/revendedor/REVENDEDOR and rejects plural, accent, extra text, empty and NULL';

  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user_a, v_acc_a, '59903951001', 'test395 a1') RETURNING id INTO v_a1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user_a, v_acc_a, '59903951002', 'test395 a2') RETURNING id INTO v_a2;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user_a, v_acc_a, '59903951003', 'test395 a3') RETURNING id INTO v_a3;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user_b, v_acc_b, '59903951004', 'test395 b1') RETURNING id INTO v_b1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user_b, v_acc_b, '59903951005', 'test395 b2') RETURNING id INTO v_b2;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user_a, v_acc_a, '59903951006', 'test395 untagged') RETURNING id INTO v_untagged;

  -- active rows: a1 (to tag), a3 (already tagged), b1 (B has no tag to reuse)
  INSERT INTO cerebro_revendedores (phone, nombre, activo) VALUES ('59903951001', 'test395 a1', true);
  INSERT INTO cerebro_revendedores (phone, nombre, activo) VALUES ('59903951003', 'test395 a3', true);
  INSERT INTO cerebro_revendedores (phone, nombre, activo) VALUES ('59903951004', 'test395 b1', true);
  -- inactive: a2 must not be tagged
  INSERT INTO cerebro_revendedores (phone, nombre, activo) VALUES ('59903951002', 'test395 a2', false);

  -- a3 is already tagged before the backfill
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_a3, v_tag_a);

  -- ---- 2. run the migration's backfill against these fixtures ----
  v_result := _reseller_backfill_allow_list();
  IF (v_result ->> 'tags_created')::int <> 1 OR (v_result ->> 'links_created')::int <> 2 THEN
    RAISE EXCEPTION 'case 2: expected 1 tag created (account B) and 2 links (a1, b1), got %', v_result;
  END IF;

  SELECT id INTO v_tag_b FROM tags WHERE account_id = v_acc_b AND reseller_tag_name_matches(name);
  IF v_tag_b IS NULL THEN RAISE EXCEPTION 'case 2: account B must get a Revendedor tag'; END IF;
  IF (SELECT count(*) FROM tags WHERE account_id = v_acc_a AND reseller_tag_name_matches(name)) <> 1 THEN
    RAISE EXCEPTION 'case 2: account A must reuse its existing matching tag (one matching tag, no duplicate)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM contact_tags WHERE contact_id = v_a1 AND tag_id = v_tag_a) THEN
    RAISE EXCEPTION 'case 2: a1 must be tagged with the reused account-A tag';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM contact_tags WHERE contact_id = v_b1 AND tag_id = v_tag_b) THEN
    RAISE EXCEPTION 'case 2: b1 must be tagged with the tag created for account B';
  END IF;
  IF EXISTS (SELECT 1 FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id
              WHERE ct.contact_id = v_a2 AND reseller_tag_name_matches(t.name)) THEN
    RAISE EXCEPTION 'case 2: an inactive allow-list row must not tag its contact';
  END IF;
  IF (SELECT count(*) FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id
       WHERE ct.contact_id = v_a3 AND reseller_tag_name_matches(t.name)) <> 1 THEN
    RAISE EXCEPTION 'case 2: an already-tagged contact must stay idempotent';
  END IF;

  -- audit: one row for the created tag, one per created link, nothing else
  IF (SELECT count(*) FROM remittance_admin_audit
       WHERE action = 'migration_reseller_tag_added' AND table_name = 'tags'
         AND actor = 'migration:395_reseller_identity') <> 1
     OR NOT EXISTS (SELECT 1 FROM remittance_admin_audit
                     WHERE action = 'migration_reseller_tag_added' AND table_name = 'tags'
                       AND row_id = v_tag_b AND after ->> 'created' = 'true'
                       AND after ->> 'name' = 'Revendedor') THEN
    RAISE EXCEPTION 'case 2: the created tag must leave one tags audit row';
  END IF;
  IF (SELECT count(*) FROM remittance_admin_audit
       WHERE action = 'migration_reseller_tag_added' AND table_name = 'contact_tags') <> 2
     OR NOT EXISTS (SELECT 1 FROM remittance_admin_audit
                     WHERE action = 'migration_reseller_tag_added' AND table_name = 'contact_tags'
                       AND after ->> 'contact_id' = v_a1::text AND after ->> 'phone' = '59903951001')
     OR NOT EXISTS (SELECT 1 FROM remittance_admin_audit
                     WHERE action = 'migration_reseller_tag_added' AND table_name = 'contact_tags'
                       AND after ->> 'contact_id' = v_b1::text AND after ->> 'phone' = '59903951004') THEN
    RAISE EXCEPTION 'case 2: one contact_tags audit row per created link (a1 and b1), got %',
      (SELECT count(*) FROM remittance_admin_audit WHERE action = 'migration_reseller_tag_added' AND table_name = 'contact_tags');
  END IF;

  -- ---- 2b. idempotence: a second run creates nothing and audits nothing ----
  SELECT (SELECT count(*) FROM tags WHERE reseller_tag_name_matches(name)),
         (SELECT count(*) FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id WHERE reseller_tag_name_matches(t.name)),
         (SELECT count(*) FROM remittance_admin_audit WHERE action = 'migration_reseller_tag_added')
    INTO v_before_tags, v_before_links, v_before_audit;
  v_result := _reseller_backfill_allow_list();
  IF (v_result ->> 'tags_created')::int <> 0 OR (v_result ->> 'links_created')::int <> 0 THEN
    RAISE EXCEPTION 'case 2b: a second backfill must create nothing, got %', v_result;
  END IF;
  IF (SELECT count(*) FROM tags WHERE reseller_tag_name_matches(name)) <> v_before_tags
     OR (SELECT count(*) FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id WHERE reseller_tag_name_matches(t.name)) <> v_before_links
     OR (SELECT count(*) FROM remittance_admin_audit WHERE action = 'migration_reseller_tag_added') <> v_before_audit THEN
    RAISE EXCEPTION 'case 2b: a second backfill changed tags, links or audit rows';
  END IF;
  RAISE NOTICE 'PASS 2: backfill tags active phones, reuses an account tag, creates one where missing, ignores inactive rows, is idempotent and audits each created tag/link';

  -- ---- 3. account scoping ----
  IF reseller_contact_is_tagged(v_b2) IS TRUE THEN
    RAISE EXCEPTION 'case 3: a matching tag in account A must not make a contact of account B a reseller';
  END IF;
  RAISE NOTICE 'PASS 3: a matching tag from another account does not count';

  -- ---- 4. bot parity: new function vs the old inline allow-list rule ----
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user_a, v_acc_a, v_a1) RETURNING id INTO v_conv_a1;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user_a, v_acc_a, v_a2) RETURNING id INTO v_conv_a2;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user_a, v_acc_a, v_a3) RETURNING id INTO v_conv_a3;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user_b, v_acc_b, v_b1) RETURNING id INTO v_conv_b1;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user_b, v_acc_b, v_b2) RETURNING id INTO v_conv_b2;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user_a, v_acc_a, v_untagged) RETURNING id INTO v_conv_u;

  IF cerebro_es_revendedor(v_conv_a1) IS NOT TRUE
     OR cerebro_es_revendedor(v_conv_a3) IS NOT TRUE
     OR cerebro_es_revendedor(v_conv_b1) IS NOT TRUE THEN
    RAISE EXCEPTION 'case 4: the tagged allow-list contacts must be resellers for the bot';
  END IF;
  IF cerebro_es_revendedor(v_conv_a2) IS TRUE
     OR cerebro_es_revendedor(v_conv_b2) IS TRUE
     OR cerebro_es_revendedor(v_conv_u) IS TRUE THEN
    RAISE EXCEPTION 'case 4: inactive-allow-list, other-account and untagged contacts must not be resellers';
  END IF;

  -- old rule computed inline (the allow-list was never changed): every
  -- conversation that was a reseller must still be one
  FOR v_old, v_new IN
    SELECT EXISTS (SELECT 1 FROM conversations v JOIN contacts c ON c.id = v.contact_id
                    JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
                   WHERE v.id = x.id),
           cerebro_es_revendedor(x.id)
      FROM conversations x
     WHERE x.contact_id IN (v_a1, v_a2, v_a3, v_b1, v_b2, v_untagged)
  LOOP
    IF v_old AND NOT v_new THEN
      RAISE EXCEPTION 'case 4: a conversation that was a reseller under the allow-list stopped being one';
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM conversations v JOIN contacts c ON c.id = v.contact_id
              JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
             WHERE NOT cerebro_es_revendedor(v.id)) THEN
    RAISE EXCEPTION 'case 4: the migration''s own "no reseller lost" check does not hold';
  END IF;
  RAISE NOTICE 'PASS 4: bot parity holds for every fixture conversation and no allow-list reseller is lost';

  -- ---- 5. duplicates yield one reseller; untagging stops it ----
  INSERT INTO tags (user_id, account_id, name) VALUES (v_user_a, v_acc_a, '  REVENDEDOR  ') RETURNING id INTO v_dup_tag;
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_a1, v_dup_tag);
  IF cerebro_es_revendedor(v_conv_a1) IS NOT TRUE THEN
    RAISE EXCEPTION 'case 5: a duplicate matching tag must still make the contact one reseller';
  END IF;
  IF (SELECT count(DISTINCT c.id) FROM contacts c
        JOIN contact_tags ct ON ct.contact_id = c.id
        JOIN tags t ON t.id = ct.tag_id
       WHERE c.id = v_a1 AND t.account_id = c.account_id AND reseller_tag_name_matches(t.name)) <> 1 THEN
    RAISE EXCEPTION 'case 5: duplicate tags must not duplicate the reseller';
  END IF;
  DELETE FROM contact_tags ct USING tags t
   WHERE ct.tag_id = t.id AND ct.contact_id = v_a1 AND reseller_tag_name_matches(t.name);
  IF cerebro_es_revendedor(v_conv_a1) IS TRUE THEN
    RAISE EXCEPTION 'case 5: an untagged contact must stop being a reseller';
  END IF;
  RAISE NOTICE 'PASS 5: duplicate matching tags yield one reseller; untagging stops reseller status';

  -- ---- 6. privileges, deprecation marker and audit actions ----
  IF has_function_privilege('anon', 'public.reseller_tag_name_matches(text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.reseller_tag_name_matches(text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.reseller_contact_is_tagged(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.reseller_contact_is_tagged(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 6: the helpers must not be executable by anon or authenticated';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.cerebro_es_revendedor(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_es_revendedor(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_es_revendedor(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 6: cerebro_es_revendedor must keep the 109 ACL (service_role only)';
  END IF;
  IF coalesce(obj_description('public.cerebro_revendedores'::regclass, 'pg_class'), '') NOT LIKE '%DEPRECATED%' THEN
    RAISE EXCEPTION 'case 6: the allow-list table must carry the deprecation comment';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'remittance_admin_audit_action_chk'
                    AND pg_get_constraintdef(oid) LIKE '%migration_reseller_tag_added%'
                    AND pg_get_constraintdef(oid) LIKE '%human_reseller_counter_reset%'
                    AND pg_get_constraintdef(oid) LIKE '%human_reseller_adjustment%'
                    AND pg_get_constraintdef(oid) LIKE '%human_reseller_tag_added%'
                    AND pg_get_constraintdef(oid) LIKE '%human_reseller_tag_removed%') THEN
    RAISE EXCEPTION 'case 6: the audit action list must include the five reseller actions';
  END IF;
  RAISE NOTICE 'PASS 6: helpers closed, bot ACL unchanged, allow-list marked deprecated, audit actions present';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;

ROLLBACK;
