-- ROLLBACK 348 -- restores the outbox exactly as it was (067/066 state): old bodies, old CHECK, no group columns.
-- Rows that only exist because of 348 are folded back first: 'cancelled' and 'failed_direct' -> 'failed',
-- and parts of a group are kept as plain rows (their columns are dropped).
DROP FUNCTION IF EXISTS public.cerebro_outbox_encolar_partes(uuid, text, text[], uuid, text);

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

  IF v_fila.id IS NOT NULL AND v_fila.status IN ('failed','failed_direct') THEN
    BEGIN
      SELECT v.account_id INTO v_cta FROM conversations v WHERE v.id = v_fila.conversation_id;
      INSERT INTO notifications (account_id, user_id, type, title, body)
      SELECT v_cta, p.user_id, 'mensaje_fallido',
             'El outbox agoto los reintentos de un mensaje',
             'Destino ' || coalesce(v_fila.telefono_e164,'?') || '. Ultimo error: '
               || coalesce(v_fila.last_error,'?')
               || '. La fila queda en ' || v_fila.status
               || '; revisar si hay que contactar por otra via.'
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

UPDATE message_outbox SET status = 'failed' WHERE status IN ('cancelled','failed_direct');
ALTER TABLE message_outbox DROP CONSTRAINT IF EXISTS outbox_status_chk;
ALTER TABLE message_outbox ADD CONSTRAINT outbox_status_chk
  CHECK (status IN ('shadow','pending','sending','sent','retry_wait','failed'));
DROP INDEX IF EXISTS public.outbox_grupo_idx;
ALTER TABLE message_outbox DROP COLUMN IF EXISTS grupo_id, DROP COLUMN IF EXISTS parte, DROP COLUMN IF EXISTS partes;
DELETE FROM cerebro_config WHERE clave = 'opt_partir_respuesta';
