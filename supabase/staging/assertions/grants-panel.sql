-- 305: service_role can read the tables the panel queries with the service key.
DO $$
DECLARE
  v_fail text := '';
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['session_events', 'promo_etecsa', 'precio_recarga'] LOOP
    IF NOT has_table_privilege('service_role', 'public.' || t, 'SELECT') THEN
      v_fail := v_fail || ' ' || t || ':sin-select';
    END IF;
  END LOOP;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
