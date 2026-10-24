-- =====================================================================
-- 296 -- The bot cannot promise "anotado" without a write (promise guard)
--
-- Production 2026-10-24: the beneficiary-draft monitoring (odd/design/beneficiary-draft.md section 9) finds agent
-- replies matching (anotado|queda registrad/anotad/así) with no write in the turn: 11 of 99 promise-shaped replies
-- in the last 14 days on 2026-10-24. Owner decision 2026-10-24: record the case and leave a system note so the NEXT
-- turn registers what is missing; the sent message is never touched.
--
-- Detection: AFTER INSERT on messages, sender_type = 'agent', ai_generated, content matches the promise text, and
-- no tool_execution_log row for the conversation in [created_at - 3 min, created_at + 1 min] (the design's window).
-- One audit row per message (message_id UNIQUE) plus a human-type memory note that STARTS with the system marker,
-- so 251 keeps it whole. A failure in the guard NEVER breaks the message insert (EXCEPTION -> WARNING).
--
-- Assertion: supabase/staging/assertions/promesa-sin-escritura.sql. Rollback: ROLLBACK-296-promesa-sin-escritura.sql.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.cerebro_promesas_sin_escritura (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id     uuid NOT NULL,
  message_id          uuid NOT NULL UNIQUE,
  message_created_at  timestamptz NOT NULL,
  content_excerpt     text NOT NULL,
  note_id             integer,
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE public.cerebro_promesas_sin_escritura IS
  'Agent replies that promised a write (anotado / queda registrado) with no tool_execution_log row in the turn. '
  'One row per message; note_id points at the cerebro_memoria system note left for the next turn. '
  'Written only by cerebro_promesa_sin_escritura_guardar.';

REVOKE ALL ON TABLE public.cerebro_promesas_sin_escritura FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.cerebro_texto_promete(p_texto text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT coalesce(p_texto, '') ~* '((^|[^[:alpha:]])anotad[oa]([^[:alpha:]]|$)|queda[[:space:]]+(registrad|anotad|as[ií])|qued[oó][[:space:]]+(registrad|anotad))';
$function$;

COMMENT ON FUNCTION public.cerebro_texto_promete(text) IS
  'True when the reply promises that something was saved: Anotado/Anotada, queda registrado/anotado/así, '
  'quedó registrado/anotado. The design pattern plus the common past forms.';

CREATE OR REPLACE FUNCTION public.cerebro_promesa_sin_escritura_guardar()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id   uuid;
  v_nota integer;
  v_at   timestamptz;
BEGIN
  IF NEW.sender_type IS DISTINCT FROM 'agent' OR NOT coalesce(NEW.ai_generated, false) THEN
    RETURN NEW;
  END IF;
  IF NOT cerebro_texto_promete(NEW.content_text) THEN
    RETURN NEW;
  END IF;

  v_at := coalesce(NEW.created_at, now());
  IF EXISTS (
    SELECT 1 FROM tool_execution_log l
     WHERE l.conversation_id = NEW.conversation_id
       AND l.created_at BETWEEN v_at - interval '3 minutes' AND v_at + interval '1 minute'
  ) THEN
    RETURN NEW;
  END IF;

  BEGIN
    INSERT INTO cerebro_promesas_sin_escritura (conversation_id, message_id, message_created_at, content_excerpt)
    VALUES (NEW.conversation_id, NEW.id, v_at, left(coalesce(NEW.content_text, ''), 240))
    ON CONFLICT (message_id) DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NOT NULL THEN
      INSERT INTO cerebro_memoria (session_id, message)
      VALUES (NEW.conversation_id::text, jsonb_build_object(
        'type', 'human',
        'content', E'[CONTEXTO DEL SISTEMA - el cliente NO ve esto]\n'
          || E'- En tu ultimo mensaje dijiste que algo quedo anotado o registrado, pero en ese turno no se guardo '
          || E'ningun dato en el sistema. Si el cliente te dio un dato (tarjeta, celular, nombre, cuenta, monto, '
          || E'CLABE), registralo con la herramienta que corresponda antes de confirmarlo. Si no habia nada que '
          || E'guardar, no afirmes que quedo anotado.'))
      RETURNING id INTO v_nota;
      UPDATE cerebro_promesas_sin_escritura SET note_id = v_nota WHERE id = v_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] promise guard failed for message %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.cerebro_promesa_sin_escritura_guardar() IS
  'AFTER INSERT on messages: records a promise without a write and leaves the system note for the next turn. '
  'Never breaks the message insert.';

REVOKE ALL ON FUNCTION public.cerebro_promesa_sin_escritura_guardar() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zzz_messages_promesa_sin_escritura ON public.messages;
CREATE TRIGGER zzz_messages_promesa_sin_escritura
  AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.cerebro_promesa_sin_escritura_guardar();
