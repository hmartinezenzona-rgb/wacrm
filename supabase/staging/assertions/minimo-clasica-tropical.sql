-- 306: Clasica and Tropical start at 20 USD (5,200 GYD at 260); Zelle keeps 50 USD.
DO $$
DECLARE
  v_owner uuid := gen_random_uuid();
  v_hash constant text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_ct uuid; v_conv uuid;
  v_clasica uuid; v_tropical uuid; v_zelle uuid; v_cup uuid;
  v_fail text := '';
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'min-306-' || v_owner || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'minimo 306 test', v_owner) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner, 'min 306', 'min-306-' || v_owner || '@test.invalid', v_acc, 'owner');

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner, '59900306001', 'MIN 306', v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_ct, v_acc) RETURNING id INTO v_conv;

  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'clasica', 'collecting_information', 0) RETURNING id INTO v_clasica;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'tropical', 'collecting_information', 0) RETURNING id INTO v_tropical;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'zelle', 'collecting_information', 0) RETURNING id INTO v_zelle;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'cuban_card', 'collecting_information', 0) RETURNING id INTO v_cup;

  IF (SELECT valor FROM cerebro_config WHERE clave = 'minimo_gyd_clasica') <> '5200' THEN
    v_fail := v_fail || ' 1:config-clasica';
  END IF;
  IF (SELECT valor FROM cerebro_config WHERE clave = 'minimo_gyd_tropical') <> '5200' THEN
    v_fail := v_fail || ' 2:config-tropical';
  END IF;
  IF cerebro_minimo_gyd(v_clasica) <> 5200 THEN v_fail := v_fail || ' 3:clasica=' || cerebro_minimo_gyd(v_clasica); END IF;
  IF cerebro_minimo_gyd(v_tropical) <> 5200 THEN v_fail := v_fail || ' 4:tropical=' || cerebro_minimo_gyd(v_tropical); END IF;
  IF cerebro_minimo_gyd(v_zelle) <> COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                                             NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000) THEN
    v_fail := v_fail || ' 5:zelle=' || cerebro_minimo_gyd(v_zelle);
  END IF;
  IF cerebro_minimo_gyd(v_cup) <> COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000) THEN
    v_fail := v_fail || ' 6:cup=' || cerebro_minimo_gyd(v_cup);
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
