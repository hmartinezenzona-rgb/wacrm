-- ROLLBACK of 236_calculator_entry_investment_rates.sql: drops the investment-rates correction RPC. Nothing else was created or replaced by 236
-- (the lock trigger and every Finanzas function are unchanged). Entries whose rates and invertido/retorno were edited through it keep those
-- figures: they are real data and, by owner decision, were never audited, so the previous values cannot be restored from the database.
-- No BEGIN/COMMIT.

DROP FUNCTION IF EXISTS public.crm_corregir_tasas_entrada_calculadora(uuid, numeric, numeric);
