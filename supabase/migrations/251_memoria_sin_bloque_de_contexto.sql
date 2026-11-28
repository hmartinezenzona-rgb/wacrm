-- =====================================================================
-- 251 -- The Cerebro memory stores what the customer said, not the context block
--
-- Production 2026-10-19: the agent's input is the customer's text plus "\n\n[CONTEXTO DEL SISTEMA - el cliente NO ve
-- esto]" and the whole block. memoryPostgresChat stored that input as the human message and replays 30 messages per
-- call, so the model received up to 27 stale copies of the block (one call: ~60% of its input), each with the orders of
-- its day. 4,726 stored human messages carried it; the customer's own text averaged 64 chars of 2,712.
--
-- cerebro_memoria_sin_basura (105/107, BEFORE INSERT on cerebro_memoria) now also cuts a HUMAN message at
-- "\n\n[CONTEXTO DEL SISTEMA" and keeps only what the customer said (trailing blank space trimmed). The current turn is
-- not affected: the agent still receives its full, fresh block; only the stored copy is shorter.
-- A message that STARTS with the block is a system note inserted on purpose (limpiar_memoria_al_liberar,
-- cerebro_rescatar_dsml): it is kept whole. The AI-turn rules are unchanged. The trigger itself is unchanged.
--
-- The rows already stored are cleaned by 252. Assertion: supabase/staging/assertions/memory-without-context-block.sql.
-- Rollback: ROLLBACK-251-memoria-sin-bloque-de-contexto.sql. odd/tasks/cerebro-memory-without-context-block.md
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_memoria_sin_basura()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_contenido text;
  v_corte     integer;
BEGIN
  v_contenido := COALESCE(NEW.message->>'content', '');

  -- (251) Lo que dijo el cliente se guarda; el bloque de contexto pegado detras, no: cada turno trae el suyo, fresco.
  -- Un mensaje que EMPIEZA por el bloque es una nota del sistema puesta a proposito y se guarda entera.
  IF COALESCE(NEW.message->>'type', '') = 'human' THEN
    v_corte := position(E'\n\n[CONTEXTO DEL SISTEMA' in v_contenido);
    IF v_corte > 0 THEN
      NEW.message := jsonb_set(NEW.message, '{content}', to_jsonb(rtrim(left(v_contenido, v_corte - 1), E' \t\r\n')));
    END IF;
    RETURN NEW;
  END IF;

  -- Solo el turno del asistente. Lo que dijo el cliente se guarda siempre.
  IF COALESCE(NEW.message->>'type', '') <> 'ai' THEN
    RETURN NEW;
  END IF;

  -- Marcado DSML (las 3 variantes llevan la palabra) o un tool_calls crudo:
  -- texto que la frontera bloqueó y que el cliente nunca recibió.
  IF v_contenido LIKE '%DSML%' OR v_contenido LIKE '%tool_calls%' THEN
    RETURN NULL;
  END IF;

  -- `SKIP` se guarda: es la respuesta que el prompt pide para callar.
  RETURN NEW;
END;
$function$;
