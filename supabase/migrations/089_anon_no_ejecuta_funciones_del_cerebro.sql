-- =====================================================================
-- 089 — `anon` no puede ejecutar las funciones del Cerebro
--
--   YA APLICADA EN PRODUCCION EL 14-AGO-2026 (10:50 UTC). NO LA REPITAS.
--
-- QUE SE ENCONTRO (revisando el ACL de la 088)
--
--   Cinco funciones del esquema public podia ejecutarlas **anon**, o
--   sea CUALQUIERA con la clave publica del navegador, sin sesion:
--
--     cerebro_outbox_reclamar(integer)        <- la peor
--     cerebro_outbox_encolar(uuid,text,text,uuid,text)
--     cerebro_outbox_resultado(uuid,boolean,text,text)
--     cerebro_ejecutar_tool_dsml(text,jsonb,uuid)
--     cerebro_avisar_chats_atascados(integer,integer)
--
--   `cerebro_outbox_reclamar(10)` es la que mas duele y solo pide un
--   numero: quien la llame se lleva los mensajes pendientes marcados
--   como reclamados, y el enviador de verdad no encuentra nada que
--   enviar. Los clientes dejarian de recibir respuestas **en silencio**.
--   `cerebro_outbox_encolar` es la simetrica: encolar un WhatsApp.
--
--   No es culpa de nadie en concreto: nacieron despues de la 064 y el
--   `ALTER DEFAULT PRIVILEGES` de aquella no las cubrio (su ACL quedo
--   en NULL, que en Postgres significa "EXECUTE para PUBLIC").
--
-- POR QUE ESTO NO ROMPE NADA
--
--   Quien las usa es n8n, y n8n entra por **conexion directa de
--   Postgres** —nodo Postgres, documentado en PLAN-2E-outbox.md y en el
--   comentario de la 055—, o sea con un rol de base de datos, no por
--   PostgREST. Comprobado ademas en `pg_stat_activity`: la conexion de
--   n8n llega por Supavisor con el rol **postgres**, que es el dueno de
--   las funciones y conserva EXECUTE pase lo que pase.
--   En el codigo de WaCRM no hay ni una llamada a ninguna de las cinco
--   (`grep` en todo el repo: cero, solo documentacion).
--   Aun asi se les da GRANT explicito a `authenticated` y
--   `service_role`, para que cualquier camino con sesion o con clave de
--   servicio siga funcionando igual. **El unico que pierde acceso es
--   `anon`**, que es precisamente el que no deberia tenerlo.
--
-- COMPROBADO DESPUES
--   Las 46 funciones `cerebro_*` llamables (las que no son de trigger)
--   dan `has_function_privilege('anon', ..., 'EXECUTE') = false`.
--
-- ROLLBACK (si algo dejara de funcionar, aunque no deberia)
--   GRANT EXECUTE ON FUNCTION <la firma> TO PUBLIC;
-- =====================================================================

REVOKE EXECUTE ON FUNCTION
  public.cerebro_outbox_reclamar(integer),
  public.cerebro_outbox_encolar(uuid, text, text, uuid, text),
  public.cerebro_outbox_resultado(uuid, boolean, text, text),
  public.cerebro_ejecutar_tool_dsml(text, jsonb, uuid),
  public.cerebro_avisar_chats_atascados(integer, integer)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
  public.cerebro_outbox_reclamar(integer),
  public.cerebro_outbox_encolar(uuid, text, text, uuid, text),
  public.cerebro_outbox_resultado(uuid, boolean, text, text),
  public.cerebro_ejecutar_tool_dsml(text, jsonb, uuid),
  public.cerebro_avisar_chats_atascados(integer, integer)
TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
