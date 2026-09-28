-- =====================================================================
-- Assertion for migration 138 (service catalog from one place).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- =====================================================================
DO $$
DECLARE v_cat text; v_n int;
BEGIN
  -- 1. The 6 existing services all have resumen/palabras_clave filled in
  --    (backfill ran) and appear in the compact catalog.
  IF EXISTS (SELECT 1 FROM cerebro_servicios
              WHERE clave IN ('combos','recargas','visa','traduccion','mexico','efectivo_usd')
                AND (resumen IS NULL OR palabras_clave IS NULL OR array_length(palabras_clave,1) IS NULL)) THEN
    RAISE EXCEPTION 'case 1: some existing service is missing resumen or palabras_clave';
  END IF;
  SELECT cerebro_catalogo_servicios() INTO v_cat;
  IF v_cat !~ '- combos:' OR v_cat !~ '- recargas:' OR v_cat !~ '- visa:'
     OR v_cat !~ '- traduccion:' OR v_cat !~ '- mexico:' OR v_cat !~ '- efectivo_usd:' THEN
    RAISE EXCEPTION 'case 1: the catalog is missing one of the 6 backfilled services: %', v_cat;
  END IF;
  RAISE NOTICE 'PASS 1: the 6 backfilled services are all in the compact catalog';

  -- 2. Inserting a new ACTIVE row adds it to the catalog, with no prompt
  --    or function edit -- the key acceptance criterion of the feature.
  INSERT INTO cerebro_servicios (clave, nombre, activo, hechos, resumen, palabras_clave, requiere_humano)
  VALUES ('zz_test_catalogo', 'Servicio de prueba (assertion, se revierte)', true,
          'Fila de prueba solo para esta assertion.', 'Resumen de prueba.',
          ARRAY['prueba-catalogo-138'], false);
  SELECT cerebro_catalogo_servicios() INTO v_cat;
  IF v_cat !~ '- zz_test_catalogo:' THEN
    RAISE EXCEPTION 'case 2: an INSERTed active row must appear in the catalog, got: %', v_cat;
  END IF;
  RAISE NOTICE 'PASS 2: an INSERT adds the row to the catalog';

  -- 3. Switching it off (activo=false) removes it, again with zero edits
  --    elsewhere.
  UPDATE cerebro_servicios SET activo = false WHERE clave = 'zz_test_catalogo';
  SELECT cerebro_catalogo_servicios() INTO v_cat;
  IF v_cat ~ '- zz_test_catalogo:' THEN
    RAISE EXCEPTION 'case 3: activo=false must remove the row from the catalog, got: %', v_cat;
  END IF;
  RAISE NOTICE 'PASS 3: activo=false removes the row from the catalog';

  -- 4. Token budget: < 400 tokens for ~7 services. Approximated as
  --    chars/4, the same heuristic used while drafting the catalog text.
  UPDATE cerebro_servicios SET activo = true WHERE clave = 'zz_test_catalogo';
  SELECT cerebro_catalogo_servicios() INTO v_cat;
  IF length(v_cat) / 4 > 400 THEN
    RAISE EXCEPTION 'case 4: catalog too big, ~% tokens (chars/4) for 7 services: %', length(v_cat)/4, v_cat;
  END IF;
  RAISE NOTICE 'PASS 4: catalog ~% tokens (chars/4) for 7 services, under the 400 budget', length(v_cat)/4;

  IF has_function_privilege('anon', 'cerebro_catalogo_servicios()', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 5: anon must not execute cerebro_catalogo_servicios';
  END IF;
  RAISE NOTICE 'PASS 5: not exposed to anon';
END $$;
