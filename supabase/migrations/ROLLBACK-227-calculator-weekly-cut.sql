-- ROLLBACK of 227_calculator_weekly_cut.sql: drops crm_cerrar_semana_calculadora, the calculator_current_entries view and
-- the two archive tables. Nothing else was redefined. It refuses (and changes nothing) when an archived week exists: the
-- archived texts and totals would be lost, and the Calculator would show the archived lines again; export or keep them
-- first.
DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM remittance_calculator_weeks) THEN
    RAISE EXCEPTION 'rollback 227 refused: archived calculator weeks exist';
  END IF;
END $guard$;

DROP FUNCTION IF EXISTS public.crm_cerrar_semana_calculadora(uuid, text, text, numeric, numeric, numeric);
DROP VIEW IF EXISTS public.calculator_current_entries;
DROP TABLE IF EXISTS remittance_calculator_week_entries;
DROP TABLE IF EXISTS remittance_calculator_weeks;
