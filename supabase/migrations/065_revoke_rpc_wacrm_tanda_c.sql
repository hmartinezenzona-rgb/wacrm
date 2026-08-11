-- ============================================================
-- 065 — Tanda C del REVOKE: funciones de WaCRM (complemento de la 064)
-- ============================================================
-- YA APLICADA EN PRODUCCION el 11-ago-2026 (02:47 UTC) via MCP
-- apply_migration. NO LA EJECUTES: este fichero es el registro.
--
-- Ejecutada por decision de Humberto sin esperar la respuesta de Hermes
-- (avisado por buzon 0212 y por la nota posterior a la aplicacion).
-- Inventario de llamadas, ACLs previas y rollback exacto:
-- ROLLBACK-065-privilegios-antes.md en el directorio del Cerebro.
--
-- Criterio por grupo (inventario .rpc( del repo de WaCRM, 11-ago):
--  * Solo servidor -> fuera PUBLIC/anon/authenticated, queda service_role.
--    Sus llamadores usan supabaseAdmin(): api-context.ts:112 (miembros,
--    transferencia de cuenta), auto-reply.ts, automations/engine.ts,
--    flows/engine.ts, y dispatchWebhookEvent(supabaseAdmin(), ...) en
--    el webhook de WhatsApp. sync_tags_cliente / _bcast_bump /
--    recompute_broadcast_counts las llaman triggers SECURITY DEFINER
--    (corren como dueno, sin chequeo del rol que hace el DML).
--  * touch_presence -> el navegador la llama con sesion: conserva
--    authenticated, pierde PUBLIC y anon.
--  * is_account_member -> la evaluan politicas RLS con el rol de la
--    peticion: conserva anon Y authenticated (quitarle anon convertiria
--    consultas anonimas de "0 filas" en "error de permiso"). Pierde PUBLIC.
--  * peek_invitation / redeem_invitation -> NO tocadas: ya tenian grants
--    explicitos sin PUBLIC (el patron correcto).
--  * Funciones trigger -> NO tocadas: PostgREST no expone funciones que
--    devuelven `trigger` (404), y revocarlas roza el DML sin ganancia.
--
-- Verificado tras aplicar (02:48 UTC): con la clave anon,
-- transfer_account_ownership/set_member_role/record_webhook_failure -> 404,
-- merge_duplicate_contacts/touch_presence -> 401, peek_invitation -> 200
-- (control positivo); CRM / -> 307 y /resumen -> 200. get_advisors: los
-- WARN de anon bajaron de 28 a 16, y los 16 restantes son deliberados
-- (12 triggers no expuestos + is_account_member + peek/redeem).

REVOKE EXECUTE ON FUNCTION
  _bcast_bump(uuid,text,integer),
  claim_ai_reply_slot(uuid,integer),
  increment_automation_execution_count(uuid),
  increment_flow_execution_count(uuid),
  merge_duplicate_contacts(),
  recompute_broadcast_counts(uuid),
  record_webhook_failure(uuid,integer),
  remove_account_member(uuid),
  set_member_role(uuid,account_role_enum),
  sync_tags_cliente(uuid),
  transfer_account_ownership(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  _bcast_bump(uuid,text,integer),
  claim_ai_reply_slot(uuid,integer),
  increment_automation_execution_count(uuid),
  increment_flow_execution_count(uuid),
  merge_duplicate_contacts(),
  recompute_broadcast_counts(uuid),
  record_webhook_failure(uuid,integer),
  remove_account_member(uuid),
  set_member_role(uuid,account_role_enum),
  sync_tags_cliente(uuid),
  transfer_account_ownership(uuid)
TO service_role;

REVOKE EXECUTE ON FUNCTION touch_presence(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION touch_presence(text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION is_account_member(uuid,account_role_enum) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION is_account_member(uuid,account_role_enum)
  TO anon, authenticated, service_role;
