-- =====================================================================
-- 044 — Fase 2, tramo 2D: registro de llamadas e idempotencia
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
--   SEGUNDO INTENTO. El primero rompio produccion (ver PENDIENTES.md).
--
-- ROLLBACK
--   Restaurar el workflow desde ROLLBACK-v2-antes-2D.json
--   DROP TABLE IF EXISTS tool_execution_log;
-- =====================================================================

CREATE TABLE IF NOT EXISTS tool_execution_log (
  id               uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  idempotency_key  text NOT NULL UNIQUE,
  tool_name        text NOT NULL,
  execution_id     text,
  conversation_id  uuid,
  operation_id     uuid,
  arguments        jsonb,
  outcome          text,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tel_conv_idx ON tool_execution_log (conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS tel_exec_idx ON tool_execution_log (execution_id);
CREATE INDEX IF NOT EXISTS tel_tool_idx ON tool_execution_log (tool_name, created_at DESC);

COMMENT ON TABLE tool_execution_log IS
  'Fase 2 tramo 2D. Una fila por llamada efectiva a una escritura del Cerebro. '
  'Clave: execution_id de n8n + nombre + md5 de argumentos, construida en SQL. '
  'El modelo NO la ve ni la inventa. Purgar a 90 dias.';


-- =====================================================================
-- LOS CINCO NODOS DEL CEREBRO (no es SQL de migracion)
--
-- En `T3v07IQqtMs6AKJ4` se anadio a cada escritura, tras el CTE `res`:
--
--   idem AS (SELECT $N || ':<tool>:' || md5(coalesce($2,'')||'|'||...) AS k),
--   reg  AS (INSERT INTO tool_execution_log (...)
--            SELECT (SELECT k FROM idem), '<tool>', $N, $1::uuid,
--                   (SELECT operation_id FROM res),
--                   jsonb_build_array(to_jsonb($2::text), ...)
--            ON CONFLICT (idempotency_key) DO NOTHING RETURNING id),
--
-- y a `queryReplacement` se le anadio `$execution.id` al final del array.
-- El parametro lo pone el WORKFLOW, no el modelo: el agente sigue viendo
-- exactamente las mismas herramientas que antes.
--
-- **EL CAST `::text` NO ES OPCIONAL.** Sin el, Postgres no puede inferir
-- el tipo del parametro dentro de `to_jsonb()` y la query revienta EN
-- EJECUCION con:
--     could not determine polymorphic type because input has type unknown
-- Eso es exactamente lo que tumbo `Registrar beneficiario auto` en el
-- primer intento.
--
-- Solo `registrar_reparto_multiple` CONDICIONA su escritura al log
-- (`AND EXISTS (SELECT 1 FROM reg)`), porque es la unica de las cinco
-- que no tenia guarda de duplicado propia. Las otras cuatro ya la
-- tienen (`mismos_datos`, `ya_marcado`) y solo registran.
--
-- ---------------------------------------------------------------------
-- QUE PROTEGE ESTA CLAVE, Y QUE NO — leerlo antes de confiar en ella
-- ---------------------------------------------------------------------
--
-- La clave lleva el `execution_id` de n8n. Por tanto:
--
--   SI protege de que el agente llame DOS VECES a la misma herramienta
--   con los mismos argumentos DENTRO DEL MISMO TURNO.
--
--   NO protege del reintento de un lote: un reintento es una ejecucion
--   NUEVA de n8n, con `execution_id` distinto, luego clave distinta.
--
-- Para cubrir tambien los reintentos habria que anclar la clave a algo
-- estable entre ellos (el `whatsapp_message_id` del mensaje que origino
-- el lote, por ejemplo) en vez de al `execution_id`. No se hizo: cambiar
-- el ancla es un rediseño, no un ajuste, y las cuatro tools con guarda
-- por contenido ya son idempotentes de hecho.
--
-- ---------------------------------------------------------------------
-- LIMITACION CONOCIDA: operation_id suele quedar NULL
-- ---------------------------------------------------------------------
-- En el camino de CREACION (no habia envio abierto), la operacion aun no
-- existe cuando corre la tool: la crea el trigger junto con el deal, un
-- instante despues. El log guarda NULL en esos casos. Se puede rellenar
-- despues cruzando por conversacion y hora si alguna vez hace falta.
--
-- =====================================================================
-- COMO SE PROBO (9-ago-2026), segundo intento
--
--   1. Fragmentos aislados (`idem` + `reg` solos) de los tres patrones
--      con mas parametros: compilan. En aislamiento el parametro no
--      tiene ningun otro uso que lo tipe, asi que es una prueba MAS
--      estricta que la query completa.
--   2. **PREPARE de las CINCO queries completas.** Sin excepciones.
--      Las cinco compilan y ninguna cambia su firma de parametros.
--   3. End-to-end contra la ruta que corre DE VERDAD
--      (`Registrar beneficiario auto`, no las tools del agente):
--      fila en el log con execution_id 25172, argumentos correctos, y
--      deal + operacion + beneficiario encadenados. 0 divergencias.
-- =====================================================================
