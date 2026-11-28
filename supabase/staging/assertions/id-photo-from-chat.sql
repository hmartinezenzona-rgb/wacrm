\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 233 (the cash recipient's ID photo is chosen from the chat).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; run it wrapped as BEGIN; <this file minus BEGIN/ROLLBACK/\set>; ROLLBACK;
-- Production 2026-10-08 (Edel): the carnet came before the cash operation existed, the bot stored nothing, and the panel had no way to attach it.
-- Model asserted:
--   * crm_corregir_beneficiario / crm_agregar_beneficiario take the key id_photo_wamid for a CASH (efectivo_usd) recipient only, and the value must be the
--     message_id of an IMAGE message of the operation's own conversation (22023 otherwise); NULL clears it on a correction; "" and non-strings are refused;
--   * same permission, lock and audit as the other fields: the audit row carries the reference before and after;
--   * crm_imagenes_de_conversacion lists the image messages of one conversation, newest first, for members only.
-- =====================================================================

CREATE FUNCTION pg_temp.t233_ctx(p_n int) RETURNS TABLE(usr uuid, acc uuid, ct uuid, conv uuid, op uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid; v_op uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990233' || lpad(p_n::text, 4, '0'), 'T233 ' || p_n) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_cv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
  VALUES (v_acc, v_cv, v_ct, 'collecting_information', 'remesa', 'efectivo_usd', 'GYD', 29000) RETURNING id INTO v_op;
  RETURN QUERY SELECT v_user, v_acc, v_ct, v_cv, v_op;
END $f$;

CREATE FUNCTION pg_temp.t233_msg(p_conv uuid, p_type text, p_wamid text, p_sender text, p_age_min int) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, media_url, message_id, created_at)
  VALUES (p_conv, p_sender, p_type, CASE WHEN p_type = 'text' THEN 'hola' END,
          CASE WHEN p_type = 'image' THEN 'https://example.invalid/' || p_wamid || '.jpg' END, p_wamid, now() - make_interval(mins => p_age_min));
$f$;

CREATE FUNCTION pg_temp.t233_cash(p_op uuid) RETURNS uuid LANGUAGE sql AS $f$
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, address, position, block_index, source, status)
  VALUES (p_op, 'efectivo_usd', 'Receptor T233', '52123456', 'Calle 1 #2, La Habana', 1, 1, 'notes_parse', 'vigente') RETURNING id;
$f$;

