-- ROLLBACK for 097_operaciones_de_conversacion_rpc.sql
--
-- Drops the read-only RPC. Nothing else changed by 097 — no new table, no
-- new column, no trigger. Safe to run even if 097 only partially applied.

DROP FUNCTION IF EXISTS crm_operaciones_de_conversacion(uuid);
