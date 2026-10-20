\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for the "Contexto conversacion" node query (n8n inline SQL): the envio_mixto column added in S6.
-- The fragment inside each query below is the EXACT text appended to the node query, before FROM conversations v.
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs.
-- Rule asserted: a conversation with a mixed group returns {total, partes[{servicio, monto_gyd, destino, moneda, status}]}
-- of its OPEN members (cancelled/completed excluded), with the destination amount when the operation has one; an
-- ungrouped conversation, and a group left with a single open member, return NULL.
-- odd/tasks/mixed-send-split-deposit.md (S6).
-- =====================================================================

DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid; v_rem uuid; v_rec uuid; v_ct2 uuid; v_cv2 uuid; v_r jsonb;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_user, '59902560001', 'T256 a', v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_user, '59902560002', 'T256 b', v_acc) RETURNING id INTO v_ct2;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_user, v_ct2, v_acc) RETURNING id INTO v_cv2;
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount, destination_currency, quoted_destination_amount)
  VALUES (gen_random_uuid(), v_acc, v_cv, v_ct, 'ready_to_transfer', 'remesa', 'clasica', 'GYD', 18200, 'USD', 70) RETURNING id INTO v_rem;
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, source_currency,
                                     quoted_source_amount, mixed_group_id)
  VALUES (gen_random_uuid(), v_acc, v_cv, v_ct, 'collecting_information', 'recarga', 'GYD', 6200, v_rem) RETURNING id INTO v_rec;
  UPDATE remittance_operations SET mixed_group_id = v_rem WHERE id = v_rem;
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_acc, v_cv2, v_ct2, 'collecting_information', 'remesa', 'clasica', 'GYD', 5000);

  -- 1. grouped conversation: total and both parts, in creation order, destination only where the operation has one
  SELECT x.envio_mixto INTO v_r FROM (SELECT v.id,
-- ENVIO MIXTO (S6, 253): the open operations grouped by remittance_operations.mixed_group_id for this conversation
-- (one deposit split across services). NULL when there is no group or fewer than 2 open members. Servicio = the
-- operation's rail (cerebro_riel_op). No semicolons and no backslashes here on purpose (the n8n Postgres node splits on
-- semicolons).
(SELECT jsonb_build_object(
          'total', sum(g.quoted_source_amount),
          'partes', jsonb_agg(jsonb_build_object(
              'servicio', cerebro_riel_op(g.id), 'monto_gyd', g.quoted_source_amount,
              'destino', g.quoted_destination_amount, 'moneda', g.destination_currency, 'status', g.status)
            ORDER BY g.created_at, g.id))
   FROM remittance_operations g
  WHERE g.mixed_group_id = (SELECT a.mixed_group_id FROM remittance_operations a
                             WHERE a.conversation_id = v.id AND a.mixed_group_id IS NOT NULL
                               AND a.status NOT IN ('completed','cancelled')
                             ORDER BY a.created_at DESC LIMIT 1)
    AND g.status NOT IN ('completed','cancelled')
 HAVING count(*) >= 2) AS envio_mixto FROM conversations v WHERE v.id = v_cv) x;
  IF v_r IS NULL THEN RAISE EXCEPTION 'FAIL 1: grouped conversation returned NULL'; END IF;
  IF (v_r->>'total')::numeric <> 24400 THEN RAISE EXCEPTION 'FAIL 1b: total %', v_r->>'total'; END IF;
  IF jsonb_array_length(v_r->'partes') <> 2 THEN RAISE EXCEPTION 'FAIL 1c: parts %', v_r->'partes'; END IF;
  IF v_r->'partes'->0->>'servicio' <> 'clasica' OR (v_r->'partes'->0->>'monto_gyd')::numeric <> 18200
     OR (v_r->'partes'->0->>'destino')::numeric <> 70 OR v_r->'partes'->0->>'moneda' <> 'USD'
     OR v_r->'partes'->0->>'status' <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'FAIL 1d: first part %', v_r->'partes'->0;
  END IF;
  IF v_r->'partes'->1->>'servicio' <> 'recarga' OR (v_r->'partes'->1->>'monto_gyd')::numeric <> 6200
     OR (v_r->'partes'->1->'destino') <> 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL 1e: second part %', v_r->'partes'->1;
  END IF;

  -- 2. an ungrouped conversation returns NULL
  SELECT x.envio_mixto INTO v_r FROM (SELECT v.id,
-- ENVIO MIXTO (S6, 253): the open operations grouped by remittance_operations.mixed_group_id for this conversation
-- (one deposit split across services). NULL when there is no group or fewer than 2 open members. Servicio = the
-- operation's rail (cerebro_riel_op). No semicolons and no backslashes here on purpose (the n8n Postgres node splits on
-- semicolons).
(SELECT jsonb_build_object(
          'total', sum(g.quoted_source_amount),
          'partes', jsonb_agg(jsonb_build_object(
              'servicio', cerebro_riel_op(g.id), 'monto_gyd', g.quoted_source_amount,
              'destino', g.quoted_destination_amount, 'moneda', g.destination_currency, 'status', g.status)
            ORDER BY g.created_at, g.id))
   FROM remittance_operations g
  WHERE g.mixed_group_id = (SELECT a.mixed_group_id FROM remittance_operations a
                             WHERE a.conversation_id = v.id AND a.mixed_group_id IS NOT NULL
                               AND a.status NOT IN ('completed','cancelled')
                             ORDER BY a.created_at DESC LIMIT 1)
    AND g.status NOT IN ('completed','cancelled')
 HAVING count(*) >= 2) AS envio_mixto FROM conversations v WHERE v.id = v_cv2) x;
  IF v_r IS NOT NULL THEN RAISE EXCEPTION 'FAIL 2: ungrouped conversation returned %', v_r; END IF;

  -- 3. a cancelled member is not listed, and a group left with one open member returns NULL
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_rec;
  SELECT x.envio_mixto INTO v_r FROM (SELECT v.id,
-- ENVIO MIXTO (S6, 253): the open operations grouped by remittance_operations.mixed_group_id for this conversation
-- (one deposit split across services). NULL when there is no group or fewer than 2 open members. Servicio = the
-- operation's rail (cerebro_riel_op). No semicolons and no backslashes here on purpose (the n8n Postgres node splits on
-- semicolons).
(SELECT jsonb_build_object(
          'total', sum(g.quoted_source_amount),
          'partes', jsonb_agg(jsonb_build_object(
              'servicio', cerebro_riel_op(g.id), 'monto_gyd', g.quoted_source_amount,
              'destino', g.quoted_destination_amount, 'moneda', g.destination_currency, 'status', g.status)
            ORDER BY g.created_at, g.id))
   FROM remittance_operations g
  WHERE g.mixed_group_id = (SELECT a.mixed_group_id FROM remittance_operations a
                             WHERE a.conversation_id = v.id AND a.mixed_group_id IS NOT NULL
                               AND a.status NOT IN ('completed','cancelled')
                             ORDER BY a.created_at DESC LIMIT 1)
    AND g.status NOT IN ('completed','cancelled')
 HAVING count(*) >= 2) AS envio_mixto FROM conversations v WHERE v.id = v_cv) x;
  IF v_r IS NOT NULL THEN RAISE EXCEPTION 'FAIL 3: one open member returned %', v_r; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;

ROLLBACK;
