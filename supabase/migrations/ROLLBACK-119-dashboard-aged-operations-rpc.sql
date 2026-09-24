-- ROLLBACK for 119_dashboard_aged_operations_rpc.sql
-- Drops the function. No data to lose — it's read-only.

DROP FUNCTION IF EXISTS cerebro_dashboard_operaciones_envejecidas();
