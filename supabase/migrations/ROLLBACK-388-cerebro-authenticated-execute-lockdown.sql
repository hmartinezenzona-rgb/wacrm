-- ROLLBACK-388-cerebro-authenticated-execute-lockdown.sql
--
-- Restores the exact post-387 state: authenticated holds EXECUTE on the four
-- functions again; PUBLIC stays revoked (387 did that). remesas_handoff was
-- never modified by 388.
--
-- Rolling back re-opens authenticated execution of bot internals: use only to
-- undo 388 immediately after applying it.

GRANT EXECUTE ON FUNCTION public.cerebro_registrar_derivacion(uuid, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_liberar_derivacion_ambigua(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_auditoria_semantica_registrar(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_telemetria_registrar(text, jsonb) TO authenticated;
