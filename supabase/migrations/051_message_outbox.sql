-- =====================================================================
--  051 — Outbox de mensajes (tramo 2E)
--
--   ###############################################################
--   ##  NO APLICADA. ESTE FICHERO NO SE HA EJECUTADO NUNCA.       ##
--   ##  Escrito el 9-ago-2026 para desplegar mas adelante.        ##
--   ##  Antes de aplicarlo, leer PLAN-2E-outbox.md ENTERO.        ##
--   ###############################################################
--
-- QUE ARREGLA
--
--   Hoy `Responder por WaCRM` es un httpRequest **sin `retryOnFail` y sin
--   `onError`**. Si ese envio falla, la ejecucion muere entera, salta el
--   manejador de errores, libera el lote, se reintenta... y **se vuelve a
--   llamar al modelo**. El cliente puede recibir la respuesta dos veces,
--   o una respuesta distinta a la que ya se le habia entregado.
--
--   Con el outbox: la respuesta se guarda ANTES de salir, el lote se
--   cierra ahi, y un proceso aparte envia. Si el envio falla se reintenta
--   **el envio**, nunca el modelo.
--
-- LO QUE NO CAMBIA
--
--   De las 10 rutas que terminan en `Cerrar lote`, **solo UNA envia algo
--   al cliente** (`Responder por WaCRM`). Las otras nueve son silencios y
--   descartes —duplicado, replay, chat oculto, limite, SKIP, silencio
--   admin...— y **NINGUNA debe generar fila de outbox**. El cambio es
--   local a una rama de diez.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. La tabla
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS message_outbox (
  id               uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  conversation_id  uuid NOT NULL,
  operation_id     uuid,
  telefono_e164    text NOT NULL,
  message_type     text NOT NULL DEFAULT 'text',
  payload          jsonb NOT NULL,
  idempotency_key  text NOT NULL UNIQUE,
  status           text NOT NULL DEFAULT 'pending',
  attempt_count    integer NOT NULL DEFAULT 0,
  next_attempt_at  timestamptz NOT NULL DEFAULT now(),
  last_error       text,
  execution_id     text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  sent_at          timestamptz,
  CONSTRAINT outbox_status_chk CHECK (status IN
    ('pending','sending','sent','retry_wait','failed')),
  CONSTRAINT outbox_type_chk CHECK (message_type IN ('text','template'))
);

CREATE INDEX IF NOT EXISTS outbox_por_enviar_idx
  ON message_outbox (next_attempt_at)
  WHERE status IN ('pending','retry_wait');

CREATE INDEX IF NOT EXISTS outbox_conv_idx
  ON message_outbox (conversation_id, created_at DESC);


-- ---------------------------------------------------------------------
-- 2. Encolar — lo llama el Cerebro en vez de enviar
-- ---------------------------------------------------------------------
--
-- **LA CLAVE DE IDEMPOTENCIA ES LO MAS IMPORTANTE DE TODO ESTE FICHERO.**
--
-- En el tramo 2D se uso `execution_id` y resulto proteger menos de lo que
-- parecia: un reintento de lote es una ejecucion NUEVA, con id distinto,
-- luego clave distinta. Aqui NO se repite ese error.
--
-- El ancla es `p_wamid_ancla`: el `whatsapp_message_id` del ultimo mensaje
-- del cliente incluido en el lote. **Eso es estable entre reintentos**,
-- porque el reintento procesa los mismos eventos. Asi, "la respuesta a
-- ese mensaje" existe una sola vez, se reintente el lote las veces que
-- sea.
--
-- Si el ancla llegara vacia se cae a `execution_id`, que es peor pero
-- mejor que nada — y se deja constancia en `last_error` para que se vea.

-- El ancla NO se pasa desde n8n: la deriva la propia funcion desde los
-- `session_events` que esa ejecucion tiene reclamados. Asi la clave
-- depende de QUE EVENTOS se procesaron, no de quien los procesa — que es
-- justo lo que la hace estable entre reintentos. Y de paso es un
-- parametro menos que resolver con expresiones en el workflow.

