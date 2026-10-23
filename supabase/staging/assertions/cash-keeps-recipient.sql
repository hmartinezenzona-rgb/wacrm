\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 286 (cambiar_servicio to efectivo_usd keeps / opens the cash recipient and says what is missing).
-- Self-reverting. Synthetic fixtures: contacts 'PRUEBA efectivo N', phones 5990286xxxx, fake card 9999000000000008.
-- Cases:
--   1  card recipient with name + phone -> cash: the card retires, ONE efectivo_usd recipient (name + phone) is in force, the answer says only the address is missing
--   2  card recipient with a phone only -> cash recipient with the phone; the answer says the address is missing and does not ask for the phone
--   3  Zelle recipient with a name only -> cash recipient with the name; the answer asks for phone and address
--   4  card with neither name nor phone -> no cash recipient invented; the answer says nothing is known about who receives
--   5  registrar_datos_entrega_efectivo then completes the SAME recipient (still one in force, address stored, complete)
--   6  an operation that already has a cash recipient is not touched by a second conversion attempt (sin_cambio)
-- =====================================================================
CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990286' || lpad(p_n::text, 4, '0'), 'PRUEBA efectivo ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;


CREATE FUNCTION pg_temp.p_efec(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(b.beneficiary_type || ':' || coalesce(b.name, '-') || ':' || coalesce(b.phone, '-') || ':' || coalesce(b.address, '-'), ' | ' ORDER BY b.beneficiary_type), '')
    FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = p_conv AND b.status = 'vigente';
$f$;

DO $$
DECLARE c record; r jsonb; j jsonb;
BEGIN
  -- 1
  SELECT * INTO c FROM pg_temp.p_conv(1);
  PERFORM cerebro_guardar_beneficiario(c.conv, 'Rosa Gomez', '9999000000000008', '53821203', 'e1a');
  r := cerebro_aplicar_servicio(c.conv, 'efectivo', 'cambiar', 'agent:cambiar_servicio', 'e1b');
  PERFORM pg_temp.p_eq('1 applied', (r ->> 'aplicado') || '/' || (SELECT cerebro_riel_op(id) FROM remittance_operations WHERE conversation_id = c.conv), 'true/efectivo_usd');
  PERFORM pg_temp.p_eq('1 one cash recipient with the data', pg_temp.p_efec(c.conv), 'efectivo_usd:Rosa Gomez:53821203:-');
  PERFORM pg_temp.p_eq('1 card retired', (SELECT count(*)::text FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = c.conv AND b.status = 'reemplazado' AND b.card_number IS NOT NULL), '1');
  PERFORM pg_temp.p_eq('1 message', (r ->> 'mensaje' LIKE '%Ya tengo el nombre Rosa Gomez y el celular 53821203; falta la direcci_n en Cuba.')::text, 'true');

  -- 5 completes the same recipient
  j := crm_registrar_datos_entrega_efectivo(c.conv, NULL, 'Calle 10 numero 5, Bayamo', NULL, NULL);
  PERFORM pg_temp.p_eq('5 same recipient completed', pg_temp.p_efec(c.conv), 'efectivo_usd:Rosa Gomez:53821203:Calle 10 numero 5, Bayamo');

  -- 6 second attempt
  r := cerebro_aplicar_servicio(c.conv, 'efectivo', 'cambiar', 'agent:cambiar_servicio', 'e1c');
  PERFORM pg_temp.p_eq('6 nothing to change', (r ->> 'aplicado') || '/' || (r ->> 'motivo'), 'false/sin_cambio');
  PERFORM pg_temp.p_eq('6 recipient untouched', pg_temp.p_efec(c.conv), 'efectivo_usd:Rosa Gomez:53821203:Calle 10 numero 5, Bayamo');

  -- 2 phone only
  SELECT * INTO c FROM pg_temp.p_conv(2);
  PERFORM cerebro_guardar_beneficiario(c.conv, NULL, '9999000000000008', '53821204', 'e2a');
  r := cerebro_aplicar_servicio(c.conv, 'efectivo', 'cambiar', 'agent:cambiar_servicio', 'e2b');
  PERFORM pg_temp.p_eq('2 phone carried', pg_temp.p_efec(c.conv), 'efectivo_usd:-:53821204:-');
  PERFORM pg_temp.p_eq('2 message', (r ->> 'mensaje' LIKE '%Ya tengo el celular 53821204; falta la direcci_n en Cuba.')::text, 'true');

  -- 3 zelle, name only
  SELECT * INTO c FROM pg_temp.p_conv(3);
  PERFORM cerebro_guardar_zelle(c.conv, 'Marta Gil', 'marta@example.com', 'e3a');
  r := cerebro_aplicar_servicio(c.conv, 'efectivo', 'cambiar', 'agent:cambiar_servicio', 'e3b');
  PERFORM pg_temp.p_eq('3 name carried', pg_temp.p_efec(c.conv), 'efectivo_usd:Marta Gil:-:-');
  PERFORM pg_temp.p_eq('3 message', (r ->> 'mensaje' LIKE '%Ya tengo el nombre Marta Gil; falta el celular y la direcci_n en Cuba.')::text, 'true');

  -- 4 nothing known
  SELECT * INTO c FROM pg_temp.p_conv(4);
  PERFORM cerebro_guardar_beneficiario(c.conv, NULL, '9999000000000008', NULL, 'e4a');
  r := cerebro_aplicar_servicio(c.conv, 'efectivo', 'cambiar', 'agent:cambiar_servicio', 'e4b');
  PERFORM pg_temp.p_eq('4 nothing invented', pg_temp.p_efec(c.conv), '');
  PERFORM pg_temp.p_eq('4 message', (r ->> 'mensaje' LIKE '%falta el nombre, el celular y la direcci_n en Cuba.')::text, 'true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
