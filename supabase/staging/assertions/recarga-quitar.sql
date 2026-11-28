\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 282 (registrar_numeros_recarga gains p_accion 'quitar'; no new tool).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Synthetic fixtures only: contacts 'PRUEBA quitar N', phones 5990282xxxx.
-- Cases (number = label in the failure message):
--   1  three numbers added, one removed ("quita el 55502222"): the other two stay in positions 1 and 2, the removed row is retired
--      ('reemplazado'), audit row agent_recharge_number_removed with the real actor, the answer says what remains
--   2  removing it again: nothing removed, the answer says it was not there; a different spelling (+53 5 5501111) matches
--   3  a removed number can be added back (4-argument call = 'agregar')
--   4  text without a Cuban number: nothing removed, says so
--   5  no recharge in course: nothing to remove, nothing opened
--   6  recipients locked by a person / transferring recharge: refused, nothing removed
--   7  invalid action: refused; ACL service_role only
-- =====================================================================
CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990282' || lpad(p_n::text, 4, '0'), 'PRUEBA quitar ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN v_cv;
END $f$;

CREATE FUNCTION pg_temp.p_recarga(p_conv uuid, p_status text DEFAULT 'collecting_information') RETURNS uuid
LANGUAGE sql AS $f$
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  SELECT v.account_id, v.id, v.contact_id, p_status, 'recarga', 'GYD', 0 FROM conversations v WHERE v.id = p_conv RETURNING id;
$f$;

CREATE FUNCTION pg_temp.p_nums(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(position || ':' || phone, ',' ORDER BY position), '') FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente';
$f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

DO $$
DECLARE c uuid; v_op uuid; v_r text;
BEGIN
  -- 1 remove one number of three
  c := pg_temp.p_conv(1);
  v_op := pg_temp.p_recarga(c);
  PERFORM crm_registrar_numeros_recarga(c, '55501111, 55502222 y 55503333');
  PERFORM pg_temp.p_eq('1 three numbers', pg_temp.p_nums(v_op), '1:55501111,2:55502222,3:55503333');
  v_r := crm_registrar_numeros_recarga(c, 'quita el 55502222, ya no', false, 'agent:registrar_numeros_recarga n8n:q1', 'quitar');
  PERFORM pg_temp.p_eq('1 removed', pg_temp.p_nums(v_op), '1:55501111,2:55503333');
  PERFORM pg_temp.p_eq('1 answer', (v_r LIKE 'quitados 1 numero(s) de recarga; la recarga tiene 2.%')::text, 'true');
  PERFORM pg_temp.p_eq('1 retired not deleted', (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND phone = '55502222' AND status = 'reemplazado' AND replaced_at IS NOT NULL), '1');
  PERFORM pg_temp.p_eq('1 audit', (SELECT actor FROM remittance_admin_audit WHERE row_id = v_op AND action = 'agent_recharge_number_removed'), 'agent:registrar_numeros_recarga n8n:q1');

  -- 2 again, and another spelling
  v_r := crm_registrar_numeros_recarga(c, '55502222', false, 'agent:x', 'quitar');
  PERFORM pg_temp.p_eq('2 not there', (v_r LIKE 'quitados 0 numero(s)%No estaban en la recarga: 55502222%')::text, 'true');
  v_r := crm_registrar_numeros_recarga(c, 'el +53 5 5501111', false, 'agent:x', 'quitar');
  PERFORM pg_temp.p_eq('2 other spelling', pg_temp.p_nums(v_op), '1:55503333');

  -- 3 add back
  PERFORM crm_registrar_numeros_recarga(c, '55502222');
  PERFORM pg_temp.p_eq('3 added back', pg_temp.p_nums(v_op), '1:55503333,2:55502222');

  -- 4 no number in the text
  v_r := crm_registrar_numeros_recarga(c, 'quita el segundo', false, 'agent:x', 'quitar');
  PERFORM pg_temp.p_eq('4 no number', (v_r LIKE 'no vi ningun numero cubano%')::text || '/' || pg_temp.p_nums(v_op), 'true/1:55503333,2:55502222');

  -- 5 no recharge
  c := pg_temp.p_conv(2);
  v_r := crm_registrar_numeros_recarga(c, '55501111', true, 'agent:x', 'quitar');
  PERFORM pg_temp.p_eq('5 nothing opened', (v_r LIKE 'sin recarga en curso%')::text || '/' || (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c), 'true/0');

  -- 6 locked / transferring
  c := pg_temp.p_conv(3);
  v_op := pg_temp.p_recarga(c);
  PERFORM crm_registrar_numeros_recarga(c, '55501111 55502222');
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('beneficiaries', jsonb_build_object('by', '11111111-1111-1111-1111-111111111111', 'at', now())) WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  v_r := crm_registrar_numeros_recarga(c, '55501111', false, 'agent:x', 'quitar');
  PERFORM pg_temp.p_eq('6 locked', (v_r LIKE '%gestiona una persona%')::text || '/' || pg_temp.p_nums(v_op), 'true/1:55501111,2:55502222');
  c := pg_temp.p_conv(4);
  v_op := pg_temp.p_recarga(c, 'transferring');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status) VALUES (v_op, 'recarga', '55509999', 1, 1, 'agente', 'vigente');
  v_r := crm_registrar_numeros_recarga(c, '55509999', false, 'agent:x', 'quitar');
  PERFORM pg_temp.p_eq('6 transferring', (v_r LIKE '%transferencia%')::text || '/' || pg_temp.p_nums(v_op), 'true/1:55509999');

  -- 7 invalid action, ACL
  v_r := crm_registrar_numeros_recarga(c, '55509999', false, 'agent:x', 'borrar');
  PERFORM pg_temp.p_eq('7 invalid', (v_r LIKE 'ERROR: la accion%')::text, 'true');
  PERFORM pg_temp.p_eq('7 acl', has_function_privilege('authenticated', 'crm_registrar_numeros_recarga(uuid,text,boolean,text,text)', 'EXECUTE')::text || ':' ||
                               has_function_privilege('service_role', 'crm_registrar_numeros_recarga(uuid,text,boolean,text,text)', 'EXECUTE')::text, 'false:true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
