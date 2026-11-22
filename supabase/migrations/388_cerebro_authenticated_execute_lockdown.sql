-- 388_cerebro_authenticated_execute_lockdown.sql
--
-- After 387 removed anon, the four mutating bot functions were still
-- executable by any signed-in user through PostgREST /rpc. Nothing in the
-- app calls them directly: every SQL caller is a SECURITY DEFINER wrapper
-- owned by postgres and restricted to service_role.
--
-- This migration leaves service_role as the only app role with EXECUTE.
-- The external remesas_handoff role keeps the explicit grant it already has
-- on cerebro_registrar_derivacion (not modified here).
--
-- Guarded by supabase/staging/assertions/cerebro-authenticated-execute-lockdown.sql.

REVOKE EXECUTE ON FUNCTION public.cerebro_registrar_derivacion(uuid, text, text, boolean) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.cerebro_liberar_derivacion_ambigua(uuid) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.cerebro_auditoria_semantica_registrar(text, jsonb) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.cerebro_telemetria_registrar(text, jsonb) FROM PUBLIC, authenticated;
