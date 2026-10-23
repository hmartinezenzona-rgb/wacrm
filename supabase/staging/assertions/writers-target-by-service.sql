\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 276 (the agent's recipient writers target the operation of THEIR service). Self-reverting:
-- BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Synthetic fixtures only: contacts 'PRUEBA objetivo N', phones 5990276xxxx, fake cards / accounts.
-- odd/notes/db-tools-progress.md (276, gap 6 of the S5b measurement: F "clasica card landed on the recarga", M3 "cash
-- re-typed the mexico operation", and the 250 several-operations rule for the tools).
-- Cases (number = label in the failure message):
--   1  mixed send before the deposit (clasica + recarga, both empty): gestionar_beneficiario writes on the clasica one, never
--      on the recarga, and the chat is not handed to a person
--   2  a lone recarga / a lone mexico operation + card data: the card opens a plain remesa next to it; the other untouched
--   3  marcar_destino_usd('efectivo') with only a mexico operation open: a new cash remesa, the mexico operation keeps its rail
--   4  marcar_destino_usd accepts 'cup' (rail cuban_card) and says so; the bad-type message is unchanged
--   5  250 for the tool: two open Zelle remesas, the tool call re-saving the first payee stays on the first, a new payee goes to
--      the empty one (before this, the tool handed the chat to a person)
--   6  registrar_numeros_recarga with an EMPTY clasica operation open opens the recarga as a separate empty operation and
--      saves the number there; with a real deposit on the other operation it still refuses (no second operation)
--   7  end to end: deposit 24,400 on that pair + repartir_envio('clasica 18200, recarga 6200') reuses both operations (no third),
--      the card stays on the clasica part and the number on the recarga part
-- =====================================================================

CREATE FUNCTION pg_temp.t_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990276' || lpad(p_n::text, 4, '0'), 'PRUEBA objetivo ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t_op(p_c record, p_svc text, p_rail text) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, 'collecting_information', p_svc, p_rail, 'GYD', 0, clock_timestamp())
  RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t_registra(p_conv uuid, p_monto numeric, p_ref text)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE sql AS $f$
  SELECT * FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           'COMP-' || substr(md5(p_ref), 1, 20));
$f$;

-- "service:rail/amount" of the open operations, oldest first
CREATE FUNCTION pg_temp.t_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(o.service_type || ':' || coalesce(o.delivery_method, '-') || '/' || coalesce(o.quoted_source_amount::int::text, '-'),
                             ';' ORDER BY o.service_type, o.delivery_method, o.id), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;

-- vigente recipients of one operation: "type:card|phone|account" list
CREATE FUNCTION pg_temp.t_ben(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(beneficiary_type || ':' || coalesce(card_number, '') || '|' || coalesce(phone, '') || '|' || coalesce(zelle_account, ''),
                             ',' ORDER BY position, block_index), 'none')
    FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente';
$f$;

CREATE FUNCTION pg_temp.t_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.t_msg(p_conv uuid, p_text text, p_secs_before int) RETURNS void LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (p_conv, 'customer', 'text', p_text, now() - make_interval(secs => p_secs_before));
$f$;

CREATE FUNCTION pg_temp.t_age(p_conv uuid, p_secs_before int) RETURNS void LANGUAGE sql AS $f$
  UPDATE remittance_operations SET created_at = now() - make_interval(secs => p_secs_before)
   WHERE conversation_id = p_conv AND created_at = now();
  UPDATE remittance_beneficiaries b SET created_at = now() - make_interval(secs => p_secs_before)
    FROM remittance_operations o
   WHERE o.id = b.operation_id AND o.conversation_id = p_conv AND b.created_at = now();
$f$;

DO $$
DECLARE
  c record; v_cl uuid; v_re uuid; v_x uuid; v_m uuid; v_a text; v_z1 uuid; v_z2 uuid; v_ids uuid[];
  v_hoy date := (now() AT TIME ZONE 'America/Guyana')::date;
  c_card constant text := '9999000000000006';
  c_card2 constant text := '9999000000000007';
