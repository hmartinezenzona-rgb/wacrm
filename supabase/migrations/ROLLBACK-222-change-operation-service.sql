-- ROLLBACK of 222_change_operation_service.sql: removes the RPC. Nothing else changed in the schema; operations already
-- switched keep their data (and their human_correction audit rows with field_name 'service').
DROP FUNCTION IF EXISTS public.crm_cambiar_servicio(uuid, text);
