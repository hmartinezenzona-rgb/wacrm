-- 316: the Hermes reconciliation query answers, agrees with the source tables
-- and refuses an inverted range. Self-reverting.
DO $$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Guyana')::date;
  v jsonb;
  v_fail text := '';
  v_n bigint;
BEGIN
  v := hermes_cuadre_finanzas(NULL, NULL);

  IF jsonb_typeof(v) <> 'object' THEN v_fail := v_fail || ' 1:tipo'; END IF;
  IF (v->>'desde')::date <> v_hoy THEN v_fail := v_fail || ' 2:desde'; END IF;
  IF (v->>'hasta')::date <> v_hoy THEN v_fail := v_fail || ' 3:hasta'; END IF;
  IF (v->'crm') IS NULL OR (v->'finanzas') IS NULL OR (v->'control_semanal') IS NULL THEN
    v_fail := v_fail || ' 4:bloques';
  END IF;

  SELECT count(*) INTO v_n
    FROM remittance_operations o
   WHERE o.status = 'completed'
     AND o.completed_at IS NOT NULL
     AND (o.completed_at AT TIME ZONE 'America/Guyana')::date = v_hoy;
  IF (v->'crm'->>'completadas')::bigint <> v_n THEN v_fail := v_fail || ' 5:crm'; END IF;

  SELECT count(*) INTO v_n
    FROM remittance_calculator_entries e
   WHERE e.source IN ('completed_operation', 'manual')
     AND e.status = 'completed'
     AND coalesce((e.completed_at AT TIME ZONE 'America/Guyana')::date, e.entry_date) = v_hoy;
  IF (v->'finanzas'->>'lineas')::bigint <> v_n THEN v_fail := v_fail || ' 6:finanzas'; END IF;

  IF ((v->'control_semanal'->'borrador'->>'lineas')::bigint
      + (v->'control_semanal'->'archivadas'->>'lineas')::bigint)
     <> (v->'finanzas'->>'lineas')::bigint THEN
    v_fail := v_fail || ' 7:semanal';
  END IF;

  BEGIN
    PERFORM hermes_cuadre_finanzas(v_hoy, v_hoy - 1);
    v_fail := v_fail || ' 8:rango';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  IF jsonb_typeof(hermes_cuadre_finanzas(v_hoy - 6, v_hoy)) <> 'object' THEN
    v_fail := v_fail || ' 9:semana';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
