-- ROLLBACK 368 — drop the repetition facts function. Run AFTER removing the `repeticion` column from the n8n node "Historial contacto",
-- or that node will fail calling a missing function.
DROP FUNCTION IF EXISTS cerebro_repeticion_turno(uuid);
