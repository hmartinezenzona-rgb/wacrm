-- =====================================================================
--  037 — Esquema del Cerebro
--
--  El Cerebro es el bot de WhatsApp que atiende las remesas. Vive en
--  n8n, no en esta aplicacion, pero comparte esta misma base de datos.
--  Sus tablas nunca se versionaron aqui, asi que una reconstruccion
--  desde cero dejaria al bot sin nada donde escribir.
--
--  ESTADO: todo esto YA ESTA APLICADO en produccion. Esta migracion es
--  historial y reconstruccion. Es idempotente de principio a fin, asi
--  que correrla contra una base que ya la tiene no hace nada.
--
--  Generada desde el esquema real de produccion el 2026-08-07.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. EVENTOS ENTRANTES
--    Cada mensaje que llega se guarda aqui antes de procesarse. El
--    Cerebro agrupa por rafagas (debounce) y reclama lotes enteros.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS session_events (
  id                      bigserial PRIMARY KEY,
  conversation_id         uuid        NOT NULL,
  contact_phone           text        NOT NULL,
  tipo                    text        NOT NULL,
  contenido               text,
  whatsapp_message_id     text,
  procesado               boolean     NOT NULL DEFAULT false,
  creado_at               timestamptz NOT NULL DEFAULT now(),
  processing_status       text        NOT NULL DEFAULT 'pending',
  processing_execution_id text,
  processing_started_at   timestamptz,
  processed_at            timestamptz,
  retry_count             integer     NOT NULL DEFAULT 0,
  last_error              text,
  next_retry_at           timestamptz
);

-- Para bases que ya tenian la tabla antes de la Fase 1.
ALTER TABLE session_events
  ADD COLUMN IF NOT EXISTS processing_status       text        NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS processing_execution_id text,
  ADD COLUMN IF NOT EXISTS processing_started_at   timestamptz,
  ADD COLUMN IF NOT EXISTS processed_at            timestamptz,
  ADD COLUMN IF NOT EXISTS retry_count             integer     NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_error              text,
  ADD COLUMN IF NOT EXISTS next_retry_at           timestamptz;

DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'session_events_procstatus_chk') THEN
    ALTER TABLE session_events
      ADD CONSTRAINT session_events_procstatus_chk
      CHECK (processing_status IN ('pending','processing','completed','retry_wait','permanent_error'));
  END IF;
END $mig$;

-- Idempotencia: un mismo mensaje de WhatsApp no puede entrar dos veces.
CREATE UNIQUE INDEX IF NOT EXISTS ux_session_events_conv_wamid
  ON session_events (conversation_id, whatsapp_message_id)
  WHERE whatsapp_message_id IS NOT NULL AND whatsapp_message_id <> '';

CREATE INDEX IF NOT EXISTS idx_session_events_conv_pend
  ON session_events (conversation_id, procesado, creado_at);
CREATE INDEX IF NOT EXISTS idx_session_events_reclamar
  ON session_events (conversation_id, id)
  WHERE processing_status IN ('pending','retry_wait');
CREATE INDEX IF NOT EXISTS idx_session_events_retry
  ON session_events (next_retry_at) WHERE processing_status = 'retry_wait';
CREATE INDEX IF NOT EXISTS idx_session_events_processing
  ON session_events (processing_started_at) WHERE processing_status = 'processing';

