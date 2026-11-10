-- 313: a recorded promise queues one admin alert and never blocks the message.
DO $$
DECLARE
  v_owner uuid := gen_random_uuid();
  v_hash constant text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_tag uuid; v_ct_admin uuid; v_ct_cli uuid;
  v_conv_admin uuid; v_conv_cli uuid; v_msg uuid;
  v_n integer; v_aviso integer; v_fail text := '';
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'prom-313-' || v_owner || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'promesa 313', v_owner) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner, 'prom 313', 'prom-313-' || v_owner || '@test.invalid', v_acc, 'owner');

  SELECT id INTO v_tag FROM tags WHERE lower(name) = 'admin' LIMIT 1;
  IF v_tag IS NULL THEN
    INSERT INTO tags (user_id, name, color) VALUES (v_owner, 'Admin', '#ff0000') RETURNING id INTO v_tag;
  END IF;

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner, '59900313001', 'ADMIN 313', v_acc) RETURNING id INTO v_ct_admin;
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_ct_admin, v_tag);
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_ct_admin, v_acc) RETURNING id INTO v_conv_admin;

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner, '59900313002', 'CLIENTE 313', v_acc) RETURNING id INTO v_ct_cli;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_ct_cli, v_acc) RETURNING id INTO v_conv_cli;

  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, ai_generated, status)
  VALUES (v_conv_cli, 'agent', 'text', 'Anotado el celular 53821208.', true, 'sent')
  RETURNING id INTO v_msg;

  -- 362: the case is recorded when the candidate is evaluated (2 min later); evaluate now. Absent on the 313 base.
  IF to_regprocedure('cerebro_promesa_evaluar(timestamptz)') IS NOT NULL THEN
    EXECUTE 'SELECT cerebro_promesa_evaluar(now() + interval ''3 minutes'')';
  END IF;
  SELECT count(*) INTO v_n FROM cerebro_promesas_sin_escritura WHERE message_id = v_msg;
  IF v_n <> 1 THEN v_fail := v_fail || ' 1:sin-registro=' || v_n; END IF;
  SELECT count(*) INTO v_aviso FROM message_outbox
   WHERE payload ->> 'text' LIKE 'AVISO PROMESA%' AND conversation_id = v_conv_cli;
  IF v_aviso <> 1 THEN v_fail := v_fail || ' 2:sin-aviso=' || v_aviso; END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
