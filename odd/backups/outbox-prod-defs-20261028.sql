-- Production definitions read with pg_get_functiondef on 2026-10-28 (read-only). Migration 067 is not in the repo.
-- message_outbox: id uuid pk, conversation_id uuid not null, operation_id uuid, telefono_e164 text not null,
--   message_type text not null default 'text', payload jsonb not null, idempotency_key text not null UNIQUE,
--   status text not null default 'pending', attempt_count int not null default 0, next_attempt_at timestamptz not null default now(),
--   last_error text, execution_id text, created_at timestamptz not null default now(), sent_at timestamptz, message_id uuid.
-- CHECK outbox_status_chk: status in ('shadow','pending','sending','sent','retry_wait','failed')   (note: 'failed_direct' is NOT allowed)
-- CHECK outbox_type_chk: message_type in ('text','template')
-- Indexes: outbox_por_enviar_idx (next_attempt_at) WHERE status in ('pending','retry_wait'); outbox_conv_idx (conversation_id, created_at desc)
-- cerebro_config: outbox_activo = 'si' (since 2026-08-11), outbox_url = 'https://wacrm.onlinefreedom.site'

CREATE OR REPLACE FUNCTION public.cerebro_outbox_encolar(p_conversation_id uuid, p_telefono text, p_texto text, p_operation_id uuid, p_execution_id text)
 RETURNS TABLE(encolado boolean, motivo text, outbox_id uuid, enviar_directo boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_clave text; v_id uuid; v_ancla text; v_sin_ancla boolean; v_status text; v_directo boolean;
BEGIN
  SELECT CASE WHEN c.valor = 'si' THEN 'pending' ELSE 'shadow' END
    INTO v_status
    FROM cerebro_config c WHERE c.clave = 'outbox_activo';
  v_status := coalesce(v_status, 'shadow');
  v_directo := (v_status = 'shadow');

  IF NULLIF(trim(coalesce(p_texto,'')),'') IS NULL THEN
    RETURN QUERY SELECT false, 'texto vacio: no se encola nada'::text, NULL::uuid, v_directo;
    RETURN;
  END IF;

  SELECT max(se.whatsapp_message_id) INTO v_ancla
    FROM session_events se
   WHERE se.processing_execution_id = p_execution_id
     AND se.whatsapp_message_id IS NOT NULL;

  v_sin_ancla := (NULLIF(trim(coalesce(v_ancla,'')),'') IS NULL);
  v_clave := p_conversation_id::text || ':' ||
             coalesce(NULLIF(trim(v_ancla),''), 'exec-' || p_execution_id);

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
                        (SELECT id FROM message_outbox WHERE idempotency_key = v_clave), v_directo;
  ELSE
    RETURN QUERY SELECT true, 'encolado'::text, v_id, v_directo;
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
      WHERE (i.status = 'pending')
         OR (i.status IN ('retry_wait','sending') AND i.next_attempt_at <= now())
      ORDER BY i.created_at
      LIMIT greatest(coalesce(p_limite,10), 1)
      FOR UPDATE SKIP LOCKED)
  RETURNING o.*;
END $function$;

-- cerebro_outbox_resultado(p_id uuid, p_ok boolean, p_message_id text DEFAULT NULL, p_error text DEFAULT NULL)
--   RETURNS TABLE(estado text, intentos integer). '-' is the NULL sentinel for p_message_id/p_error (n8n drops trailing empty params).
--   ok: sending -> sent (sent_at, message_id). fail: attempt_count+1; >=4 -> 'failed' else 'retry_wait' with next_attempt_at
--   +10s / +30s / +120s. If the row is 'shadow' (direct send): ok -> sent, fail -> 'failed_direct' (violates the CHECK above).
--   On 'failed'/'failed_direct' it inserts a `notifications` row (type 'mensaje_fallido') for every profile of the account.
--   Returns 'ignorado: la fila no estaba en sending ni en shadow' when nothing matched.
