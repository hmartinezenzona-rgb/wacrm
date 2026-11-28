-- ROLLBACK for 118_dashboard_operations_funnel_rpc.sql
-- Drops the function. No data to lose — it's read-only.

DROP FUNCTION IF EXISTS cerebro_dashboard_embudo_operaciones();
