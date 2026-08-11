-- ============================================================
-- 064 — REVOKE de las funciones cerebro_* expuestas por PostgREST
-- ============================================================
-- YA APLICADA EN PRODUCCION el 11-ago-2026 (01:56 UTC) via MCP
-- apply_migration. NO LA EJECUTES: este fichero es el registro.
--
-- Hallazgo 1 (CRITICO) de la auditoria del 11-ago: las 56 funciones
-- SECURITY DEFINER de `public` eran ejecutables por `anon` y
-- `authenticated` via /rest/v1/rpc/ — incluida cerebro_config_get,
-- que devuelve el secreto del canal de notificacion, y las que
-- mueven dinero (registrar/cruzar depositos, completar lotes).
--
-- LA TRAMPA QUE CAMBIO EL SQL DEL PLAN: el permiso NO venia de un
-- grant a `anon` — venia de PUBLIC (default de Postgres: proacl NULL
-- o `=X/postgres`). Un `REVOKE ... FROM anon` a secas no quitaba
-- nada. Por eso se revoca PUBLIC y se re-otorga selectivo.
--
-- Quien NO se ve afectado:
--   * n8n — entra por Postgres directo como rol `postgres`
--     (propietario): verificado en pg_stat_activity (Supavisor).
--   * WaCRM servidor — usa service_role (supabaseAdmin), que aqui
--     recibe GRANT explicito de seguro.
--   * Las funciones de WaCRM (invitaciones, miembros, presencia,
--     broadcast, IA, contactos) NO se tocan: tanda C, de Hermes.
--   * Las funciones TRIGGER (cerebro_sync_benef_trigger,
--     cerebro_sync_operacion_desde_deal, etc.) se dejan a proposito:
--     PostgREST no expone funciones que devuelven `trigger` (404) y
--     revocarles EXECUTE roza el DML de deals sin ganancia real.
--
-- Lo que el CRM llama desde el NAVEGADOR (inventario .rpc( del repo
-- de WaCRM, 11-ago) y conserva `authenticated`:
--   cerebro_dashboard_resumen, cerebro_dashboard_historial (/resumen),
--   cerebro_promo_pendiente, cerebro_promo_confirmar_pendiente
--   (pantalla de notificaciones / boton de confirmar promo).
--
-- Como se verifico (11-ago 01:57-02:05 UTC):
--   1. has_function_privilege: anon=false en todo cerebro_* invocable;
--      authenticated solo true en las 4 del navegador.
--   2. HTTP real con la clave anon: cerebro_config_get -> 404,
--      cerebro_registrar_deposito -> 404, cerebro_promo_confirmar -> 404,
--      cerebro_dashboard_resumen -> 401; control positivo
--      peek_invitation -> 200 (PostgREST y la clave, intactos).
--   3. /resumen del CRM -> 200.
--   4. Los 5 vigilantes + cron de reintentos en success DESPUES de
--      aplicar (ejecuciones 28243-28250, 02:00-02:01 UTC).
--   5. Mensaje real a la conversacion de pruebas: el Cerebro responde
--      y el lote se cierra (ver fichero 24).
--   6. get_advisors: de 28 WARN anon_security_definer quedan 26 de
--      WaCRM (Hermes, tanda C) + 2 triggers del Cerebro (no expuestos).
--
-- Rollback: ROLLBACK-064-privilegios-antes.md (GRANT ... TO PUBLIC).

-- Bloque A: funciones internas del Cerebro — nada del navegador las llama.
REVOKE EXECUTE ON FUNCTION
  cerebro_avisar_chats_atascados(integer,integer),
  cerebro_avisar_mensajes_fallidos(integer),
  cerebro_avisar_mensajes_perdidos(integer,integer),
  cerebro_completar_lote(text),
  cerebro_config_get(text),
  cerebro_conversacion_no_vista(uuid),
  cerebro_cruzar_deposito(uuid,text,numeric,uuid,uuid,uuid,boolean),
  cerebro_es_revendedor(uuid),
  cerebro_estado_desde_etapa(uuid),
  cerebro_liberar_lote(text,text),
  cerebro_op_transicion_valida(text,text),
  cerebro_outbox_encolar(uuid,text,text,uuid,text),
  cerebro_parsear_beneficiarios(text),
  cerebro_promo_confirmar(uuid,text),
  cerebro_promo_proxima(),
  cerebro_promo_registrar(numeric,numeric,numeric,date,date,text,text,text),
  cerebro_promo_revision(jsonb),
  cerebro_promo_vigente(),
  cerebro_purgar_logs(),
  cerebro_reclamar_lote(uuid,text),
  cerebro_reclamar_reintentos(uuid),
  cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text),
  cerebro_registrar_ejecucion(text,text,text,uuid,text),
  cerebro_rescatar_huerfanos(integer),
  cerebro_resolver_operacion(uuid),
  cerebro_resolver_operacion(uuid,text[]),
  cerebro_servicio_get(text),
  cerebro_sync_beneficiarios(uuid),
  cerebro_volumen(date,date)
FROM PUBLIC, anon, authenticated;

-- service_role explicito, de seguro: es clave de servidor, nunca del navegador.
GRANT EXECUTE ON FUNCTION
  cerebro_avisar_chats_atascados(integer,integer),
  cerebro_avisar_mensajes_fallidos(integer),
  cerebro_avisar_mensajes_perdidos(integer,integer),
  cerebro_completar_lote(text),
  cerebro_config_get(text),
  cerebro_conversacion_no_vista(uuid),
  cerebro_cruzar_deposito(uuid,text,numeric,uuid,uuid,uuid,boolean),
  cerebro_es_revendedor(uuid),
  cerebro_estado_desde_etapa(uuid),
  cerebro_liberar_lote(text,text),
  cerebro_op_transicion_valida(text,text),
  cerebro_outbox_encolar(uuid,text,text,uuid,text),
  cerebro_parsear_beneficiarios(text),
  cerebro_promo_confirmar(uuid,text),
  cerebro_promo_proxima(),
  cerebro_promo_registrar(numeric,numeric,numeric,date,date,text,text,text),
  cerebro_promo_revision(jsonb),
  cerebro_promo_vigente(),
  cerebro_purgar_logs(),
  cerebro_reclamar_lote(uuid,text),
  cerebro_reclamar_reintentos(uuid),
  cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text),
  cerebro_registrar_ejecucion(text,text,text,uuid,text),
  cerebro_rescatar_huerfanos(integer),
  cerebro_resolver_operacion(uuid),
  cerebro_resolver_operacion(uuid,text[]),
  cerebro_servicio_get(text),
  cerebro_sync_beneficiarios(uuid),
  cerebro_volumen(date,date)
TO service_role;

-- Bloque B: las 4 que el CRM llama desde el navegador con sesion iniciada.
REVOKE EXECUTE ON FUNCTION
  cerebro_dashboard_resumen(),
  cerebro_dashboard_historial(date,date,text,integer),
  cerebro_promo_pendiente(),
  cerebro_promo_confirmar_pendiente(text)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
  cerebro_dashboard_resumen(),
  cerebro_dashboard_historial(date,date,text,integer),
  cerebro_promo_pendiente(),
  cerebro_promo_confirmar_pendiente(text)
TO authenticated, service_role;

-- Bloque C: cerrar el grifo para el futuro. Sin esto, cada funcion nueva
-- nace con EXECUTE para PUBLIC y reabre el agujero. OJO PARA MIGRACIONES
-- FUTURAS (mias y de Hermes): una funcion nueva que el navegador deba
-- llamar necesita ahora su GRANT EXECUTE ... TO authenticated explicito.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM authenticated;
