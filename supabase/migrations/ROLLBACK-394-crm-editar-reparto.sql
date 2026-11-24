-- Rollback of 394: drop crm_editar_reparto (a new function; nothing else changed). Shares edited through it stay as they are.
DROP FUNCTION IF EXISTS public.crm_editar_reparto(uuid, jsonb);
