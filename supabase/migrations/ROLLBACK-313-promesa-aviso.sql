-- ROLLBACK 313: restores the guard without the admin alert.

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
