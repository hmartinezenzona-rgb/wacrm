-- =====================================================================
-- Assertion for migration 131 (cerebro_nombre_completa + zelle_nombre_cuenta).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- The node logic itself is benched with its real SQL by pruebas/banco-merge-nombre.py.
-- =====================================================================
DO $$
BEGIN
  IF NOT cerebro_nombre_completa('Nelson Tejo Perez', 'Nelson') THEN RAISE EXCEPTION 'case 1: "Nelson Tejo Perez" completes "Nelson"'; END IF;
  IF NOT cerebro_nombre_completa('Liliana Gonzales Velázquez', 'liliana') THEN RAISE EXCEPTION 'case 1: case and accents are ignored'; END IF;
  RAISE NOTICE 'PASS 1: a written full name completes the label it contains';

  IF cerebro_nombre_completa('Jaime Rodriguez', 'Tata') THEN RAISE EXCEPTION 'case 2: "Jaime Rodriguez" must not complete "Tata"'; END IF;
  IF cerebro_nombre_completa('Nelson', 'Nelson') THEN RAISE EXCEPTION 'case 2: the same name is not a completion'; END IF;
  IF cerebro_nombre_completa('Nelson Tejo', NULL) OR cerebro_nombre_completa(NULL, 'Nelson') OR cerebro_nombre_completa('Ana Perez', '') THEN
    RAISE EXCEPTION 'case 2: NULL or empty never completes';
  END IF;
  RAISE NOTICE 'PASS 2: a different, equal or empty name is not a completion';

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'cerebro_beneficiario_parcial' AND column_name = 'zelle_nombre_cuenta') THEN
    RAISE EXCEPTION 'case 3: cerebro_beneficiario_parcial.zelle_nombre_cuenta is missing';
  END IF;
  RAISE NOTICE 'PASS 3: the accumulated name can be tied to its account';

  IF has_function_privilege('anon', 'cerebro_nombre_completa(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 4: anon must not execute cerebro_nombre_completa';
  END IF;
  RAISE NOTICE 'PASS 4: not exposed to anon';
END $$;

-- Convention: reaching this point means every case above passed.
DO $$ BEGIN RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'; END $$;
