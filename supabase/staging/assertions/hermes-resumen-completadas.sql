-- 322: "completadas" counts by completed_at, agreeing with a hand count and
-- with hermes_cuadre_finanzas over the same days. Self-reverting.
DO $$
DECLARE
  v_ini timestamptz := ((now() AT TIME ZONE 'America/Guyana')::date - 6 + time '00:00') AT TIME ZONE 'America/Guyana';
  v_fin timestamptz := now();
  v jsonb;
  v_fail text := '';
  v_n bigint;
BEGIN
  v := hermes_resumen_periodo(v_ini, v_fin, 1);

  SELECT count(*) INTO v_n
    FROM remittance_operations
   WHERE status = 'completed'
     AND completed_at >= v_ini AND completed_at < v_fin;
  IF (v->'totales'->>'completadas')::bigint <> v_n THEN
    v_fail := v_fail || ' 1:completadas';
  END IF;

  -- The same week, read through the reconciliation function.
  SELECT count(*) INTO v_n
    FROM remittance_operations
   WHERE status = 'completed'
     AND (completed_at AT TIME ZONE 'America/Guyana')::date
         BETWEEN (now() AT TIME ZONE 'America/Guyana')::date - 6
             AND (now() AT TIME ZONE 'America/Guyana')::date;
  IF (hermes_cuadre_finanzas((now() AT TIME ZONE 'America/Guyana')::date - 6,
                             (now() AT TIME ZONE 'America/Guyana')::date)->'crm'->>'completadas')::bigint
     <> v_n THEN
    v_fail := v_fail || ' 2:cuadre';
  END IF;

  SELECT count(*) INTO v_n
    FROM remittance_operations
   WHERE status = 'incident'
     AND coalesce(status_changed_at, updated_at) >= v_ini
     AND coalesce(status_changed_at, updated_at) < v_fin;
  IF (v->'totales'->>'incidencias')::bigint <> v_n THEN
    v_fail := v_fail || ' 3:incidencias';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION '322 FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
