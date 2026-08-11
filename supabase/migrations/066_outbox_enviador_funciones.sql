-- ============================================================
-- 066 — Fase 2 del outbox: funciones del enviador (y aparcado 'shadow')
-- ============================================================
-- YA APLICADA EN PRODUCCION el 11-ago-2026 (02:50 UTC) via MCP
-- apply_migration. NO LA EJECUTES: este fichero es el registro.
-- Plan completo: PLAN-2E-outbox.md. Workflow del enviador:
-- `Cerebro - Enviador del outbox` (K4ijL3NzmY1VX7XI).
--
-- Decisiones que no se ven en el SQL:
--  * 'shadow' = fila que el Cerebro YA envio por el camino viejo. CRITICO:
--    habia 182 filas 'pending' de la fase en sombra; un enviador recien
--    encendido se las habria RE-ENVIADO a clientes reales.
--  * El fallo de ventana de 24 h NO llega en la respuesta HTTP: WaCRM
--    devuelve 201 con wamid y la muerte llega asincrona como
--    status='failed' en `messages` (verificado en send-message.ts). Por
--    eso la columna message_id: el fallback por plantilla de la fase 3
--    tendra que mirar el estado del mensaje, no el codigo HTTP.
--  * El lease de 5 min en reclamar es la proteccion contra el doble envio
--    si n8n muere entre reclamar y resultado.
--  * Grants: ninguno — tras la 064 las funciones nuevas nacen cerradas y
--    n8n entra como postgres (dueno).

-- 1) Estado 'shadow' y aparcado de lo ya enviado.
ALTER TABLE message_outbox DROP CONSTRAINT outbox_status_chk;
ALTER TABLE message_outbox ADD CONSTRAINT outbox_status_chk
  CHECK (status = ANY (ARRAY['shadow','pending','sending','sent','retry_wait','failed']));

UPDATE message_outbox SET status = 'shadow' WHERE status = 'pending';

-- 2) Ata la fila al mensaje creado en WaCRM (para el fallback de fase 3).
ALTER TABLE message_outbox ADD COLUMN IF NOT EXISTS message_id uuid;

-- 3) El interruptor de la fase 3.
INSERT INTO cerebro_config (clave, valor)
VALUES ('outbox_activo', 'no')
ON CONFLICT (clave) DO NOTHING;

-- 4) encolar respeta el interruptor: 'no' -> la fila nace 'shadow';
--    'si' -> nace 'pending'. Resto identico a la 051.
CREATE OR REPLACE FUNCTION public.cerebro_outbox_encolar(p_conversation_id uuid, p_telefono text, p_texto text, p_operation_id uuid, p_execution_id text)
 RETURNS TABLE(encolado boolean, motivo text, outbox_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_clave text; v_id uuid; v_ancla text; v_sin_ancla boolean; v_status text;
BEGIN
  IF NULLIF(trim(coalesce(p_texto,'')),'') IS NULL THEN
    RETURN QUERY SELECT false, 'texto vacio: no se encola nada'::text, NULL::uuid;
    RETURN;
  END IF;

  SELECT max(se.whatsapp_message_id) INTO v_ancla
    FROM session_events se
   WHERE se.processing_execution_id = p_execution_id
     AND se.whatsapp_message_id IS NOT NULL;

  v_sin_ancla := (NULLIF(trim(coalesce(v_ancla,'')),'') IS NULL);
  v_clave := p_conversation_id::text || ':' ||
             coalesce(NULLIF(trim(v_ancla),''), 'exec-' || p_execution_id);

  SELECT CASE WHEN c.valor = 'si' THEN 'pending' ELSE 'shadow' END
    INTO v_status
    FROM cerebro_config c WHERE c.clave = 'outbox_activo';
  v_status := coalesce(v_status, 'shadow');

  INSERT INTO message_outbox (conversation_id, operation_id, telefono_e164,
                              message_type, payload, idempotency_key, execution_id, status, last_error)
  VALUES (p_conversation_id, p_operation_id, p_telefono, 'text',
          jsonb_build_object('to', p_telefono, 'type', 'text', 'text', p_texto),
          v_clave, p_execution_id, v_status,
          CASE WHEN v_sin_ancla THEN 'AVISO: encolado sin ancla de wamid, la clave usa execution_id y NO protege del reintento de lote' END)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN QUERY SELECT false, 'ya estaba encolado: la respuesta a ese mensaje ya existe'::text,
                        (SELECT id FROM message_outbox WHERE idempotency_key = v_clave);
  ELSE
    RETURN QUERY SELECT true, 'encolado'::text, v_id;
  END IF;
END $function$;

-- 5) reclamar: hasta p_limite filas listas, marcadas 'sending' con lease
--    de 5 min. Vencido el lease, la fila vuelve a ser reclamable.
CREATE OR REPLACE FUNCTION public.cerebro_outbox_reclamar(p_limite integer DEFAULT 10)
 RETURNS SETOF message_outbox
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  UPDATE message_outbox o
     SET status = 'sending',
         next_attempt_at = now() + interval '5 minutes'
   WHERE o.id IN (
     SELECT i.id FROM message_outbox i
      WHERE (i.status = 'pending')
         OR (i.status IN ('retry_wait','sending') AND i.next_attempt_at <= now())
      ORDER BY i.created_at
      LIMIT greatest(coalesce(p_limite,10), 1)
      FOR UPDATE SKIP LOCKED)
  RETURNING o.*;
