-- =====================================================================
-- Assertion for migration 205 (special closed days). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- Owner, 2026-10-03: Monday 2026-10-05 the business does not work (anniversary); the bot answers that day as out of
-- hours, all day, saying why, and points work to the next business day. The closed days live in cerebro_config
-- 'dias_cerrados' (JSON list of {"fecha","motivo"}); Sundays stay closed as always.
-- =====================================================================
DO $$
DECLARE v_info jsonb;
BEGIN
  UPDATE cerebro_config SET valor = '[{"fecha": "2026-10-05", "motivo": "el aniversario de Remesas Ya"}]' WHERE clave = 'dias_cerrados';
  IF NOT FOUND THEN
    INSERT INTO cerebro_config (clave, valor) VALUES ('dias_cerrados', '[{"fecha": "2026-10-05", "motivo": "el aniversario de Remesas Ya"}]');
  END IF;

  -- 1. The closed day and its reason; an ordinary day is open.
  IF cerebro_dia_cerrado('2026-10-05') IS DISTINCT FROM 'el aniversario de Remesas Ya' OR cerebro_dia_cerrado('2026-10-06') IS NOT NULL THEN
    RAISE EXCEPTION 'case 1: got % / %', cerebro_dia_cerrado('2026-10-05'), cerebro_dia_cerrado('2026-10-06'); END IF;

  -- 2. The next business day skips Sunday and the closed Monday.
  IF cerebro_proximo_dia_habil('2026-10-03') IS DISTINCT FROM '2026-10-06'::date   -- from Saturday
     OR cerebro_proximo_dia_habil('2026-10-04') IS DISTINCT FROM '2026-10-06'::date -- from Sunday
     OR cerebro_proximo_dia_habil('2026-10-05') IS DISTINCT FROM '2026-10-06'::date -- from the closed Monday
     OR cerebro_proximo_dia_habil('2026-10-06') IS DISTINCT FROM '2026-10-07'::date THEN
    RAISE EXCEPTION 'case 2: next business days wrong'; END IF;

  -- 3. What the bot reads: on the closed day / the day before / a normal week.
  v_info := cerebro_cierre_especial_info('2026-10-05');
  IF v_info ->> 'hoy_motivo' IS DISTINCT FROM 'el aniversario de Remesas Ya' OR v_info ->> 'proximo_habil' IS DISTINCT FROM 'mañana martes 6' THEN
    RAISE EXCEPTION 'case 3 (Monday): got %', v_info; END IF;
  v_info := cerebro_cierre_especial_info('2026-10-04');
  IF v_info ->> 'hoy_motivo' IS NOT NULL OR v_info ->> 'proximo_habil' IS DISTINCT FROM 'el martes 6'
     OR v_info ->> 'proximo_cierre' IS DISTINCT FROM 'mañana lunes 5 no trabajamos por el aniversario de Remesas Ya' THEN
    RAISE EXCEPTION 'case 3 (Sunday): got %', v_info; END IF;
  v_info := cerebro_cierre_especial_info('2026-10-03');
  IF v_info ->> 'proximo_habil' IS DISTINCT FROM 'el martes 6'
     OR v_info ->> 'proximo_cierre' IS DISTINCT FROM 'el lunes 5 no trabajamos por el aniversario de Remesas Ya' THEN
    RAISE EXCEPTION 'case 3 (Saturday): got %', v_info; END IF;
  v_info := cerebro_cierre_especial_info('2026-10-13');
  IF v_info ->> 'hoy_motivo' IS NOT NULL OR v_info ->> 'proximo_cierre' IS NOT NULL OR v_info ->> 'proximo_habil' IS DISTINCT FROM 'mañana miércoles 14' THEN
    RAISE EXCEPTION 'case 3 (normal Tuesday): got %', v_info; END IF;

  -- 4. A broken or empty config closes nothing.
  UPDATE cerebro_config SET valor = 'no es json' WHERE clave = 'dias_cerrados';
  IF cerebro_dia_cerrado('2026-10-05') IS NOT NULL THEN RAISE EXCEPTION 'case 4: a broken config must close nothing'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
