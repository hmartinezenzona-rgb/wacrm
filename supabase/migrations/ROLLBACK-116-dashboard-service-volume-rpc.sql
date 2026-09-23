-- =====================================================================
-- ROLLBACK-116 — reverts 116_dashboard_service_volume_rpc.sql
--
-- Safe to run any time: this function is a pure, stateless read (no
-- table/column changes, no data written through it). Dropping it only
-- breaks the /dashboard service-volume widget's data fetch until 116 is
-- re-applied.
-- =====================================================================

DROP FUNCTION IF EXISTS cerebro_dashboard_volumen_por_servicio();
