-- 310: an admin-tagged conversation validates the receipt without creating a deal or an operation.
DO $$
DECLARE
  v_owner uuid := gen_random_uuid();
  v_hash constant text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_tag uuid;
  v_ct_admin uuid; v_conv_admin uuid;
  v_deals_before integer; v_ops_before integer;
  v_deal uuid; v_accion text; v_fail text := '';
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dep-admin-310-' || v_owner || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'registrar admin 310', v_owner) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner, 'dep admin 310', 'dep-admin-310-' || v_owner || '@test.invalid', v_acc, 'owner');

  SELECT id INTO v_tag FROM tags WHERE lower(name) = 'admin' LIMIT 1;
  IF v_tag IS NULL THEN
    INSERT INTO tags (user_id, name, color) VALUES (v_owner, 'Admin', '#ff0000') RETURNING id INTO v_tag;
  END IF;

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner, '59900310001', 'ADMIN 310', v_acc) RETURNING id INTO v_ct_admin;
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_ct_admin, v_tag);
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_ct_admin, v_acc) RETURNING id INTO v_conv_admin;

  SELECT count(*) INTO v_deals_before FROM deals;
  SELECT count(*) INTO v_ops_before FROM remittance_operations;

  SELECT deal_id, accion INTO v_deal, v_accion
    FROM cerebro_registrar_deposito_si_cliente(v_conv_admin, 5000, 'GYD', NULL, 'prueba 310', 'prueba-310');

  IF v_deal IS NOT NULL THEN v_fail := v_fail || ' 1:creo-deal'; END IF;
  IF v_accion <> 'verificacion_admin' THEN v_fail := v_fail || ' 2:accion=' || coalesce(v_accion, 'null'); END IF;
  IF (SELECT count(*) FROM deals) <> v_deals_before THEN v_fail := v_fail || ' 3:deals'; END IF;
  IF (SELECT count(*) FROM remittance_operations) <> v_ops_before THEN v_fail := v_fail || ' 4:ops'; END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
