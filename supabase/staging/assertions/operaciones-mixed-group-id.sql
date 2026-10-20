\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 254: crm_operaciones_de_conversacion returns operation_mixed_group_id.
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- Rule asserted: the two operations of a mixed send (253) come back with the same group id (the anchor's id); an
-- ungrouped operation comes back with NULL.
-- odd/tasks/mixed-send-split-deposit.md (S2).
-- =====================================================================

DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid; v_rem uuid; v_rec uuid; v_lone uuid; v_cv2 uuid; v_ct2 uuid;
  v_grp int; v_n int; v_r record;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '59902540001', 'T254 a', v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '59902540002', 'T254 b', v_acc) RETURNING id INTO v_ct2;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct2, v_acc) RETURNING id INTO v_cv2;

  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_acc, v_cv, v_ct, 'collecting_information', 'remesa', 'clasica', 'GYD', 18200)
  RETURNING id INTO v_rem;
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, source_currency,
                                     quoted_source_amount, mixed_group_id)
  VALUES (gen_random_uuid(), v_acc, v_cv, v_ct, 'collecting_information', 'recarga', 'GYD', 6200, v_rem)
  RETURNING id INTO v_rec;
  UPDATE remittance_operations SET mixed_group_id = v_rem WHERE id = v_rem;
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_acc, v_cv2, v_ct2, 'collecting_information', 'remesa', 'clasica', 'GYD', 5000)
  RETURNING id INTO v_lone;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1. both members of the pair carry the anchor's id
  SELECT count(DISTINCT operation_id), count(DISTINCT operation_mixed_group_id) FILTER (WHERE operation_mixed_group_id = v_rem)
    INTO v_n, v_grp FROM crm_operaciones_de_conversacion(v_cv) WHERE operation_id IN (v_rem, v_rec);
  IF v_n <> 2 OR v_grp <> 1 THEN RAISE EXCEPTION 'FAIL 1: pair returns % ops / % group ids', v_n, v_grp; END IF;
  IF EXISTS (SELECT 1 FROM crm_operaciones_de_conversacion(v_cv)
              WHERE operation_id IN (v_rem, v_rec) AND operation_mixed_group_id IS DISTINCT FROM v_rem) THEN
    RAISE EXCEPTION 'FAIL 1b: a member did not return the anchor id';
  END IF;

  -- 2. an ungrouped operation returns NULL
  SELECT * INTO v_r FROM crm_operaciones_de_conversacion(v_cv2) WHERE operation_id = v_lone;
  IF v_r.operation_id IS NULL THEN RAISE EXCEPTION 'FAIL 2: ungrouped operation missing'; END IF;
  IF v_r.operation_mixed_group_id IS NOT NULL THEN RAISE EXCEPTION 'FAIL 2b: ungrouped operation has a group id'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;

ROLLBACK;