CREATE OR REPLACE FUNCTION cerebro_outbox_encolar(
  p_conversation_id uuid,
  p_telefono        text,
  p_texto           text,
  p_operation_id    uuid,
  p_execution_id    text
) RETURNS TABLE (encolado boolean, motivo text, outbox_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_clave text;
  v_id uuid;
  v_ancla text;
  v_sin_ancla boolean;
BEGIN
  IF NULLIF(trim(coalesce(p_texto,'')),'') IS NULL THEN
    RETURN QUERY SELECT false, 'texto vacio: no se encola nada'::text, NULL::uuid;
    RETURN;
  END IF;

  -- Los eventos del lote, tal y como los dejo `cerebro_reclamar_lote`.
  -- En un reintento son LOS MISMOS, luego este max() es el mismo valor.
  SELECT max(se.whatsapp_message_id) INTO v_ancla
    FROM session_events se
   WHERE se.processing_execution_id = p_execution_id
     AND se.whatsapp_message_id IS NOT NULL;

  v_sin_ancla := (NULLIF(trim(coalesce(v_ancla,'')),'') IS NULL);

  v_clave := p_conversation_id::text || ':' ||
             coalesce(NULLIF(trim(v_ancla),''), 'exec-' || p_execution_id);

  INSERT INTO message_outbox (conversation_id, operation_id, telefono_e164,
                              message_type, payload, idempotency_key,
                              execution_id, last_error)
  VALUES (p_conversation_id, p_operation_id, p_telefono, 'text',
          jsonb_build_object('to', p_telefono, 'type', 'text', 'text', p_texto),
          v_clave, p_execution_id,
          CASE WHEN v_sin_ancla THEN 'AVISO: encolado sin ancla de wamid, la clave usa execution_id y NO protege del reintento de lote' END)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN QUERY SELECT false, 'ya estaba encolado: la respuesta a ese mensaje ya existe'::text,
                        (SELECT id FROM message_outbox WHERE idempotency_key = v_clave);
  ELSE
    RETURN QUERY SELECT true, 'encolado'::text, v_id;
  END IF;
END $$;


-- ---------------------------------------------------------------------
-- 3. Lo que toma el enviador
-- ---------------------------------------------------------------------
-- `FOR UPDATE SKIP LOCKED`: mismo criterio que `Reclamar lote` de la
-- Fase 1. Dos enviadores a la vez no pueden coger la misma fila.

CREATE OR REPLACE FUNCTION cerebro_outbox_reclamar(p_limite integer DEFAULT 10)
RETURNS TABLE (id uuid, conversation_id uuid, telefono_e164 text,
               message_type text, payload jsonb, attempt_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN QUERY
  WITH tomadas AS (
    SELECT o.id FROM message_outbox o
     WHERE o.status IN ('pending','retry_wait')
       AND o.next_attempt_at <= now()
     ORDER BY o.created_at
     LIMIT p_limite
     FOR UPDATE SKIP LOCKED
  )
  UPDATE message_outbox m
     SET status = 'sending', attempt_count = m.attempt_count + 1
    FROM tomadas t
   WHERE m.id = t.id
  RETURNING m.id, m.conversation_id, m.telefono_e164,
            m.message_type, m.payload, m.attempt_count;
END $$;


-- ---------------------------------------------------------------------
-- 4. Resultado del envio
-- ---------------------------------------------------------------------
-- Backoff igual que el de la Fase 1: 10 s, 30 s, 120 s. Al cuarto
-- intento se da por `failed` y **se avisa en el CRM**, que no depende de
-- la ventana de 24 h de WhatsApp.

CREATE OR REPLACE FUNCTION cerebro_outbox_resultado(
  p_id uuid, p_ok boolean, p_error text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_intentos int; v_conv uuid;
BEGIN
  IF p_ok THEN
    UPDATE message_outbox SET status='sent', sent_at=now(), last_error=NULL
     WHERE id = p_id;
    RETURN 'enviado';
  END IF;

  SELECT attempt_count, conversation_id INTO v_intentos, v_conv
    FROM message_outbox WHERE id = p_id;

  IF v_intentos >= 4 THEN
    UPDATE message_outbox
       SET status='failed', last_error=left(coalesce(p_error,'sin detalle'), 500)
     WHERE id = p_id;

    INSERT INTO notifications (account_id, user_id, type, title, body)
    SELECT '465fb4ce-33b6-4473-ad2c-42818772f587', u, 'mensaje_fallido',
           'Una respuesta no se pudo entregar',
           'Tras 4 intentos. Conversacion ' || v_conv || '. Revise el chat.'
      FROM unnest(ARRAY['e3c7943d-b2fa-4c53-ae2f-406f1533ed47',
                        '5c4d16fd-1530-4023-8119-b58e04cc815f',
                        'ca797265-a1b3-43f7-9d9f-68c15d1f4780']::uuid[]) AS u;
    RETURN 'agotado: marcado failed y avisado en el CRM';
  END IF;

  UPDATE message_outbox
     SET status='retry_wait',
         last_error = left(coalesce(p_error,'sin detalle'), 500),
         next_attempt_at = now() + (CASE v_intentos
              WHEN 1 THEN interval '10 seconds'
              WHEN 2 THEN interval '30 seconds'
              ELSE interval '120 seconds' END)
   WHERE id = p_id;
  RETURN 'reintento programado';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] outbox resultado fallo: %', SQLERRM;
  RETURN 'fallo: ' || SQLERRM;
END $$;


-- ---------------------------------------------------------------------
-- 5. Vigilancia
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW cerebro_outbox_salud AS
  SELECT status, count(*) AS filas,
         min(created_at) AS mas_antiguo,
         max(attempt_count) AS max_intentos
    FROM message_outbox
   GROUP BY status;

-- Debe dar CERO. Una respuesta atascada es un cliente esperando.
--   SELECT * FROM message_outbox
--    WHERE status IN ('pending','retry_wait','sending')
--      AND created_at < now() - interval '15 minutes';


-- =====================================================================
-- ROLLBACK
--   DROP VIEW IF EXISTS cerebro_outbox_salud;
--   DROP FUNCTION IF EXISTS cerebro_outbox_resultado(uuid, boolean, text);
--   DROP FUNCTION IF EXISTS cerebro_outbox_reclamar(integer);
--   DROP FUNCTION IF EXISTS cerebro_outbox_encolar(uuid,text,text,uuid,text,text);
--   DROP TABLE IF EXISTS message_outbox;
--
-- Mientras el Cerebro siga enviando como hoy (fase 1 del plan), quitar
-- todo esto no afecta a nada.
-- =====================================================================
