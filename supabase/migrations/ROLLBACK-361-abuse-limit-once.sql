-- ROLLBACK for 361: removes cerebro_control_abuso. The n8n node `Control de abuso` must be restored first (it calls this function).
-- cerebro_registrar_derivacion was not touched by 361.

DROP FUNCTION IF EXISTS public.cerebro_control_abuso(uuid, integer);
