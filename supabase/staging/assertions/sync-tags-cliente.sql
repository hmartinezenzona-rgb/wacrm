-- Assertion for the live sync_tags_cliente body (168, captured from the
-- catalog because 172 retired the deal triggers the old harness needed).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
--
--   1 zero completed operations -> Nuevo
--   2 one completed operation  -> Cliente, Nuevo removed
--   3 three completed           -> Recurrentes, Cliente removed
--   4 an Admin-tagged contact keeps its tags and gains none
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
  v_nuevo uuid; v_cliente uuid; v_rec uuid; v_admin uuid;
  v_tags text;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'fixture: no conversation to borrow user/account'; END IF;

  SELECT id INTO v_nuevo   FROM tags WHERE lower(name) = 'nuevo'       LIMIT 1;
  SELECT id INTO v_cliente FROM tags WHERE lower(name) = 'cliente'     LIMIT 1;
  SELECT id INTO v_rec     FROM tags WHERE lower(name) = 'recurrentes' LIMIT 1;
  SELECT id INTO v_admin   FROM tags WHERE lower(name) = 'admin'       LIMIT 1;
  IF v_nuevo IS NULL OR v_cliente IS NULL OR v_rec IS NULL OR v_admin IS NULL THEN
    RAISE EXCEPTION 'fixture: missing one of the nuevo/cliente/recurrentes/admin tags';
  END IF;

  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '59900168001', 'test168 sync') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  -- 1. No completed operations yet.
  PERFORM sync_tags_cliente(v_ct);
  IF NOT EXISTS (SELECT 1 FROM contact_tags WHERE contact_id = v_ct AND tag_id = v_nuevo) THEN
    RAISE EXCEPTION 'case 1: a contact with no delivered operations must be Nuevo';
  END IF;
  RAISE NOTICE 'PASS 1: zero delivered operations -> Nuevo';

  -- 2. One completed operation. A person completes from the panel: the
  --    automation guard coerces an insert marked as automation to incident.
  PERFORM set_config('wacrm.origin', 'admin', true);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, completed_at)
  VALUES (v_acc, v_conv, v_ct, 'completed', 'remesa', 'GYD', 1000, now());
  PERFORM sync_tags_cliente(v_ct);
  IF NOT EXISTS (SELECT 1 FROM contact_tags WHERE contact_id = v_ct AND tag_id = v_cliente)
     OR EXISTS (SELECT 1 FROM contact_tags WHERE contact_id = v_ct AND tag_id = v_nuevo) THEN
    RAISE EXCEPTION 'case 2: one delivered operation must leave Cliente and remove Nuevo';
  END IF;
  RAISE NOTICE 'PASS 2: one delivered operation -> Cliente';

  -- 3. Three completed operations.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, completed_at)
  VALUES (v_acc, v_conv, v_ct, 'completed', 'remesa', 'GYD', 1000, now()),
         (v_acc, v_conv, v_ct, 'completed', 'remesa', 'GYD', 1000, now());
  PERFORM sync_tags_cliente(v_ct);
  IF NOT EXISTS (SELECT 1 FROM contact_tags WHERE contact_id = v_ct AND tag_id = v_rec)
     OR EXISTS (SELECT 1 FROM contact_tags WHERE contact_id = v_ct AND tag_id = v_cliente) THEN
    RAISE EXCEPTION 'case 3: three delivered operations must leave Recurrentes and remove Cliente';
  END IF;
  RAISE NOTICE 'PASS 3: three delivered operations -> Recurrentes';

  -- 4. Admin is a short-circuit: the tags it already has do not change.
  SELECT string_agg(t.name, ',' ORDER BY t.name) INTO v_tags
    FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id
   WHERE ct.contact_id = v_ct AND ct.tag_id <> v_admin;
  INSERT INTO contact_tags (id, contact_id, tag_id) VALUES (gen_random_uuid(), v_ct, v_admin);
  PERFORM sync_tags_cliente(v_ct);
  IF (SELECT string_agg(t.name, ',' ORDER BY t.name)
        FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id
       WHERE ct.contact_id = v_ct AND ct.tag_id <> v_admin) IS DISTINCT FROM v_tags THEN
    RAISE EXCEPTION 'case 4: an Admin-tagged contact changed its other tags';
  END IF;
  RAISE NOTICE 'PASS 4: Admin short-circuits';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