BEGIN
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 2, 'ASSERT 276', 'https://assert.invalid/276', 'assert', md5('assert-276-vigente'), 'confirmada');
  IF (SELECT precio_gyd FROM cerebro_promo_vigente()) IS DISTINCT FROM 6200 THEN RAISE EXCEPTION 'fixture: promo price is not 6200'; END IF;

  -- 1 mixed send before the deposit
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_cl := pg_temp.t_op(c, 'remesa', 'clasica');
  v_re := pg_temp.t_op(c, 'recarga', NULL);
  SELECT accion INTO v_a FROM cerebro_guardar_beneficiario(c.conv, '', c_card, '53821203', 'f1');
  PERFORM pg_temp.t_eq('1 not handed to a person', (v_a LIKE 'NO SE REGISTRO NADA%')::text, 'false');
  PERFORM pg_temp.t_eq('1 card on the clasica operation', pg_temp.t_ben(v_cl), 'clasica:' || c_card || '|53821203|');
  PERFORM pg_temp.t_eq('1 recarga untouched', pg_temp.t_ben(v_re), 'none');
  PERFORM pg_temp.t_eq('1 no extra operation', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '2');

  -- 2 lone recarga, lone mexico
  SELECT * INTO c FROM pg_temp.t_conv(2);
  v_re := pg_temp.t_op(c, 'recarga', NULL);
  PERFORM cerebro_guardar_beneficiario(c.conv, '', c_card, '53821203', 'f2');
  PERFORM pg_temp.t_eq('2 recarga untouched', pg_temp.t_ben(v_re), 'none');
  PERFORM pg_temp.t_eq('2 a remesa opened next to it', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND service_type = 'remesa'), '1');
  SELECT * INTO c FROM pg_temp.t_conv(3);
  v_m := pg_temp.t_op(c, 'mexico', NULL);
  PERFORM cerebro_guardar_beneficiario(c.conv, '', c_card, '53821203', 'f3');
  PERFORM pg_temp.t_eq('2 mexico untouched', pg_temp.t_ben(v_m) || '/' || coalesce((SELECT delivery_method FROM remittance_operations WHERE id = v_m), '-'), 'none/-');
  PERFORM pg_temp.t_eq('2 a remesa opened next to mexico', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND service_type = 'remesa'), '1');

  -- 3 cash mark with only a mexico operation
  SELECT * INTO c FROM pg_temp.t_conv(4);
  v_m := pg_temp.t_op(c, 'mexico', NULL);
  SELECT accion INTO v_a FROM cerebro_marcar_destino_usd(c.conv, 'efectivo', 'f4');
  PERFORM pg_temp.t_eq('3 mexico keeps its rail', coalesce((SELECT delivery_method FROM remittance_operations WHERE id = v_m), '-'), '-');
  PERFORM pg_temp.t_eq('3 new cash remesa', pg_temp.t_ops(c.conv), 'mexico:-/0;remesa:efectivo_usd/0');

  -- 4 cup
  SELECT * INTO c FROM pg_temp.t_conv(5);
  v_x := pg_temp.t_op(c, 'remesa', NULL);
  SELECT accion INTO v_a FROM cerebro_marcar_destino_usd(c.conv, 'cup', 'f5');
  PERFORM pg_temp.t_eq('4 cup marked', coalesce((SELECT delivery_method FROM remittance_operations WHERE id = v_x), '-'), 'cuban_card');
  PERFORM pg_temp.t_eq('4 cup text', (v_a LIKE '%CUP%')::text, 'true');
  SELECT accion INTO v_a FROM cerebro_marcar_destino_usd(c.conv, 'paypal', 'f5b');
  PERFORM pg_temp.t_eq('4 bad type message unchanged', v_a, 'ERROR: el tipo debe ser clasica, tropical o efectivo. No se marco nada.');

  -- 5 250 for the tool: two open Zelle remesas
  SELECT * INTO c FROM pg_temp.t_conv(6);
  PERFORM pg_temp.t_msg(c.conv, E'786-295-5183\n\nSantialv LLC', 98);
  PERFORM pg_temp.t_registra(c.conv, 28600, '27600001');
  PERFORM pg_temp.t_age(c.conv, 86);
  PERFORM cerebro_guardar_zelle(c.conv, 'Santialv LLC', '7862955183', 'f6a');
  PERFORM pg_temp.t_age(c.conv, 66);
  PERFORM pg_temp.t_registra(c.conv, 28600, '27600002');
  PERFORM pg_temp.t_age(c.conv, 33);
  SELECT accion INTO v_a FROM cerebro_guardar_zelle(c.conv, 'Santialv LLC', '7862955183', 'f6b');
  PERFORM pg_temp.t_eq('5 re-save is not handed to a person', (v_a LIKE 'NO SE REGISTRO NADA%')::text, 'false');
  PERFORM pg_temp.t_msg(c.conv, '7043431236', 23);
  PERFORM pg_temp.t_msg(c.conv, 'Orlansys Rodriguez', 23);
  SELECT accion INTO v_a FROM cerebro_guardar_zelle(c.conv, 'Orlansys Rodriguez', '7043431236', 'f6c');
  SELECT array_agg(o.id ORDER BY o.created_at) INTO v_ids FROM remittance_operations o WHERE o.conversation_id = c.conv;
  PERFORM pg_temp.t_eq('5 first payee on the first operation', pg_temp.t_ben(v_ids[1]), 'zelle:||7862955183');
  PERFORM pg_temp.t_eq('5 second payee on the second operation', pg_temp.t_ben(v_ids[2]), 'zelle:||7043431236');

  -- 6 numbers with an empty clasica open
  SELECT * INTO c FROM pg_temp.t_conv(7);
  v_cl := pg_temp.t_op(c, 'remesa', 'clasica');
  PERFORM cerebro_declarar_servicio(c.conv, 'clasica', 'agent:declarar_servicio');
  v_a := crm_registrar_numeros_recarga(c.conv, '55599180', true, 'agent:registrar_numeros_recarga');
  PERFORM pg_temp.t_eq('6 separate recarga', pg_temp.t_ops(c.conv), 'recarga:-/0;remesa:clasica/0');
  PERFORM pg_temp.t_eq('6 number saved', (SELECT pg_temp.t_ben(o.id) FROM remittance_operations o WHERE o.conversation_id = c.conv AND o.service_type = 'recarga'), 'recarga:|55599180|');
  PERFORM pg_temp.t_eq('6 text', (v_a LIKE 'guardados 1%')::text, 'true');
  -- with a real deposit on the other operation: unchanged refusal, no second operation
  SELECT * INTO c FROM pg_temp.t_conv(8);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
  VALUES (c.acc, c.conv, c.contact, 'deposit_verification', 'remesa', 'clasica', 'GYD', 5000);
  v_a := crm_registrar_numeros_recarga(c.conv, '55599180', true, 'agent:registrar_numeros_recarga');
  PERFORM pg_temp.t_eq('6 refusal keeps one operation', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '1');

  -- 7 end to end on the pair of case 6 (fresh conversation)
  SELECT * INTO c FROM pg_temp.t_conv(9);
  v_cl := pg_temp.t_op(c, 'remesa', 'clasica');
  PERFORM cerebro_guardar_beneficiario(c.conv, '', c_card2, '53821203', 'f9a');
  PERFORM crm_registrar_numeros_recarga(c.conv, '55599180', true, 'agent:registrar_numeros_recarga');
  PERFORM pg_temp.t_registra(c.conv, 24400, '27600003');
  v_a := cerebro_repartir_envio(c.conv, 'clasica 18200, recarga 6200', 'f9b');
  PERFORM pg_temp.t_eq('7 split done on the two operations', (v_a LIKE 'Reparto hecho%')::text, 'true');
  PERFORM pg_temp.t_eq('7 two operations only', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND status <> 'cancelled'), '2');
  PERFORM pg_temp.t_eq('7 clasica keeps the card', pg_temp.t_ben(v_cl), 'clasica:' || c_card2 || '|53821203|');
  PERFORM pg_temp.t_eq('7 recarga keeps the number', (SELECT pg_temp.t_ben(o.id) FROM remittance_operations o WHERE o.conversation_id = c.conv AND o.service_type = 'recarga'), 'recarga:|55599180|');
  PERFORM pg_temp.t_eq('7 amounts', (SELECT string_agg(o.service_type || '/' || o.quoted_source_amount::int, ';' ORDER BY o.service_type) FROM remittance_operations o WHERE o.conversation_id = c.conv), 'recarga/6200;remesa/18200');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
