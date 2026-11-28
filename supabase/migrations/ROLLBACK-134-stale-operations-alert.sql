-- ROLLBACK for 134. Deactivate the n8n workflow "Vigilante - remesas abiertas viejas" first.
-- Notifications already created are kept (nothing historical is deleted), so the type stays allowed.
DROP FUNCTION IF EXISTS cerebro_avisar_remesas_abiertas_viejas(integer, boolean);
NOTIFY pgrst, 'reload schema';
