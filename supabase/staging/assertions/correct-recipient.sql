\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 284 (gestionar_beneficiario = cerebro_guardar_beneficiario corrects ONE recipient by position / type, and
-- validates the operation the bot names).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Synthetic fixtures only: contacts 'PRUEBA corregir N', phones 5990284xxxx, fake cards 99990000000000nn.
-- Cases (number = label in the failure message):
--   1  a reparto of two cards: name of position 2 only; the card of position 1 only (phone kept); the other slot is untouched
--   2  a card that already belongs to another recipient is refused; an unknown position lists the recipients; no position with two recipients asks
--   3  a single card recipient + tipo tarjeta: name only; the same data again = sin cambios
--   4  a Zelle recipient by tipo zelle: the holder name is corrected; a card or phone is refused naming registrar_beneficiario_zelle
--   5  p_op: card data goes to the named operation (a planned CUP part) while another operation is open; an operation of another
--      conversation and a closed one are refused, nothing written
--   6  recipients locked by a person: refused
--   7  without position / type the old behaviour is untouched (single recipient write)
-- =====================================================================
CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990284' || lpad(p_n::text, 4, '0'), 'PRUEBA corregir ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.p_plan(p_conv uuid) RETURNS jsonb
LANGUAGE sql AS $f$ SELECT cerebro_resolver_servicio(p_conv) -> 'reparto_planeado'; $f$;

-- a deposit that is verified: MMG row in the ledger + registrar + cruce (same as split-deposit-minimums)

CREATE FUNCTION pg_temp.p_gb(p_conv uuid, p_nombre text, p_tarjeta text, p_celular text, p_pos int, p_tipo text, p_op uuid DEFAULT NULL) RETURNS text
LANGUAGE sql AS $f$
  SELECT accion FROM cerebro_guardar_beneficiario(p_conv, p_nombre, p_tarjeta, p_celular, 'q284', p_op, 'gestionar_beneficiario', p_pos, p_tipo);
$f$;

CREATE FUNCTION pg_temp.p_bens(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(b.position || ':' || coalesce(b.name, '-') || ':' || coalesce(b.card_number, coalesce(b.zelle_account, '-')) || ':' || coalesce(b.phone, '-'), ' | ' ORDER BY o.created_at, b.position),'')
    FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = p_conv AND b.status = 'vigente';
$f$;

DO $$
DECLARE
  c record; a text; v_op uuid; v_op2 uuid; c2 record;