-- ---------------------------------------------------------------------
-- 2. CORRELACION DE EJECUCIONES
--    Una fila por ejecucion del workflow. Permite al manejador de
--    errores saber que conversacion fallo sin adivinarlo.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cerebro_ejecuciones (
  execution_id    text PRIMARY KEY,
  workflow_id     text,
  workflow_name   text,
  conversation_id uuid,
  status          text        NOT NULL DEFAULT 'running',
  started_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz,
  retry_count     integer     NOT NULL DEFAULT 0,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

DO $mig$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cerebro_ejecuciones_status_chk') THEN
    ALTER TABLE cerebro_ejecuciones ADD CONSTRAINT cerebro_ejecuciones_status_chk
      CHECK (status IN ('running','completed','failed','permanent_error'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cerebro_ejecuciones_retry_chk') THEN
    ALTER TABLE cerebro_ejecuciones ADD CONSTRAINT cerebro_ejecuciones_retry_chk
      CHECK (retry_count >= 0);
  END IF;
END $mig$;

CREATE INDEX IF NOT EXISTS idx_cerebro_ejec_conv    ON cerebro_ejecuciones (conversation_id);
CREATE INDEX IF NOT EXISTS idx_cerebro_ejec_status  ON cerebro_ejecuciones (status);
CREATE INDEX IF NOT EXISTS idx_cerebro_ejec_started ON cerebro_ejecuciones (started_at DESC);

-- ---------------------------------------------------------------------
-- 3. CONFIGURACION Y SECRETOS
--    Ni secretos ni URLs internas viven en los workflows ni en el SQL.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cerebro_config (
  clave       text PRIMARY KEY,
  valor       text NOT NULL,
  descripcion text,
  actualizado timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON cerebro_config FROM PUBLIC;
ALTER TABLE cerebro_config ENABLE ROW LEVEL SECURITY;

-- Anti-replay de las peticiones firmadas al webhook.
CREATE TABLE IF NOT EXISTS cerebro_webhook_nonces (
  firma    text PRIMARY KEY,
  visto_en timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_cerebro_nonces_visto ON cerebro_webhook_nonces (visto_en);

-- ---------------------------------------------------------------------
-- 4. ESTADO AUXILIAR DEL BOT
-- ---------------------------------------------------------------------
-- Throttle de alertas: no repetir el mismo aviso cada 30 minutos.
CREATE TABLE IF NOT EXISTS cerebro_alertas (
  clave  text PRIMARY KEY,
  ultimo timestamptz NOT NULL DEFAULT now()
);

-- Legacy de la Fase 1. Ya no se lee, se conserva por compatibilidad.
CREATE TABLE IF NOT EXISTS cerebro_reintentos (
  conversation_id uuid PRIMARY KEY,
  intentos        integer     NOT NULL DEFAULT 0,
  ultimo_intento  timestamptz NOT NULL DEFAULT now()
);

-- Acumula tarjeta y celular cuando el cliente los manda en mensajes
-- distintos. Se limpia al registrar el beneficiario.
CREATE TABLE IF NOT EXISTS cerebro_beneficiario_parcial (
  conversation_id uuid PRIMARY KEY,
  tarjeta         text,
  celular         text,
  actualizado     timestamptz NOT NULL DEFAULT now()
);

-- Memoria conversacional del agente (la gestiona el nodo de LangChain).
CREATE TABLE IF NOT EXISTS cerebro_memoria (
  id         serial PRIMARY KEY,
  session_id varchar(255) NOT NULL,
  message    jsonb        NOT NULL
);

-- ---------------------------------------------------------------------
-- 5. NEGOCIO: comprobantes, tasas y depositos del banco
-- ---------------------------------------------------------------------
-- Antifraude: un mismo comprobante no se registra dos veces. El
-- whatsapp_message_id distingue "el sistema reprocesa su propio
-- mensaje" de "el cliente reenvio la misma captura".
CREATE TABLE IF NOT EXISTS comprobantes_hashes (
  hash_imagen         text PRIMARY KEY,
  cliente_whatsapp    text        NOT NULL,
  comp_id             text,
  fecha_recibido      timestamptz NOT NULL DEFAULT now(),
  whatsapp_message_id text
);

ALTER TABLE comprobantes_hashes
  ADD COLUMN IF NOT EXISTS whatsapp_message_id text;

CREATE INDEX IF NOT EXISTS idx_comprobantes_hashes_wamid
  ON comprobantes_hashes (whatsapp_message_id) WHERE whatsapp_message_id IS NOT NULL;

-- Tasa de cambio vigente por moneda y dia.
CREATE TABLE IF NOT EXISTS tasas (
  fecha          date        NOT NULL DEFAULT CURRENT_DATE,
  moneda         text        NOT NULL DEFAULT 'usd',
  tasa_cup       numeric     NOT NULL,
  fuente         text        NOT NULL DEFAULT 'whatsapp',
  actualizada_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fecha, moneda)
);

-- Libro de depositos leidos de los correos del banco. El Cerebro cruza
-- el TransID del comprobante contra esta tabla para verificar.
CREATE TABLE IF NOT EXISTS depositos_mmg (
  trans_id         text PRIMARY KEY,
  monto            numeric(14,2) NOT NULL,
  moneda           text          NOT NULL DEFAULT 'GYD',
  titular          text,
  asunto           text          NOT NULL,
  recibido_en      timestamptz   NOT NULL,
  fecha_texto      text,
  gmail_message_id text UNIQUE,
  crudo            text,
  deal_id          uuid,
  consumido_en     timestamptz,
  anulado_en       timestamptz,
  motivo_anulacion text,
  creado_en        timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_depositos_mmg_deal ON depositos_mmg (deal_id);
CREATE INDEX IF NOT EXISTS idx_depositos_mmg_libres
  ON depositos_mmg (recibido_en DESC) WHERE consumido_en IS NULL;

-- ---------------------------------------------------------------------
-- 6. FUNCIONES
--
--    OJO al mantenerlas: cambiar la firma con CREATE OR REPLACE NO
--    reemplaza la funcion, CREA otra. Ya paso una vez con
--    cerebro_reclamar_reintentos: con las dos versiones presentes la
--    llamada sin argumentos quedaba ambigua y el cron fallaba en cada
--    tick. De ahi el DROP explicito de abajo.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS cerebro_reclamar_reintentos();

CREATE OR REPLACE FUNCTION cerebro_config_get(p_clave text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT valor FROM cerebro_config WHERE clave = p_clave;
$function$;

CREATE OR REPLACE FUNCTION cerebro_registrar_ejecucion(
  p_execution_id text, p_workflow_id text, p_workflow_name text,
  p_conversation_id uuid, p_firma text DEFAULT NULL::text)
RETURNS TABLE(exec_id text, es_replay boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_replay boolean := false;
  v_ins    integer := 0;
BEGIN
  IF p_firma IS NOT NULL AND p_firma <> '' THEN
    DELETE FROM cerebro_webhook_nonces WHERE visto_en < now() - interval '1 hour';
    INSERT INTO cerebro_webhook_nonces (firma) VALUES (p_firma)
    ON CONFLICT (firma) DO NOTHING;
    GET DIAGNOSTICS v_ins = ROW_COUNT;
    v_replay := (v_ins = 0);
  END IF;

  INSERT INTO cerebro_ejecuciones (execution_id, workflow_id, workflow_name, conversation_id, status)
  VALUES (p_execution_id, p_workflow_id, p_workflow_name, p_conversation_id, 'running')
  ON CONFLICT (execution_id) DO UPDATE
     SET conversation_id = COALESCE(EXCLUDED.conversation_id, cerebro_ejecuciones.conversation_id),
         updated_at      = now();

  RETURN QUERY SELECT p_execution_id, v_replay;
END;
$function$;

-- Reclamacion atomica: dos ejecuciones simultaneas nunca se llevan las
-- mismas filas.
CREATE OR REPLACE FUNCTION cerebro_reclamar_lote(p_conversation_id uuid, p_execution_id text)
RETURNS SETOF session_events
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  WITH cand AS (
    SELECT e.id FROM session_events e
     WHERE e.conversation_id = p_conversation_id
       AND e.processing_status IN ('pending','retry_wait')
     ORDER BY e.id
       FOR UPDATE SKIP LOCKED
  ),
  reclamados AS (
    UPDATE session_events s
       SET processing_status       = 'processing',
           processing_execution_id = p_execution_id,
           processing_started_at   = now(),
           next_retry_at           = NULL,
           procesado               = true
     WHERE s.id IN (SELECT id FROM cand)
    RETURNING s.*
  )
  SELECT * FROM reclamados ORDER BY id;

  DELETE FROM cerebro_reintentos WHERE conversation_id = p_conversation_id;
END;
$function$;

-- Cierre del lote. Solo toca las filas de ESTA ejecucion.
CREATE OR REPLACE FUNCTION cerebro_completar_lote(p_execution_id text)
RETURNS TABLE(completados integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_n integer := 0;
BEGIN
  UPDATE session_events e
     SET processing_status       = 'completed',
         procesado               = true,
         processed_at            = now(),
         processing_execution_id = NULL,
         processing_started_at   = NULL,
         next_retry_at           = NULL,
         last_error              = NULL
   WHERE e.processing_execution_id = p_execution_id
     AND e.processing_status = 'processing';
  GET DIAGNOSTICS v_n = ROW_COUNT;

  UPDATE cerebro_ejecuciones
     SET status = 'completed', finished_at = now(), updated_at = now()
   WHERE cerebro_ejecuciones.execution_id = p_execution_id;

  RETURN QUERY SELECT v_n;
END;
$function$;

-- Liberacion tras un fallo. La llave es el execution_id: si no hay
-- correlacion, NO TOCA NADA. Backoff 10s / 30s / 120s y al cuarto
-- fallo, error permanente.
CREATE OR REPLACE FUNCTION cerebro_liberar_lote(p_execution_id text, p_error text)
RETURNS TABLE(liberados integer, conv_id uuid, intento integer,
              proximo_intento timestamptz, estado text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_conv   uuid;
  v_next   integer;
  v_delay  interval;
  v_estado text;
  v_n      integer := 0;
BEGIN
  SELECT e.conversation_id, max(e.retry_count) + 1
    INTO v_conv, v_next
    FROM session_events e
   WHERE e.processing_execution_id = p_execution_id
     AND e.processing_status = 'processing'
   GROUP BY e.conversation_id
   ORDER BY 1
   LIMIT 1;

  IF v_conv IS NULL THEN
    UPDATE cerebro_ejecuciones
       SET status = 'failed', finished_at = now(), updated_at = now(),
           last_error = left(COALESCE(p_error,''), 500)
     WHERE cerebro_ejecuciones.execution_id = p_execution_id;
    RETURN QUERY SELECT 0, NULL::uuid, 0, NULL::timestamptz, 'sin_correlacion'::text;
    RETURN;
  END IF;

  v_delay := CASE v_next
               WHEN 1 THEN interval '10 seconds'
               WHEN 2 THEN interval '30 seconds'
               WHEN 3 THEN interval '120 seconds'
               ELSE NULL
             END;
  v_estado := CASE WHEN v_delay IS NULL THEN 'permanent_error' ELSE 'retry_wait' END;

  UPDATE session_events e
     SET processing_status       = v_estado,
         procesado               = (v_estado = 'permanent_error'),
         processing_execution_id = NULL,
         processing_started_at   = NULL,
         retry_count             = e.retry_count + 1,
         last_error              = left(COALESCE(p_error,''), 500),
         next_retry_at           = CASE WHEN v_delay IS NULL THEN NULL ELSE now() + v_delay END
   WHERE e.processing_execution_id = p_execution_id
     AND e.processing_status = 'processing';
  GET DIAGNOSTICS v_n = ROW_COUNT;

  UPDATE cerebro_ejecuciones
     SET status      = CASE WHEN v_estado = 'permanent_error' THEN 'permanent_error' ELSE 'failed' END,
         finished_at = now(), updated_at = now(),
         retry_count = v_next,
         last_error  = left(COALESCE(p_error,''), 500)
   WHERE cerebro_ejecuciones.execution_id = p_execution_id;

  RETURN QUERY SELECT v_n, v_conv, v_next,
                      (CASE WHEN v_delay IS NULL THEN NULL ELSE now() + v_delay END)::timestamptz,
                      v_estado;
END;
$function$;

-- Si n8n muere de golpe, el error trigger no dispara y el lote queda en
-- 'processing' para siempre. Esto lo devuelve a la cola.
CREATE OR REPLACE FUNCTION cerebro_rescatar_huerfanos(p_minutos integer DEFAULT 10)
RETURNS TABLE(rescatados integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_n integer := 0;
BEGIN
  UPDATE session_events e
     SET processing_status       = CASE WHEN e.retry_count >= 3 THEN 'permanent_error' ELSE 'retry_wait' END,
         procesado               = (e.retry_count >= 3),
         processing_execution_id = NULL,
         processing_started_at   = NULL,
         retry_count             = e.retry_count + 1,
         last_error              = 'ejecucion muerta sin error trigger',
         next_retry_at           = CASE WHEN e.retry_count >= 3 THEN NULL ELSE now() END
   WHERE e.processing_status = 'processing'
     AND e.processing_started_at < now() - make_interval(mins => p_minutos);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT v_n;
END;
$function$;

-- Reclama las conversaciones con reintento vencido. El "lease" de 5
-- minutos impide que dos procesos disparen el mismo reintento.
-- Sin parametro barre todo; con parametro, solo esa conversacion.
CREATE OR REPLACE FUNCTION cerebro_reclamar_reintentos(p_conversation_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(conv_id uuid, nro_intento integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  WITH listos AS (
    SELECT e.conversation_id, max(e.retry_count) AS intento
      FROM session_events e
     WHERE e.processing_status = 'retry_wait'
       AND e.next_retry_at IS NOT NULL
       AND e.next_retry_at <= now()
       AND e.creado_at > now() - interval '24 hours'
       AND (p_conversation_id IS NULL OR e.conversation_id = p_conversation_id)
     GROUP BY e.conversation_id
  ),
  lease AS (
    UPDATE session_events s
       SET next_retry_at = now() + interval '5 minutes'
     WHERE s.conversation_id IN (SELECT l.conversation_id FROM listos l)
       AND s.processing_status = 'retry_wait'
       AND s.next_retry_at <= now()
    RETURNING s.conversation_id
  )
  SELECT DISTINCT l.conversation_id, li.intento
    FROM lease l
    JOIN listos li ON li.conversation_id = l.conversation_id;
END;
$function$;

-- ---------------------------------------------------------------------
-- 7. CONFIGURACION INICIAL
--
--    NINGUN SECRETO VIAJA EN ESTE FICHERO. El secreto del canal
--    Postgres -> n8n se genera DENTRO de la base la primera vez, y solo
--    si no existe ya. En produccion ya esta puesto y esto no lo pisa.
--
--    Si reconstruyes desde cero, tras aplicar esta migracion hay que:
--      1. Ajustar notify_url al dominio real de n8n.
--      2. Copiar el secreto generado al workflow receptor, o dejar que
--         lo lea con cerebro_config_get('notify_secret').
-- ---------------------------------------------------------------------
INSERT INTO cerebro_config (clave, valor, descripcion)
VALUES ('notify_url',
        'https://CAMBIAR.example.com/webhook/wacrm-notify-etapa',
        'Webhook interno de notificaciones. Sin secreto en la URL.')
ON CONFLICT (clave) DO NOTHING;

INSERT INTO cerebro_config (clave, valor, descripcion)
SELECT 'notify_secret',
       encode(sha256((gen_random_uuid()::text || clock_timestamp()::text)::bytea), 'hex'),
       'Secreto del canal Postgres -> n8n. Viaja en la cabecera X-Cerebro-Secret.'
ON CONFLICT (clave) DO NOTHING;

INSERT INTO cerebro_config (clave, valor, descripcion)
VALUES ('dedup_por_wamid', 'on',
        'Interruptor del dedup por whatsapp_message_id. En "off" vuelve al comportamiento anterior.')
ON CONFLICT (clave) DO NOTHING;