-- run a statement as a user (JWT claims) and return its SQLSTATE or 'ok'
CREATE FUNCTION pg_temp.t233_as(p_uid uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  EXECUTE p_sql;
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN SQLSTATE;
END $f$;

DO $$
DECLARE
  c record; c2 record; v_b uuid; v_b2 uuid; v_r text; v_row remittance_beneficiaries%ROWTYPE; v_aud record; v_n int; v_res jsonb;
  v_stranger uuid := gen_random_uuid();
BEGIN
  SELECT * INTO c FROM pg_temp.t233_ctx(1);
  SELECT * INTO c2 FROM pg_temp.t233_ctx(2);
  PERFORM pg_temp.t233_msg(c.conv, 'image', 'wamid.t233.img.old', 'customer', 300);
  PERFORM pg_temp.t233_msg(c.conv, 'text', 'wamid.t233.txt', 'customer', 200);
  PERFORM pg_temp.t233_msg(c.conv, 'image', 'wamid.t233.img.new', 'customer', 100);
  PERFORM pg_temp.t233_msg(c.conv, 'image', 'wamid.t233.img.agent', 'agent', 50);
  PERFORM pg_temp.t233_msg(c2.conv, 'image', 'wamid.t233.other', 'customer', 100);
  v_b := pg_temp.t233_cash(c.op);

  -- a. correction with a valid image of the conversation
  v_r := pg_temp.t233_as(c.usr, format('SELECT crm_corregir_beneficiario(%L, %L::jsonb)', v_b, '{"id_photo_wamid":"wamid.t233.img.old"}'));
  IF v_r <> 'ok' THEN RAISE EXCEPTION 'case a: the correction must work, got %', v_r; END IF;
  SELECT * INTO v_row FROM remittance_beneficiaries WHERE operation_id = c.op AND status = 'vigente';
  IF v_row.id_photo_wamid IS DISTINCT FROM 'wamid.t233.img.old' OR v_row.name <> 'Receptor T233' OR v_row.phone <> '52123456'
     OR v_row.address <> 'Calle 1 #2, La Habana' OR v_row.beneficiary_type <> 'efectivo_usd' OR v_row.source <> 'admin_correction' THEN
    RAISE EXCEPTION 'case a: unexpected row %', to_jsonb(v_row); END IF;
  SELECT * INTO v_aud FROM remittance_admin_audit WHERE row_id = v_row.id AND action = 'human_correction';
  IF v_aud.id IS NULL OR v_aud.after -> 'id_photo_wamid' IS DISTINCT FROM to_jsonb('wamid.t233.img.old'::text)
     OR NOT (v_aud.before ? 'id_photo_wamid') OR v_aud.before -> 'id_photo_wamid' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'case a: the audit must carry the reference before and after: %', to_jsonb(v_aud); END IF;
  IF NOT (SELECT admin_locked_fields ? 'beneficiaries' FROM remittance_operations WHERE id = c.op) THEN RAISE EXCEPTION 'case a: the beneficiaries lock'; END IF;
  IF NOT crm_beneficiarios_completos(c.op) THEN RAISE EXCEPTION 'case a: the recipient with its photo must be complete'; END IF;
  RAISE NOTICE 'PASS a: a cash recipient takes an image of the chat as its ID photo (row, audit, lock, completeness)';

  -- b. change to another image, audit before = the previous one
  v_b := v_row.id;
  v_r := pg_temp.t233_as(c.usr, format('SELECT crm_corregir_beneficiario(%L, %L::jsonb)', v_b, '{"id_photo_wamid":"wamid.t233.img.new"}'));
  SELECT * INTO v_row FROM remittance_beneficiaries WHERE operation_id = c.op AND status = 'vigente';
  IF v_r <> 'ok' OR v_row.id_photo_wamid <> 'wamid.t233.img.new' THEN RAISE EXCEPTION 'case b: got % %', v_r, v_row.id_photo_wamid; END IF;
  SELECT * INTO v_aud FROM remittance_admin_audit WHERE row_id = v_row.id AND action = 'human_correction';
  IF v_aud.before -> 'id_photo_wamid' IS DISTINCT FROM to_jsonb('wamid.t233.img.old'::text) THEN RAISE EXCEPTION 'case b: audit before %', to_jsonb(v_aud); END IF;
  RAISE NOTICE 'PASS b: the photo can be changed; the audit keeps the previous reference';

  -- c. everything else is refused with 22023 and writes nothing
  v_b := v_row.id;
  FOREACH v_r IN ARRAY ARRAY['{"id_photo_wamid":"wamid.t233.txt"}', '{"id_photo_wamid":"wamid.t233.other"}', '{"id_photo_wamid":"wamid.nope"}',
                            '{"id_photo_wamid":""}', '{"id_photo_wamid":123}', '{"id_photo_wamid":{"a":1}}'] LOOP
    IF pg_temp.t233_as(c.usr, format('SELECT crm_corregir_beneficiario(%L, %L::jsonb)', v_b, v_r)) <> '22023' THEN
      RAISE EXCEPTION 'case c: % must be refused with 22023', v_r; END IF;
  END LOOP;
  IF (SELECT id FROM remittance_beneficiaries WHERE operation_id = c.op AND status = 'vigente') <> v_b THEN RAISE EXCEPTION 'case c: a refusal must write nothing'; END IF;
  RAISE NOTICE 'PASS c: a text message, another chat''s image, an unknown id, "", a number and an object are refused';

  -- d. NULL clears the photo
  v_r := pg_temp.t233_as(c.usr, format('SELECT crm_corregir_beneficiario(%L, %L::jsonb)', v_b, '{"id_photo_wamid":null}'));
  SELECT * INTO v_row FROM remittance_beneficiaries WHERE operation_id = c.op AND status = 'vigente';
  IF v_r <> 'ok' OR v_row.id_photo_wamid IS NOT NULL OR crm_beneficiarios_completos(c.op) THEN RAISE EXCEPTION 'case d: null must clear the photo (%, %)', v_r, v_row.id_photo_wamid; END IF;
  RAISE NOTICE 'PASS d: null clears the photo and the recipient is incomplete again';

  -- e. a correction of another field keeps the photo
  v_b := v_row.id;
  PERFORM pg_temp.t233_as(c.usr, format('SELECT crm_corregir_beneficiario(%L, %L::jsonb)', v_b, '{"id_photo_wamid":"wamid.t233.img.agent"}'));
  SELECT id INTO v_b FROM remittance_beneficiaries WHERE operation_id = c.op AND status = 'vigente';
  PERFORM pg_temp.t233_as(c.usr, format('SELECT crm_corregir_beneficiario(%L, %L::jsonb)', v_b, '{"name":"Otro Nombre"}'));
  IF (SELECT id_photo_wamid FROM remittance_beneficiaries WHERE operation_id = c.op AND status = 'vigente') IS DISTINCT FROM 'wamid.t233.img.agent' THEN
    RAISE EXCEPTION 'case e: a name correction must keep the photo'; END IF;
  RAISE NOTICE 'PASS e: other corrections keep the photo (an image sent by the agent is also accepted)';

  -- f. not a cash recipient -> refused; non-member -> refused
  UPDATE remittance_beneficiaries SET status = 'reemplazado' WHERE operation_id = c.op AND status = 'vigente';
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, block_index, source, status)
  VALUES (c.op, 'zelle', 'Zelle T233', 'z@x.com', 100, 'USD', 1, 9, 'notes_parse', 'vigente') RETURNING id INTO v_b2;
  IF pg_temp.t233_as(c.usr, format('SELECT crm_corregir_beneficiario(%L, %L::jsonb)', v_b2, '{"id_photo_wamid":"wamid.t233.img.new"}')) <> '22023' THEN
    RAISE EXCEPTION 'case f: a non-cash recipient must refuse the photo'; END IF;
  v_b := pg_temp.t233_cash(c2.op);
  IF pg_temp.t233_as(v_stranger, format('SELECT crm_corregir_beneficiario(%L, %L::jsonb)', v_b, '{"id_photo_wamid":"wamid.t233.other"}')) <> '42501' THEN
    RAISE EXCEPTION 'case f: a non-member must be refused (42501)'; END IF;
  RAISE NOTICE 'PASS f: only a cash recipient takes the key; non-members are refused';

  -- g. add: a cash recipient with its photo; invalid refused; non-cash with the key refused; no key unchanged
  DELETE FROM remittance_beneficiaries WHERE operation_id = c2.op;
  v_r := pg_temp.t233_as(c2.usr, format('SELECT crm_agregar_beneficiario(%L, %L::jsonb)', c2.op,
           '{"beneficiary_type":"efectivo_usd","name":"Nuevo","phone":"52123456","address":"Calle 9","id_photo_wamid":"wamid.t233.other"}'));
  SELECT * INTO v_row FROM remittance_beneficiaries WHERE operation_id = c2.op AND status = 'vigente';
  IF v_r <> 'ok' OR v_row.id_photo_wamid IS DISTINCT FROM 'wamid.t233.other' THEN RAISE EXCEPTION 'case g1: got % %', v_r, v_row.id_photo_wamid; END IF;
  IF NOT crm_beneficiarios_completos(c2.op) THEN RAISE EXCEPTION 'case g1: a recipient added with its photo is complete'; END IF;
  SELECT * INTO v_aud FROM remittance_admin_audit WHERE row_id = v_row.id AND action = 'human_beneficiary_added';
  IF v_aud.after ->> 'id_photo_wamid' IS DISTINCT FROM 'wamid.t233.other' THEN RAISE EXCEPTION 'case g1: the audit carries the datos: %', to_jsonb(v_aud); END IF;
  DELETE FROM remittance_beneficiaries WHERE operation_id = c2.op;
  IF pg_temp.t233_as(c2.usr, format('SELECT crm_agregar_beneficiario(%L, %L::jsonb)', c2.op,
        '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 9","id_photo_wamid":"wamid.t233.img.new"}')) <> '22023' THEN
    RAISE EXCEPTION 'case g2: another chat''s image must be refused on add'; END IF;
  IF pg_temp.t233_as(c2.usr, format('SELECT crm_agregar_beneficiario(%L, %L::jsonb)', c2.op,
        '{"beneficiary_type":"zelle","name":"Z","zelle_account":"z@x.com","amount":10,"currency":"USD","id_photo_wamid":"wamid.t233.other"}')) <> '22023' THEN
    RAISE EXCEPTION 'case g3: a non-cash recipient must refuse the photo on add'; END IF;
  v_r := pg_temp.t233_as(c2.usr, format('SELECT crm_agregar_beneficiario(%L, %L::jsonb)', c2.op,
           '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 9"}'));
  IF v_r <> 'ok' OR (SELECT id_photo_wamid FROM remittance_beneficiaries WHERE operation_id = c2.op AND status = 'vigente') IS NOT NULL THEN
    RAISE EXCEPTION 'case g4: adding without a photo is unchanged (%)', v_r; END IF;
  RAISE NOTICE 'PASS g: crm_agregar_beneficiario takes the same optional key with the same validation';

  -- h. the picker's read
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO v_n FROM crm_imagenes_de_conversacion(c.conv);
  IF v_n <> 3 THEN RAISE EXCEPTION 'case h: 3 images expected (text and other chats excluded), got %', v_n; END IF;
  IF (SELECT array_agg(message_id ORDER BY ord) FROM (SELECT message_id, row_number() OVER () ord FROM crm_imagenes_de_conversacion(c.conv)) s)
     IS DISTINCT FROM ARRAY['wamid.t233.img.agent', 'wamid.t233.img.new', 'wamid.t233.img.old'] THEN
    RAISE EXCEPTION 'case h: newest first expected'; END IF;
  IF (SELECT count(*) FROM crm_imagenes_de_conversacion(c.conv, 2)) <> 2 THEN RAISE EXCEPTION 'case h: the limit'; END IF;
  IF NOT EXISTS (SELECT 1 FROM crm_imagenes_de_conversacion(c.conv) WHERE message_id = 'wamid.t233.img.new' AND sender_type = 'customer'
                    AND media_url = 'https://example.invalid/wamid.t233.img.new.jpg' AND created_at IS NOT NULL AND id IS NOT NULL) THEN
    RAISE EXCEPTION 'case h: columns'; END IF;
  PERFORM set_config('request.jwt.claims', '', true);
  IF pg_temp.t233_as(v_stranger, format('SELECT * FROM crm_imagenes_de_conversacion(%L)', c.conv)) <> '42501' THEN RAISE EXCEPTION 'case h: a non-member is refused'; END IF;
  IF pg_temp.t233_as(c.usr, 'SELECT * FROM crm_imagenes_de_conversacion(NULL)') <> '42501' THEN RAISE EXCEPTION 'case h: NULL conversation refused'; END IF;
  RAISE NOTICE 'PASS h: crm_imagenes_de_conversacion lists the conversation''s images, newest first, for members only';

  RAISE NOTICE 'ALL PASS (id-photo-from-chat)';
END $$;

ROLLBACK;
