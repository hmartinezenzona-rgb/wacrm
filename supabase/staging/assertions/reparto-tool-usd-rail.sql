-- =====================================================================
-- Assertion for migration 174 (the LLM reparto tool records Clasica/Tropical shares in USD).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Real case: Kenia 5927478061 (2026-09-29), 30 USD + 20 USD to two Clasica cards, stored as a CUP
-- reparto ("Recibe: 30 CUP").
-- =====================================================================
DO $$
DECLARE v_rows jsonb; v_n int;
BEGIN
  -- 1. The new block format: each share says its currency and rail.
  SELECT jsonb_agg(jsonb_build_object('t', tipo, 'card', tarjeta, 'a', monto, 'c', moneda) ORDER BY posicion), count(*)
    INTO v_rows, v_n
    FROM cerebro_parsear_beneficiarios(
      'REPARTO ENTRE VARIOS BENEFICIARIOS' || chr(10) ||
      '1) Tarjeta: 9760039003648069 | Celular: 52725088 | Recibe: 30 USD Clasica' || chr(10) ||
      '2) Tarjeta: 9760039005544217 | Celular: 59499176 | Recibe: 20 USD Clasica');
  IF v_n <> 2 OR v_rows->0->>'t' <> 'clasica' OR v_rows->0->>'c' <> 'USD' OR (v_rows->0->>'a')::numeric <> 30
     OR v_rows->1->>'t' <> 'clasica' OR (v_rows->1->>'a')::numeric <> 20 THEN
    RAISE EXCEPTION 'case 1: Clasica shares must be clasica/USD, got %', v_rows;
  END IF;

  -- 2. Mixed: one CUP card and one Tropical in the same reparto.
  SELECT jsonb_agg(jsonb_build_object('t', tipo, 'a', monto, 'c', moneda) ORDER BY posicion), count(*)
    INTO v_rows, v_n
    FROM cerebro_parsear_beneficiarios(
      'REPARTO ENTRE VARIOS BENEFICIARIOS' || chr(10) ||
      '1) Tarjeta: 9227959879614050 | Celular: 54363811 | Recibe: 45000 CUP' || chr(10) ||
      '2) Tarjeta: 9760039001240356 | Celular: 58528291 | Recibe: 192 USD Tropical');
  IF v_n <> 2 OR v_rows->0->>'t' <> 'multiple_distribution' OR v_rows->0->>'c' <> 'CUP'
     OR v_rows->1->>'t' <> 'tropical' OR v_rows->1->>'c' <> 'USD' THEN
    RAISE EXCEPTION 'case 2: CUP + Tropical, got %', v_rows;
  END IF;

  -- 3. Blocks already in the database (old format) still read the same.
  SELECT count(*) INTO v_n
    FROM cerebro_parsear_beneficiarios(
      'REPARTO ACTUALIZADO ENTRE VARIOS BENEFICIARIOS - reemplaza lo anterior' || chr(10) ||
      '1) Tarjeta: 9760039003648069 | Celular: 52725088 | Recibe: 30 CUP' || chr(10) ||
      '2) Tarjeta: 9760039005544217 | Celular: 59499176 | Recibe: 20 CUP')
   WHERE tipo = 'multiple_distribution' AND moneda = 'CUP';
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 3: old CUP blocks must still parse, got %', v_n; END IF;

  -- 4. "unas tarjetas clasicas" (plural) names the Clasica rail.
  IF cerebro_detectar_destino('Lo otro a unas tarjetas clásicas') IS DISTINCT FROM 'clasica'
     OR cerebro_detectar_destino('a las tropicales') IS DISTINCT FROM 'tropical'
     OR cerebro_detectar_destino('esa tarjeta clásica') IS DISTINCT FROM 'clasica' THEN
    RAISE EXCEPTION 'case 4: plural rail names not detected';
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
