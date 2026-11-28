\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 250 (re-saving the payee an operation already holds does not copy it onto another one).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- Production 2026-10-19 (conversation c2bb35c0), replayed with 247-249: two receipts of 28,600 GYD for two Zelle payees.
-- "Registrar zelle auto" re-saves the accumulated payee (Santialv) on every burst; after the second receipt rule C sent that
-- re-save to the newest, empty operation, so Santialv sat on both and the real second payee (Orlansys) went to a person.
-- Rule asserted: an account that is already the vigente payee of exactly one open operation, and that the customer has not
-- typed again since it was written there, is a re-save of that operation. Typed again, the 133 behaviour holds.
-- odd/tasks/combo-negated-mention.md (C6).
-- now() is fixed inside the transaction, so every timestamp is set relative to it (T = now() is the last step).
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_t249(p_tag text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900249' || p_tag, 'test249' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.msg_t249(p_conv uuid, p_text text, p_secs_before int) RETURNS void LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (p_conv, 'customer', 'text', p_text, now() - make_interval(secs => p_secs_before));
$$;
-- what this transaction just created is moved back to its real moment
CREATE OR REPLACE FUNCTION pg_temp.age_t249(p_conv uuid, p_secs_before int) RETURNS void LANGUAGE sql AS $$
  UPDATE remittance_operations SET created_at = now() - make_interval(secs => p_secs_before)
   WHERE conversation_id = p_conv AND created_at = now();
  UPDATE remittance_beneficiaries b SET created_at = now() - make_interval(secs => p_secs_before)
    FROM remittance_operations o
   WHERE o.id = b.operation_id AND o.conversation_id = p_conv AND b.created_at = now();
$$;
CREATE OR REPLACE FUNCTION pg_temp.deposit_t249(p_conv uuid, p_ref text, p_comp text) RETURNS void LANGUAGE sql AS $$
  SELECT FROM cerebro_registrar_deposito(p_conv, 28600, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid,
    E'DEPOSITO: 28,600 GYD - EXITOSA\nVia: Agente MMG;\nRef: ' || p_ref || E'\n' || p_comp, p_comp);
$$;
-- payees per operation, oldest operation first: 'Santialv LLC|Orlansys Rodriguez'
CREATE OR REPLACE FUNCTION pg_temp.payees_t249(p_conv uuid) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(coalesce((SELECT string_agg(b.name, '+' ORDER BY b.block_index) FROM remittance_beneficiaries b
                                WHERE b.operation_id = o.id AND b.status = 'vigente'), '-'), '|' ORDER BY o.created_at)
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$$;

DO $$
DECLARE v_conv uuid;
BEGIN
  -- 1. The production sequence.
  v_conv := pg_temp.conv_t249('01');
  PERFORM pg_temp.msg_t249(v_conv, E'786-295-5183\n\nSantialv LLC \n\n⚠️NO ESCRIBIR NADA DE CUBA REMESAS NI COMBO ECT ⚠️', 98);
  PERFORM pg_temp.deposit_t249(v_conv, '10403589357209', 'COMP-ca662da243d444accfff');             -- 15:40:20
  PERFORM pg_temp.age_t249(v_conv, 86);
  PERFORM cerebro_guardar_zelle_auto(v_conv, 'Santialv LLC', '7862955183', 't249-1');                -- 15:40:40
  PERFORM pg_temp.age_t249(v_conv, 66);
  PERFORM pg_temp.deposit_t249(v_conv, '10403589323650', 'COMP-89f48f23dd6280a585d8');             -- 15:41:13
  PERFORM pg_temp.age_t249(v_conv, 33);
  PERFORM cerebro_guardar_zelle_auto(v_conv, 'Santialv LLC', '7862955183', 't249-2');                -- 15:41:13, re-save
  PERFORM pg_temp.age_t249(v_conv, 33);
  IF pg_temp.payees_t249(v_conv) <> 'Santialv LLC|-' THEN
    RAISE EXCEPTION 'case 1a: the re-save must stay on the first operation, got %', pg_temp.payees_t249(v_conv); END IF;
  PERFORM pg_temp.msg_t249(v_conv, '7043431236', 23);                                                -- 15:41:23
  PERFORM pg_temp.msg_t249(v_conv, 'Orlansys Rodríguez', 23);
  PERFORM cerebro_guardar_zelle_auto(v_conv, 'Orlansys Rodríguez', '7043431236', 't249-3');          -- 15:41:46
  IF pg_temp.payees_t249(v_conv) <> 'Santialv LLC|Orlansys Rodríguez' THEN
    RAISE EXCEPTION 'case 1b: each payee must sit on its own operation, got %', pg_temp.payees_t249(v_conv); END IF;

  -- 2. Typed again after it was saved, the same account is a new remesa's payee (133 unchanged): rule C takes the newest.
  v_conv := pg_temp.conv_t249('02');
  PERFORM pg_temp.msg_t249(v_conv, 'Zelle 7862955183 Santialv LLC', 200);
  PERFORM pg_temp.deposit_t249(v_conv, '10403589357301', 'COMP-249aaaaaaaaaaaaaaaa1');
  PERFORM pg_temp.age_t249(v_conv, 190);
  PERFORM cerebro_guardar_zelle_auto(v_conv, 'Santialv LLC', '7862955183', 't249-4');
  PERFORM pg_temp.age_t249(v_conv, 180);
  PERFORM pg_temp.deposit_t249(v_conv, '10403589357302', 'COMP-249aaaaaaaaaaaaaaaa2');
  PERFORM pg_temp.age_t249(v_conv, 30);
  PERFORM pg_temp.msg_t249(v_conv, 'el segundo tambien a Santialv LLC 7862955183', 10);
  PERFORM cerebro_guardar_zelle_auto(v_conv, 'Santialv LLC', '7862955183', 't249-5');
  IF pg_temp.payees_t249(v_conv) <> 'Santialv LLC|Santialv LLC' THEN
    RAISE EXCEPTION 'case 2: an account typed again must go to the new operation, got %', pg_temp.payees_t249(v_conv); END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
