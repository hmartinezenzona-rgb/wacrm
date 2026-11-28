-- 302: service_role can operate the outbox; anon/authenticated still cannot.
DO $$
DECLARE
  v_fail text := '';
BEGIN
  IF NOT has_table_privilege('service_role', 'public.webhook_outbox', 'INSERT') THEN
    v_fail := v_fail || ' 1:insert';
  END IF;
  IF NOT has_table_privilege('service_role', 'public.webhook_outbox', 'SELECT') THEN
    v_fail := v_fail || ' 2:select';
  END IF;
  IF NOT has_table_privilege('service_role', 'public.webhook_outbox', 'UPDATE') THEN
    v_fail := v_fail || ' 3:update';
  END IF;
  IF NOT has_table_privilege('service_role', 'public.webhook_outbox', 'DELETE') THEN
    v_fail := v_fail || ' 4:delete';
  END IF;

  IF has_table_privilege('anon', 'public.webhook_outbox', 'INSERT')
     OR has_table_privilege('authenticated', 'public.webhook_outbox', 'INSERT') THEN
    v_fail := v_fail || ' 5:fuga-browser';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.cerebro_webhook_outbox_reclamar(integer)', 'EXECUTE') THEN
    v_fail := v_fail || ' 6:reclamar';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.cerebro_webhook_outbox_ping()', 'EXECUTE') THEN
    v_fail := v_fail || ' 7:ping';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
