-- ROLLBACK of 128. First remove the 'Guardar lecturas vision' node from the Cerebro (n8n rollback copy).
-- The readings are history: the table is KEPT. Drop it only on an explicit decision:
--   DROP TABLE cerebro_lecturas_vision;
DROP FUNCTION IF EXISTS cerebro_guardar_lecturas_vision(uuid, text, jsonb);
NOTIFY pgrst, 'reload schema';
