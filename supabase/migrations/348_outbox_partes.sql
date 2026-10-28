-- =====================================================================
-- 348 -- Outbox: one bot reply as several WhatsApp messages, delivered in order.
--
-- Phase 3 of the conversation format. A reply with several ideas leaves as several short messages. Meta does
-- not guarantee the order of back-to-back sends and the sender can run concurrently, so the outbox itself
-- guarantees the order and never leaves a financial reply half delivered without telling the admin.
--
--   * message_outbox: grupo_id / parte / partes (all NULL for single messages and every old row).
--   * outbox_status_chk: adds 'cancelled' (parts that must not go out) and 'failed_direct', which
--     cerebro_outbox_resultado already writes for failed direct sends but the old CHECK forbade (bug found
--     while writing this: a failed direct send would have raised check_violation instead of being recorded).
--   * cerebro_outbox_encolar_partes(): atomic multi-part enqueue; one part behaves exactly like
--     cerebro_outbox_encolar.
--   * cerebro_outbox_reclamar(): a part is claimable only when every lower part of its group is 'sent'; a
--     group with a failed or cancelled part is never claimed.
--   * cerebro_outbox_resultado(): a part that fails for good cancels the unsent parts of its group and the
--     admin notice says the reply was delivered in part (part X of N).
--   * cerebro_config.opt_partir_respuesta = 'no' (flag read by the Cerebro workflow; off = one message).
--
-- Bodies are the staging bodies read with pg_get_functiondef (equal to production for encolar/reclamar;
-- resultado could only be compared with its documented behaviour, 067 is not in the repo).
-- Guard: idempotent (IF NOT EXISTS, CREATE OR REPLACE, ON CONFLICT DO NOTHING).
-- ROLLBACK: ROLLBACK-348-outbox-partes.sql
-- Assertion: supabase/staging/assertions/outbox-partes.sql
-- =====================================================================

ALTER TABLE message_outbox
  ADD COLUMN IF NOT EXISTS grupo_id uuid,
  ADD COLUMN IF NOT EXISTS parte    smallint,
  ADD COLUMN IF NOT EXISTS partes   smallint;

ALTER TABLE message_outbox DROP CONSTRAINT IF EXISTS outbox_status_chk;
ALTER TABLE message_outbox ADD CONSTRAINT outbox_status_chk
  CHECK (status IN ('shadow','pending','sending','sent','retry_wait','failed','failed_direct','cancelled'));

CREATE INDEX IF NOT EXISTS outbox_grupo_idx ON message_outbox (grupo_id, parte) WHERE grupo_id IS NOT NULL;

