-- ROLLBACK for 117_dashboard_operations_in_progress_rpc.sql
-- Drops the function. No data to lose — it's read-only.

DROP FUNCTION IF EXISTS cerebro_dashboard_operaciones_en_curso();
