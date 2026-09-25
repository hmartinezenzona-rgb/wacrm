-- ROLLBACK for 121_financial_close_rpc.sql
-- Drops the function. No data to lose — it's read-only.

DROP FUNCTION IF EXISTS public.crm_cierre_financiero(date, date);