INSERT INTO cerebro_config (clave, valor, descripcion) VALUES
  ('opt_partir_respuesta', 'no',
   'si = the Cerebro splits a long reply into up to 4 ordered WhatsApp messages (cerebro_outbox_encolar_partes); no = one message, exactly as before (348).')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.cerebro_outbox_encolar_partes(p_conversation_id uuid, p_telefono text, p_partes text[], p_operation_id uuid, p_execution_id text)
 RETURNS TABLE(encolado boolean, motivo text, outbox_id uuid, enviar_directo boolean, partes integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- (348) Enqueues one reply as 1..N ordered messages. Blank parts are ignored.
--   0 or 1 part -> exactly cerebro_outbox_encolar (same key, same row, same answer; partes = 0 or 1).
--   shadow mode (outbox_activo <> 'si', the Cerebro sends directly) -> the parts are joined with a blank line
--     and go as ONE message through cerebro_outbox_encolar: direct sending has no ordering guarantee.
--   N > 1 -> N rows in ONE statement (all or none): keys '<base>:p1'..'<base>:pN', one grupo_id, parte/partes.
--     If the reply was already enqueued (the base key or '<base>:p1' exists) nothing is inserted.
DECLARE
  v_partes text[]; v_n int; v_status text; v_directo boolean;
  v_ancla text; v_sin_ancla boolean; v_clave text; v_dentro int; v_grupo uuid; v_primero uuid;
BEGIN
  SELECT coalesce(array_agg(u.t ORDER BY u.o), ARRAY[]::text[]) INTO v_partes
    FROM unnest(p_partes) WITH ORDINALITY AS u(t, o)
   WHERE NULLIF(trim(coalesce(u.t,'')),'') IS NOT NULL;
  v_n := coalesce(cardinality(v_partes), 0);

  SELECT CASE WHEN c.valor = 'si' THEN 'pending' ELSE 'shadow' END
    INTO v_status
    FROM cerebro_config c WHERE c.clave = 'outbox_activo';
  v_status := coalesce(v_status, 'shadow');
  v_directo := (v_status = 'shadow');

  IF v_n <= 1 OR v_directo THEN
    RETURN QUERY
      SELECT e.encolado, e.motivo, e.outbox_id, e.enviar_directo, least(v_n, 1)
        FROM cerebro_outbox_encolar(p_conversation_id, p_telefono,
               CASE WHEN v_n = 0 THEN NULL ELSE array_to_string(v_partes, E'\n\n') END,
               p_operation_id, p_execution_id) e;
    RETURN;
  END IF;

  SELECT max(se.whatsapp_message_id) INTO v_ancla
    FROM session_events se
   WHERE se.processing_execution_id = p_execution_id
     AND se.whatsapp_message_id IS NOT NULL;

  v_sin_ancla := (NULLIF(trim(coalesce(v_ancla,'')),'') IS NULL);
  v_clave := p_conversation_id::text || ':' ||
             coalesce(NULLIF(trim(v_ancla),''), 'exec-' || p_execution_id);

  SELECT m.id INTO v_primero FROM message_outbox m
   WHERE m.idempotency_key IN (v_clave, v_clave || ':p1')
   ORDER BY m.created_at LIMIT 1;
  IF v_primero IS NOT NULL THEN
    RETURN QUERY SELECT false, 'ya estaba encolado: la respuesta a ese mensaje ya existe'::text,
                        v_primero, v_directo, v_n;
    RETURN;
  END IF;

  v_grupo := gen_random_uuid();
  INSERT INTO message_outbox (conversation_id, operation_id, telefono_e164,
                              message_type, payload, idempotency_key, execution_id, status, last_error,
                              grupo_id, parte, partes)
  SELECT p_conversation_id, p_operation_id, p_telefono, 'text',
         jsonb_build_object('to', p_telefono, 'type', 'text', 'text', u.t),
         v_clave || ':p' || u.o, p_execution_id, v_status,
         CASE WHEN v_sin_ancla THEN 'AVISO: encolado sin ancla de wamid, la clave usa execution_id y NO protege del reintento de lote' END,
         v_grupo, u.o::smallint, v_n::smallint
    FROM unnest(v_partes) WITH ORDINALITY AS u(t, o)
  ON CONFLICT (idempotency_key) DO NOTHING;
  GET DIAGNOSTICS v_dentro = ROW_COUNT;

  IF v_dentro > 0 AND v_dentro < v_n THEN
    RAISE EXCEPTION 'cerebro_outbox_encolar_partes: solo se insertaron % de % partes', v_dentro, v_n;
  END IF;

  SELECT m.id INTO v_primero FROM message_outbox m WHERE m.idempotency_key = v_clave || ':p1';
  IF v_dentro = 0 THEN
    RETURN QUERY SELECT false, 'ya estaba encolado: la respuesta a ese mensaje ya existe'::text,
                        v_primero, v_directo, v_n;
  ELSE
    RETURN QUERY SELECT true, 'encolado'::text, v_primero, v_directo, v_n;
  END IF;
END $function$;

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
      WHERE ((i.status = 'pending')
          OR (i.status IN ('retry_wait','sending') AND i.next_attempt_at <= now()))
        -- (348) A part of a multi-message reply is claimable only when every lower part is already 'sent',
        -- so at most one part per group is eligible in any call, and a group with a failed or cancelled part
        -- is never claimed again. Rows without grupo_id (every row before 348) follow the old rule.
        AND (i.grupo_id IS NULL
             OR NOT EXISTS (SELECT 1 FROM message_outbox g
                             WHERE g.grupo_id = i.grupo_id
                               AND (g.status IN ('failed','cancelled')
                                    OR (g.parte < i.parte AND g.status <> 'sent'))))
      ORDER BY i.created_at, i.parte
      LIMIT greatest(coalesce(p_limite,10), 1)
      FOR UPDATE SKIP LOCKED)
  RETURNING o.*;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_outbox_resultado(p_id uuid, p_ok boolean, p_message_id text DEFAULT NULL::text, p_error text DEFAULT NULL::text)
 RETURNS TABLE(estado text, intentos integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_fila  message_outbox;
  v_mid   uuid;
  v_cta   uuid;
  v_err   text;
  v_enviadas int;
  v_aviso text := '';
BEGIN
  -- n8n no sabe mandar NULL ni parametros vacios al final del
  -- queryReplacement (se pierden y revienta con "no parameter $4"),
  -- asi que '-' es el centinela de NULL.
  v_mid := CASE WHEN trim(coalesce(p_message_id,'')) IN ('','-') THEN NULL
                ELSE trim(p_message_id)::uuid END;
  v_err := CASE WHEN trim(coalesce(p_error,'')) IN ('','-') THEN NULL
                ELSE left(trim(p_error), 500) END;

  IF p_ok THEN
    UPDATE message_outbox
       SET status = 'sent', sent_at = now(), message_id = v_mid, last_error = NULL
     WHERE id = p_id AND status = 'sending'
    RETURNING * INTO v_fila;
  ELSE
    UPDATE message_outbox
       SET attempt_count = attempt_count + 1,
           last_error = v_err,
           status = CASE WHEN attempt_count + 1 >= 4 THEN 'failed' ELSE 'retry_wait' END,
           next_attempt_at = CASE attempt_count + 1
             WHEN 1 THEN now() + interval '10 seconds'
             WHEN 2 THEN now() + interval '30 seconds'
             ELSE now() + interval '120 seconds' END
     WHERE id = p_id AND status = 'sending'
    RETURNING * INTO v_fila;
  END IF;

  -- ENVIO DIRECTO DEL CEREBRO (LEGACY OPTIMIZED V1, fase 1F).
  -- Mientras `outbox_activo = 'no'`, la fila nace en 'shadow' y quien envia es
  -- el propio Cerebro. Antes, su resultado no se anotaba en ningun sitio: el
  -- UPDATE de arriba exige 'sending' y no encontraba nada.
  -- Ahora se anota, con dos cuidados:
  --   * un fallo NO pasa a 'pending': eso lo haria reclamable por el enviador
  --     y podria reenviarse horas despues, fuera de contexto. Va a
  --     'failed_direct', que `cerebro_outbox_reclamar` NO selecciona nunca.
  --   * el aviso al equipo se crea igual, que es lo que hace util el registro.
  IF v_fila.id IS NULL THEN
    IF p_ok THEN
      UPDATE message_outbox
         SET status = 'sent', sent_at = now(), message_id = v_mid, last_error = NULL
       WHERE id = p_id AND status = 'shadow'
      RETURNING * INTO v_fila;
    ELSE
      UPDATE message_outbox
         SET status = 'failed_direct',
             attempt_count = attempt_count + 1,
             last_error = coalesce(v_err, 'envio directo fallido')
       WHERE id = p_id AND status = 'shadow'
      RETURNING * INTO v_fila;
    END IF;
  END IF;

  -- (348) A part of a multi-message reply failed for good: the parts after it must never go out (the customer
  -- would get a reply with a hole in it), so they are cancelled, and the notice says the reply is partial.
  IF v_fila.id IS NOT NULL AND v_fila.status = 'failed' AND v_fila.grupo_id IS NOT NULL THEN
    UPDATE message_outbox m
       SET status = 'cancelled',
           last_error = 'cancelado: la parte ' || v_fila.parte || ' de ' || v_fila.partes || ' fallo'
     WHERE m.grupo_id = v_fila.grupo_id
       AND m.id <> v_fila.id
       AND m.status IN ('pending','retry_wait','sending');
    SELECT count(*) INTO v_enviadas
      FROM message_outbox m WHERE m.grupo_id = v_fila.grupo_id AND m.status = 'sent';
    v_aviso := ' RESPUESTA ENTREGADA A MEDIAS: fallo la parte ' || v_fila.parte || ' de ' || v_fila.partes
            || ' (el cliente recibio ' || v_enviadas || ' de ' || v_fila.partes
            || ' mensajes); las demas se cancelaron. Contactar al cliente para completar la respuesta.';
  END IF;

  IF v_fila.id IS NOT NULL AND v_fila.status IN ('failed','failed_direct') THEN
    BEGIN
      SELECT v.account_id INTO v_cta FROM conversations v WHERE v.id = v_fila.conversation_id;
      INSERT INTO notifications (account_id, user_id, type, title, body)
      SELECT v_cta, p.user_id, 'mensaje_fallido',
             'El outbox agoto los reintentos de un mensaje',
             'Destino ' || coalesce(v_fila.telefono_e164,'?') || '. Ultimo error: '
               || coalesce(v_fila.last_error,'?')
               || '. La fila queda en ' || v_fila.status
               || '; revisar si hay que contactar por otra via.' || v_aviso
        FROM profiles p
       WHERE p.account_id = v_cta
         AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p.user_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'cerebro_outbox_resultado: aviso no creado: %', SQLERRM;
    END;
  END IF;

  IF v_fila.id IS NULL THEN
    RETURN QUERY SELECT 'ignorado: la fila no estaba en sending ni en shadow'::text, NULL::integer;
  ELSE
    RETURN QUERY SELECT v_fila.status, v_fila.attempt_count;
  END IF;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_outbox_encolar_partes(uuid, text, text[], uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_outbox_encolar_partes(uuid, text, text[], uuid, text) TO service_role;
