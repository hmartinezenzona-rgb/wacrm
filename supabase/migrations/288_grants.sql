-- 288: explicit grants for everything 243 and 265-287 create or replace (production readiness, 2026-10-23).
--
-- Production has NARROW default privileges (functions: postgres only; tables: anon / authenticated / service_role only Dxtm; sequences: postgres only) while staging has broad
-- ones, which is how the 270 incident (service_role without a grant on cerebro_config) stayed invisible on staging. This migration states, for each of the 33 functions and
-- the 2 new tables, the privileges production conventions give them, so that applying the bundle there leaves the same access on both environments:
--   * agent-facing tools (cerebro_*, crm_registrar_*): EXECUTE for service_role only;
--   * panel RPCs: crm_agregar_beneficiario / crm_beneficiarios_completos / crm_corregir_beneficiario: authenticated only; crm_operaciones_de_conversacion,
--     cerebro_dashboard_historial and cerebro_resolver_servicio: authenticated + service_role (as production / 265);
--   * internal helpers (_cerebro_*, _repartir_envio_core, cerebro_minimo_gyd, cerebro_riel_op, ...): postgres only; their callers are SECURITY DEFINER (they run as the owner);
--   * cerebro_servicio_declarado and cerebro_reparto_planeado: RLS on, service_role SELECT / INSERT / UPDATE / DELETE, nobody else.
-- No sequences and no column-level grants are involved (the new remittance_beneficiaries columns clabe / bank_name ride on the table's privileges).
-- Idempotent. calculator_service_for_operation is left as production has it (PUBLIC). Assertion: grants-mirror-production.
-- Rollback: ROLLBACK-288-grants.sql (restores the broad staging state).

-- Functions: explicit state for every function created or replaced by 243 and 265-287 (production default is postgres only).
-- agent-facing: service_role
REVOKE ALL ON FUNCTION public.cerebro_aplicar_servicio(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_aplicar_servicio(uuid, text, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_declarar_servicio(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_declarar_servicio(uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_cotizar(uuid, numeric, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_cotizar(uuid, numeric, text, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_fijar_objetivo(uuid, numeric, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_fijar_objetivo(uuid, numeric, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text, integer, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text, integer, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario_mexico(uuid, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_beneficiario_mexico(uuid, text, text, text, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text, integer, boolean, numeric) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_zelle(uuid, text, text, text, uuid, text, integer, boolean, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_marcar_destino_usd(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_marcar_destino_usd(uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_modificar_operacion(uuid, uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_modificar_operacion(uuid, uuid, text, jsonb, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_registrar_deposito(uuid, numeric, text, uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_deposito(uuid, numeric, text, uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_repartir_envio(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_repartir_envio(uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.crm_registrar_datos_entrega_efectivo(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_registrar_datos_entrega_efectivo(uuid, text, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.crm_registrar_numeros_recarga(uuid, text, boolean, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_registrar_numeros_recarga(uuid, text, boolean, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_parsear_beneficiarios(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_parsear_beneficiarios(text) TO service_role;
-- panel + agent: authenticated, service_role
REVOKE ALL ON FUNCTION public.crm_operaciones_de_conversacion(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_operaciones_de_conversacion(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_dashboard_historial(date, date, text, integer, integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_dashboard_historial(date, date, text, integer, integer) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_resolver_servicio(uuid, text, text, numeric, timestamp with time zone) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_resolver_servicio(uuid, text, text, numeric, timestamp with time zone) TO authenticated, service_role;
-- panel-facing: authenticated
REVOKE ALL ON FUNCTION public.crm_agregar_beneficiario(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_agregar_beneficiario(uuid, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.crm_beneficiarios_completos(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_beneficiarios_completos(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.crm_corregir_beneficiario(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_corregir_beneficiario(uuid, jsonb) TO authenticated;
-- internal helpers: postgres only (SECURITY DEFINER callers run as the owner)
REVOKE ALL ON FUNCTION public._cambiar_servicio_core(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_aplicar_plan_reparto(uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_nombre_servicio(text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_op_parte(uuid, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_op_tiene_dinero(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_operacion_declarada(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_ops_para_datos(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_partes_envio_parse(text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_reparto_planear(uuid, jsonb, boolean, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_servicio_clave(text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_texto_partes(jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._cerebro_usd_parte(text, numeric) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._repartir_envio_core(uuid, jsonb, text, text, text, boolean) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.calculator_resolve_operation_service(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario_auto(uuid, text, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_limpiar_servicio_declarado() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_minimo_gyd(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_resolver_para_guardar(uuid, text, text, jsonb, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_riel_op(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- New tables (production default would give anon / authenticated / service_role only Dxtm): RLS stays on, the bot's service role gets row access.
REVOKE ALL ON TABLE public.cerebro_servicio_declarado FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.cerebro_servicio_declarado TO service_role;
REVOKE ALL ON TABLE public.cerebro_reparto_planeado FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.cerebro_reparto_planeado TO service_role;
