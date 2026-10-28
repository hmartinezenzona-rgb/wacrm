\set ON_ERROR_STOP on
-- 350: the panel (service key) can confirm and discard an Etecsa promo, and nothing else on it.
-- Cases:
--   1. service_role can UPDATE estado, confirmada_at and confirmada_por (what /api/promotions/etecsa writes).
--   2. service_role still cannot change the promo's figures or dates (min_cup, multiplicador, vigente_desde).
--   3. As service_role, the exact update the route runs on confirm succeeds on a detected promo.
DO $$
DECLARE
  v_fail text := '';
  c text;
  v_id uuid;
BEGIN
  FOREACH c IN ARRAY ARRAY['estado', 'confirmada_at', 'confirmada_por'] LOOP
    IF NOT has_column_privilege('service_role', 'public.promo_etecsa', c, 'UPDATE') THEN
      v_fail := v_fail || ' ' || c || ':sin-update';
    END IF;
  END LOOP;

  FOREACH c IN ARRAY ARRAY['min_cup', 'multiplicador', 'vigente_desde'] LOOP
    IF has_column_privilege('service_role', 'public.promo_etecsa', c, 'UPDATE') THEN
      v_fail := v_fail || ' ' || c || ':update-de-mas';
    END IF;
  END LOOP;

  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url,
                            texto_crudo, huella)
  VALUES (600, 1250, 96, current_date + 3, current_date + 5, 'ASSERT 350', 'https://assert.invalid/350',
          'assert', md5('assert-350'))
  RETURNING id INTO v_id;
  BEGIN
    SET LOCAL ROLE service_role;
    UPDATE promo_etecsa SET estado = 'confirmada', confirmada_at = now(), confirmada_por = 'crm'
     WHERE id = v_id AND estado = 'detectada';
    RESET ROLE;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    v_fail := v_fail || ' confirmar:' || SQLERRM;
  END;
  IF v_fail NOT LIKE '%confirmar:%'
     AND (SELECT estado FROM promo_etecsa WHERE id = v_id) IS DISTINCT FROM 'confirmada' THEN
    v_fail := v_fail || ' confirmar:sin-efecto';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
