-- 387_cerebro_anon_execute_lockdown.sql
--
-- Seven internal SECURITY DEFINER functions kept PostgreSQL's default
-- EXECUTE grant to PUBLIC, so the public anon key could call bot internals:
-- derivation, semantic audit, telemetry, combo state and USD_MXN rates.
--
-- Revoking from PUBLIC is the only way to remove anon's inherited EXECUTE.
-- authenticated and service_role keep the access they had, following the
-- existing pattern in 297_tasa_usd_mxn.sql.
--
-- peek_invitation is intentionally anonymous (019: the /join/<token> page
-- calls it before sign-in) and is NOT touched here.
--
-- Guarded by supabase/staging/assertions/cerebro-anon-execute-lockdown.sql.

REVOKE ALL ON FUNCTION public.cerebro_registrar_derivacion(uuid, text, text, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cerebro_liberar_derivacion_ambigua(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cerebro_auditoria_semantica_registrar(text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cerebro_telemetria_registrar(text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cerebro_combo_en_curso(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cerebro_tasa_usd_mxn() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cerebro_tasa_usd_mxn_info() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.cerebro_registrar_derivacion(uuid, text, text, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_liberar_derivacion_ambigua(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_auditoria_semantica_registrar(text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_telemetria_registrar(text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_combo_en_curso(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_tasa_usd_mxn() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_tasa_usd_mxn_info() TO authenticated, service_role;