BEGIN
  -- 1 reparto of two cards
  SELECT * INTO c FROM pg_temp.p_conv(1);
  PERFORM cerebro_guardar_reparto(c.conv, '9999000000000008', '53821203', '5000', '9999000000000016', '53821204', '5000', '', '', '', 'q1a');
  PERFORM pg_temp.p_eq('1 two slots', (SELECT count(*)::text FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = c.conv AND b.status = 'vigente'), '2');
  a := pg_temp.p_gb(c.conv, 'Ana Perez', NULL, NULL, 2, NULL);
  PERFORM pg_temp.p_eq('1 name of 2', (a LIKE 'corregido (destinatario 2 de 2): nombre Ana Perez%')::text, 'true');
  PERFORM pg_temp.p_eq('1 slot 1 untouched', (SELECT coalesce(b.name, '-') || ':' || b.card_number || ':' || b.phone FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
                                              WHERE o.conversation_id = c.conv AND b.status = 'vigente' AND b.position = 1), '-:9999000000000008:53821203');
  PERFORM pg_temp.p_eq('1 slot 2 name', (SELECT b.name FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = c.conv AND b.status = 'vigente' AND b.position = 2), 'Ana Perez');
  a := pg_temp.p_gb(c.conv, NULL, '9999000000000024', NULL, 1, NULL);
  PERFORM pg_temp.p_eq('1 card of 1', (a LIKE 'corregido (destinatario 1 de 2): tarjeta 9999000000000024%')::text, 'true');
  PERFORM pg_temp.p_eq('1 phone kept', (SELECT b.card_number || ':' || b.phone FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = c.conv AND b.status = 'vigente' AND b.position = 1), '9999000000000024:53821203');
  PERFORM pg_temp.p_eq('1 audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE action = 'agent_beneficiary_corrected' AND actor = 'agent:gestionar_beneficiario n8n:q284'), '2');

  -- 2 refusals
  a := pg_temp.p_gb(c.conv, NULL, '9999000000000016', NULL, 1, NULL);
  PERFORM pg_temp.p_eq('2 duplicate card', (a LIKE 'NO SE GUARDO NADA: esa tarjeta ya es de otro destinatario%')::text, 'true');
  a := pg_temp.p_gb(c.conv, 'Luis', NULL, NULL, 5, NULL);
  PERFORM pg_temp.p_eq('2 unknown position', (a LIKE 'NO SE GUARDO NADA: no hay un destinatario en la posicion 5. Hay 2:%1)%2)%')::text, 'true');
  a := pg_temp.p_gb(c.conv, 'Luis', NULL, NULL, NULL, 'tarjeta');
  PERFORM pg_temp.p_eq('2 which one', (a LIKE 'NO SE GUARDO NADA: hay 2 destinatarios%Indica la posicion%')::text, 'true');
  PERFORM pg_temp.p_eq('2 nothing written', (SELECT b.name FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = c.conv AND b.status = 'vigente' AND b.position = 1) IS NULL::text, 'true');

  -- 3 a single card recipient
  SELECT * INTO c FROM pg_temp.p_conv(2);
  PERFORM cerebro_guardar_beneficiario(c.conv, 'Mario Gil', '9999000000000008', '53821203', 'q3a');
  a := pg_temp.p_gb(c.conv, 'Mario Gil Vega', NULL, NULL, NULL, 'tarjeta');
  PERFORM pg_temp.p_eq('3 name only', (a LIKE 'corregido (destinatario 1 de 1): nombre Mario Gil Vega%')::text || '/' || pg_temp.p_bens(c.conv), 'true/1:Mario Gil Vega:9999000000000008:53821203');
  a := pg_temp.p_gb(c.conv, 'Mario Gil Vega', NULL, NULL, NULL, 'tarjeta');
  PERFORM pg_temp.p_eq('3 same data', (a LIKE 'sin cambios:%')::text, 'true');

  -- 4 Zelle holder
  SELECT * INTO c FROM pg_temp.p_conv(3);
  PERFORM cerebro_guardar_zelle(c.conv, 'Marta Gil', 'marta.gil@example.com', 'q4a');
  a := pg_temp.p_gb(c.conv, 'Marta Gil Vega', NULL, NULL, NULL, 'zelle');
  PERFORM pg_temp.p_eq('4 holder', (a LIKE 'corregido (destinatario 1 de 1): nombre Marta Gil Vega%')::text || '/' || pg_temp.p_bens(c.conv), 'true/1:Marta Gil Vega:marta.gil@example.com:-');
  a := pg_temp.p_gb(c.conv, NULL, '9999000000000008', NULL, NULL, 'zelle');
  PERFORM pg_temp.p_eq('4 card on a zelle', (a LIKE 'NO SE GUARDO NADA:%registrar_beneficiario_zelle%')::text, 'true');

  -- 5 p_op
  SELECT * INTO c FROM pg_temp.p_conv(4);
  PERFORM cerebro_repartir_envio(c.conv, 'zelle 20000, cup 6000', 'q5a');
  SELECT id INTO v_op FROM remittance_operations WHERE conversation_id = c.conv AND cerebro_riel_op(id) = 'cuban_card';
  a := pg_temp.p_gb(c.conv, 'Luisa Gonzalez', '9999000000000008', '53821203', NULL, NULL, v_op);
  PERFORM pg_temp.p_eq('5 lands on the named operation', (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND card_number = '9999000000000008'), '1');
  SELECT * INTO c2 FROM pg_temp.p_conv(5);
  a := pg_temp.p_gb(c2.conv, 'Luisa Gonzalez', '9999000000000016', '53821204', NULL, NULL, v_op);
  PERFORM pg_temp.p_eq('5 other conversation', (a LIKE 'NO SE GUARDO NADA: esa operacion no es de esta conversacion%')::text || '/' || pg_temp.p_bens(c2.conv), 'true/');
  UPDATE remittance_operations SET status = 'cancelled', cancelled_at = now() WHERE id = v_op;
  a := pg_temp.p_gb(c.conv, 'Luisa Gonzalez', '9999000000000016', '53821204', NULL, NULL, v_op);
  PERFORM pg_temp.p_eq('5 closed operation', (a LIKE 'NO SE GUARDO NADA: esa operacion no es de esta conversacion o ya no esta abierta%')::text, 'true');

  -- 6 lock
  SELECT * INTO c FROM pg_temp.p_conv(6);
  PERFORM cerebro_guardar_beneficiario(c.conv, 'Mario Gil', '9999000000000008', '53821203', 'q6a');
  SELECT id INTO v_op FROM remittance_operations WHERE conversation_id = c.conv;
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('beneficiaries', jsonb_build_object('by', '11111111-1111-1111-1111-111111111111', 'at', now())) WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  a := pg_temp.p_gb(c.conv, 'Otro Nombre', NULL, NULL, 1, NULL);
  PERFORM pg_temp.p_eq('6 locked', (a LIKE 'NO SE GUARDO NADA: los destinatarios de este envio los fijo una persona%')::text, 'true');

  -- 7 old behaviour
  SELECT * INTO c FROM pg_temp.p_conv(7);
  SELECT accion INTO a FROM cerebro_guardar_beneficiario(c.conv, 'Mario Gil', '9999000000000008', '53821203', 'q7a');
  PERFORM pg_temp.p_eq('7 old write', (a LIKE 'guardado: tarjeta 9999000000000008, celular 53821203, nombre Mario Gil%Completo.')::text, 'true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