END $function$;

-- 6) resultado: exito -> 'sent'; fallo -> backoff 10 s / 30 s / 120 s y al
--    4.o intento 'failed' + aviso en el CRM (patron de la 039; un aviso
--    roto jamas impide marcar la fila). p_message_id llega como text
--    porque n8n no sabe mandar NULL en queryReplacement: '' = NULL.
CREATE OR REPLACE FUNCTION public.cerebro_outbox_resultado(p_id uuid, p_ok boolean, p_message_id text DEFAULT NULL, p_error text DEFAULT NULL)
 RETURNS TABLE(estado text, intentos integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_fila  message_outbox;
  v_mid   uuid;
  v_cta   uuid;
BEGIN
  v_mid := NULLIF(trim(coalesce(p_message_id,'')),'')::uuid;

  IF p_ok THEN
    UPDATE message_outbox
       SET status = 'sent', sent_at = now(), message_id = v_mid, last_error = NULL
     WHERE id = p_id AND status = 'sending'
    RETURNING * INTO v_fila;
  ELSE
    UPDATE message_outbox
       SET attempt_count = attempt_count + 1,
           last_error = left(NULLIF(trim(coalesce(p_error,'')),''), 500),
           status = CASE WHEN attempt_count + 1 >= 4 THEN 'failed' ELSE 'retry_wait' END,
           next_attempt_at = CASE attempt_count + 1
             WHEN 1 THEN now() + interval '10 seconds'
             WHEN 2 THEN now() + interval '30 seconds'
             ELSE now() + interval '120 seconds' END
     WHERE id = p_id AND status = 'sending'
    RETURNING * INTO v_fila;

    IF v_fila.id IS NOT NULL AND v_fila.status = 'failed' THEN
      BEGIN
        SELECT v.account_id INTO v_cta FROM conversations v WHERE v.id = v_fila.conversation_id;
        INSERT INTO notifications (account_id, user_id, type, title, body)
        SELECT v_cta, p.user_id, 'mensaje_fallido',
               'El outbox agoto los reintentos de un mensaje',
               'Destino ' || coalesce(v_fila.telefono_e164,'?') || '. Ultimo error: '
                 || coalesce(v_fila.last_error,'?')
                 || '. La fila queda en failed; revisar si hay que contactar por otra via.'
          FROM profiles p
         WHERE p.account_id = v_cta
           AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p.user_id);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'cerebro_outbox_resultado: aviso no creado: %', SQLERRM;
      END;
    END IF;
  END IF;

  IF v_fila.id IS NULL THEN
    RETURN QUERY SELECT 'ignorado: la fila no estaba en sending'::text, NULL::integer;
  ELSE
    RETURN QUERY SELECT v_fila.status, v_fila.attempt_count;
  END IF;
END $function$;
