-- ROLLBACK-387-cerebro-anon-execute-lockdown.sql
--
-- Restores the exact pre-387 state: PUBLIC holds EXECUTE on the seven
-- functions again (which implies every role, including anon), and the
-- explicit grants added by 387 are removed.
--
-- Rolling back re-opens anon execution of bot internals: use only to undo
-- 387 immediately after applying it.

REVOKE ALL ON FUNCTION public.cerebro_registrar_derivacion(uuid, text, text, boolean) FROM authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_liberar_derivacion_ambigua(uuid) FROM authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_auditoria_semantica_registrar(text, jsonb) FROM authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_telemetria_registrar(text, jsonb) FROM authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_combo_en_curso(uuid) FROM authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_tasa_usd_mxn() FROM authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_tasa_usd_mxn_info() FROM authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.cerebro_registrar_derivacion(uuid, text, text, boolean) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.cerebro_liberar_derivacion_ambigua(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.cerebro_auditoria_semantica_registrar(text, jsonb) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.cerebro_telemetria_registrar(text, jsonb) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.cerebro_combo_en_curso(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.cerebro_tasa_usd_mxn() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.cerebro_tasa_usd_mxn_info() TO PUBLIC;
