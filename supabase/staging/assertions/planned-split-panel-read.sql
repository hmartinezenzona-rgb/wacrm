\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 370 (the panel reads the conversation's planned split: crm_reparto_planeado_de_conversacion).
-- Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contact 'PRUEBA plan panel', phone 5990370xxxx. The caller is simulated through request.jwt.claims.
-- Cases:
--   1  no plan: no row
--   2  a plan: one row per part in the customer's order, with the service, the amount and the plan total on every row
--   3  a viewer of another account (or nobody) gets 42501
--   4  ACL: authenticated and service_role may run it, anon may not
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_n int; v_txt text; v_ok boolean;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '59903700001', 'PRUEBA plan panel', v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_conv;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  SELECT count(*) INTO v_n FROM crm_reparto_planeado_de_conversacion(v_conv);
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 1: no plan must give no row, got %', v_n; END IF;

  INSERT INTO cerebro_reparto_planeado (conversation_id, partes, total_gyd, actor)
  VALUES (v_conv, '[{"servicio":"recarga","monto_gyd":12400},{"servicio":"zelle","monto_gyd":13000}]'::jsonb, 25400, 'agent:repartir_envio');
  SELECT string_agg(servicio || '=' || monto_gyd::int || '/' || total_gyd::int, ';' ORDER BY posicion) INTO v_txt
    FROM crm_reparto_planeado_de_conversacion(v_conv);
  IF v_txt IS DISTINCT FROM 'recarga=12400/25400;zelle=13000/25400' THEN RAISE EXCEPTION 'case 2: got [%]', v_txt; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN
    PERFORM * FROM crm_reparto_planeado_de_conversacion(v_conv);
  EXCEPTION WHEN insufficient_privilege THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: a non-member must get insufficient_privilege'; END IF;

  IF NOT (has_function_privilege('authenticated', 'public.crm_reparto_planeado_de_conversacion(uuid)', 'EXECUTE')
          AND has_function_privilege('service_role', 'public.crm_reparto_planeado_de_conversacion(uuid)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.crm_reparto_planeado_de_conversacion(uuid)', 'EXECUTE')) THEN
    RAISE EXCEPTION 'case 4: ACL';
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
