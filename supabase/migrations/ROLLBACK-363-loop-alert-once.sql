-- ROLLBACK for 363: removes cerebro_control_bucle. The n8n node `Control de abuso` must be restored first (it calls this function).
-- cerebro_registrar_derivacion and cerebro_control_abuso were not touched by 363.

DROP FUNCTION IF EXISTS public.cerebro_control_bucle(uuid, boolean, integer, boolean, integer);
