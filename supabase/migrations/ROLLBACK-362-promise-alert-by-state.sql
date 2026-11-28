-- ROLLBACK 362: restores the immediate promise guard (313 body) and the 296 claim matcher; removes the evaluator,
-- the saved-state helper, the candidate table and the cron job. Pending candidates are discarded.

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'evaluar-promesas') THEN
    PERFORM cron.unschedule('evaluar-promesas');
  END IF;
END;
$cron$;

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
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id   uuid;
  v_nota integer;
  v_at   timestamptz;
  v_admin text;
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

      -- (313) Aviso al admin: el bot prometio y no escribio. Best-effort: un fallo
      -- del aviso NO puede tumbar la insercion del mensaje.
      BEGIN
        SELECT c.phone INTO v_admin
          FROM contacts c
          JOIN contact_tags ct ON ct.contact_id = c.id
          JOIN tags t ON t.id = ct.tag_id
         WHERE lower(t.name) = 'admin'
         ORDER BY c.created_at
         LIMIT 1;
        IF v_admin IS NOT NULL THEN
          PERFORM cerebro_outbox_encolar(
            NEW.conversation_id,
            v_admin,
            'AVISO PROMESA: el bot dijo que anotaba algo y no lo guardo.' || chr(10) || chr(10)
              || 'Conversacion: ' || left(NEW.conversation_id::text, 8) || chr(10)
              || 'Hora UTC: ' || to_char(v_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || chr(10)
              || 'Revise el chat y registre el dato si falta.',
            NULL,
            'promesa-' || NEW.id::text);
        END IF;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[wacrm] promise alert failed for message %: %', NEW.id, SQLERRM;
      END;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] promise guard failed for message %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.cerebro_promesa_sin_escritura_guardar() IS
  'AFTER INSERT on messages: records a promise without a write and leaves the system note for the next turn. Never breaks the message insert.';

DROP FUNCTION IF EXISTS public.cerebro_promesa_evaluar(timestamptz);
DROP FUNCTION IF EXISTS public.cerebro_promesa_estado_guardado(uuid, timestamptz, timestamptz);
DROP TABLE IF EXISTS public.cerebro_promesa_candidatas;
