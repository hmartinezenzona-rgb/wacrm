-- =====================================================================
-- Assertion for migration 258 (the board shows completed operations only since the last business opening).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Fixtures build their own account, user,
-- contact and operations. Run it as: BEGIN; \i board-clears-at-opening.sql; ROLLBACK;
--
-- Cases:
--   1. crm_tablero_corte(t) with fixed instants: after the opening hour -> today's opening; before it -> yesterday's;
--      exactly at it -> that instant; it follows cerebro_config horario_abre (Guyana time, UTC-4).
--   2. The board shows an operation completed after the cut and hides one completed before it (even if < 24 h ago).
--   3. Open operations are unaffected by the cut; grants: only service_role executes the helper.
-- =====================================================================
DO $$
DECLARE
  v_user   uuid := gen_random_uuid();
  v_acc    uuid;
  v_ct     uuid;
  v_conv   uuid;
  v_hash   text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_cut    timestamptz;
  v_after  uuid;
  v_before uuid;
  v_open   uuid;
  v_got    timestamptz;
BEGIN
  -- 1. The cut, with fixed instants (Guyana = UTC-4, no DST). Opening 09:00 by default config.
  UPDATE cerebro_config SET valor = '09:00' WHERE clave = 'horario_abre';
  v_got := crm_tablero_corte('2026-10-21 12:15:00-04');
  IF v_got <> '2026-10-21 09:00:00-04'::timestamptz THEN
    RAISE EXCEPTION 'case 1: after opening the cut is today 09:00, got %', v_got; END IF;
  v_got := crm_tablero_corte('2026-10-21 08:59:59-04');
  IF v_got <> '2026-10-20 09:00:00-04'::timestamptz THEN
    RAISE EXCEPTION 'case 1: before opening the cut is yesterday 09:00, got %', v_got; END IF;
  v_got := crm_tablero_corte('2026-10-21 09:00:00-04');
  IF v_got <> '2026-10-21 09:00:00-04'::timestamptz THEN
    RAISE EXCEPTION 'case 1: at opening the cut is that instant, got %', v_got; END IF;
  -- 02:30 UTC on the 22nd is still the 21st in Guyana (22:30).
  v_got := crm_tablero_corte('2026-10-22 02:30:00+00');
  IF v_got <> '2026-10-21 09:00:00-04'::timestamptz THEN
    RAISE EXCEPTION 'case 1: the day is the Guyana day, got %', v_got; END IF;
  UPDATE cerebro_config SET valor = '08:30' WHERE clave = 'horario_abre';
  v_got := crm_tablero_corte('2026-10-21 08:45:00-04');
  IF v_got <> '2026-10-21 08:30:00-04'::timestamptz THEN
    RAISE EXCEPTION 'case 1: the cut follows horario_abre, got %', v_got; END IF;
  UPDATE cerebro_config SET valor = '09:00' WHERE clave = 'horario_abre';

  -- Fixture.
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tab-cut-' || v_user || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'board cut account', v_user) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_user, 'board cut agent', 'tab-cut-' || v_user || '@test.invalid', v_acc, 'agent');
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990025801', 'Board Cut Customer') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  v_cut := crm_tablero_corte(now());
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 25801, 'zelle') RETURNING id INTO v_after;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 25802, 'zelle') RETURNING id INTO v_before;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 25803, 'zelle') RETURNING id INTO v_open;
  -- A completion is only accepted from a logged-in human (the status guard suppresses automation ones).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = v_cut + interval '1 second' WHERE id = v_after;
  UPDATE remittance_operations SET status = 'completed', completed_at = v_cut - interval '1 second' WHERE id = v_before;

  -- 2. After the cut appears; before it (less than 24 h earlier) does not.
  IF NOT EXISTS (SELECT 1 FROM crm_tablero_operaciones() t WHERE t.operation_id = v_after) THEN
    RAISE EXCEPTION 'case 2: an operation completed after the opening must appear'; END IF;
  IF EXISTS (SELECT 1 FROM crm_tablero_operaciones() t WHERE t.operation_id = v_before) THEN
    RAISE EXCEPTION 'case 2: an operation completed before the opening must not appear'; END IF;

  -- 3. Open operations are not cut.
  IF NOT EXISTS (SELECT 1 FROM crm_tablero_operaciones() t WHERE t.operation_id = v_open) THEN
    RAISE EXCEPTION 'case 3: an open operation must appear'; END IF;
  PERFORM set_config('request.jwt.claims', '', true);
  IF has_function_privilege('anon', 'public.crm_tablero_corte(timestamptz)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.crm_tablero_corte(timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.crm_tablero_corte(timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 3: only service_role executes crm_tablero_corte'; END IF;
  IF NOT has_function_privilege('authenticated', 'crm_tablero_operaciones()', 'EXECUTE')
     OR has_function_privilege('anon', 'crm_tablero_operaciones()', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 3: board grants changed'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
