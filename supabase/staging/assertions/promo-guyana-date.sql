-- =====================================================================
-- Assertions for 122 (promo functions follow the Guyana day).
-- RUN ONLY INSIDE A TRANSACTION THAT IS ROLLED BACK: inserts fixtures.
-- Every check RAISEs on mismatch.
-- =====================================================================

-- Fixtures: a confirmed promo 2026-08-13..16 (600 CUP, x6), a detected-only
-- one 2026-08-20..23 (must be ignored while promo_etecsa_modo = 'confirmar'),
-- and a confirmed one spanning Guyana "today" for the cerebro_servicio_get check.
INSERT INTO promo_etecsa (url, estado, huella, titulo, min_cup, max_cup, multiplicador,
                          vigente_desde, vigente_hasta, texto_crudo, detectada_at, confirmada_at, confirmada_por)
VALUES
  ('https://example.test/a', 'confirmada', 'fc-a', 'T', 600, 1250, 6, '2026-08-13', '2026-08-16', 'x', now(), now(), 'test'),
  ('https://example.test/b', 'detectada',  'fc-b', 'T', 600, 1250, 6, '2026-08-20', '2026-08-23', 'x', now(), NULL,  NULL);

DO $$
DECLARE
  n int;
  d int;
BEGIN
  IF coalesce(cerebro_config_get('promo_etecsa_modo'), 'confirmar') <> 'confirmar' THEN
    RAISE EXCEPTION 'precondition: promo_etecsa_modo must be confirmar on this database';
  END IF;

  -- vigente: inclusive on both ends, by the day passed in.
  SELECT count(*) INTO n FROM cerebro_promo_vigente('2026-08-16'::date);
  IF n <> 1 THEN RAISE EXCEPTION 'vigente on its last day (08-16): expected 1, got %', n; END IF;
  SELECT count(*) INTO n FROM cerebro_promo_vigente('2026-08-13'::date);
  IF n <> 1 THEN RAISE EXCEPTION 'vigente on its first day (08-13): expected 1, got %', n; END IF;
  SELECT count(*) INTO n FROM cerebro_promo_vigente('2026-08-17'::date);
  IF n <> 0 THEN RAISE EXCEPTION 'vigente the day after (08-17): expected 0, got %', n; END IF;
  SELECT count(*) INTO n FROM cerebro_promo_vigente('2026-08-21'::date);
  IF n <> 0 THEN RAISE EXCEPTION 'a detected-only promo must not be vigente in confirmar mode, got %', n; END IF;

  -- proxima: announced before it starts, gone once it starts.
  SELECT count(*), max(dias_para) INTO n, d FROM cerebro_promo_proxima('2026-08-10'::date);
  IF n <> 1 OR d <> 3 THEN RAISE EXCEPTION 'proxima on 08-10: expected 1 row with dias_para 3, got % / %', n, d; END IF;
  SELECT count(*) INTO n FROM cerebro_promo_proxima('2026-08-13'::date);
  IF n <> 0 THEN RAISE EXCEPTION 'proxima on its first day: expected 0, got %', n; END IF;

  -- The default is the Guyana calendar day, not the UTC current_date.
  IF pg_get_function_arguments('cerebro_promo_vigente(date)'::regprocedure) NOT LIKE '%America/Guyana%'
     OR pg_get_function_arguments('cerebro_promo_proxima(date)'::regprocedure) NOT LIKE '%America/Guyana%' THEN
    RAISE EXCEPTION 'defaults must be the Guyana day: % / %',
      pg_get_function_arguments('cerebro_promo_vigente(date)'::regprocedure),
      pg_get_function_arguments('cerebro_promo_proxima(date)'::regprocedure);
  END IF;

  -- Only the one-argument versions exist (a leftover zero-arg overload would
  -- make cerebro_servicio_get's no-argument call ambiguous).
  SELECT count(*) INTO n FROM pg_proc WHERE proname IN ('cerebro_promo_vigente', 'cerebro_promo_proxima');
  IF n <> 2 THEN RAISE EXCEPTION 'expected exactly 2 promo functions, got %', n; END IF;
END $$;

-- cerebro_servicio_get still works with its no-argument calls and uses the
-- Guyana day: a confirmed promo covering Guyana today is quoted.
INSERT INTO promo_etecsa (url, estado, huella, titulo, min_cup, max_cup, multiplicador,
                          vigente_desde, vigente_hasta, texto_crudo, detectada_at, confirmada_at, confirmada_por)
SELECT 'https://example.test/c', 'confirmada', 'fc-c', 'T', 600, 1250, 5,
       (now() AT TIME ZONE 'America/Guyana')::date, (now() AT TIME ZONE 'America/Guyana')::date,
       'x', now(), now(), 'test';

DO $$
DECLARE
  v_hechos text;
BEGIN
  SELECT hechos INTO v_hechos FROM cerebro_servicio_get('recargas');
  IF v_hechos NOT LIKE '%PROMOCION VIGENTE HOY%' THEN
    RAISE EXCEPTION 'cerebro_servicio_get must quote the promo valid on the Guyana day, got: %', right(v_hechos, 200);
  END IF;
END $$;

SELECT 'promo-guyana-date assertions: ALL PASSED' AS result;
