-- ROLLBACK of 251_memoria_sin_bloque_de_contexto.sql: restores cerebro_memoria_sin_basura exactly as staging and production
-- had it on 2026-10-19 (pg_get_functiondef md5 8cc5f5f8656da415b0d15be39b429977, the 105/107 body). New customer turns are
-- stored with the block again. Rows already cut stay cut (252 has its own rollback).

CREATE OR REPLACE FUNCTION public.cerebro_memoria_sin_basura()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_contenido text;
BEGIN
  -- Solo el turno del asistente. Lo que dijo el cliente se guarda siempre.
  IF COALESCE(NEW.message->>'type', '') <> 'ai' THEN
    RETURN NEW;
  END IF;

  v_contenido := COALESCE(NEW.message->>'content', '');

  -- Marcado DSML (las 3 variantes llevan la palabra) o un tool_calls crudo:
  -- texto que la frontera bloqueó y que el cliente nunca recibió.
  IF v_contenido LIKE '%DSML%' OR v_contenido LIKE '%tool_calls%' THEN
    RETURN NULL;
  END IF;

  -- `SKIP` se guarda: es la respuesta que el prompt pide para callar.
  RETURN NEW;
END;
$function$
;
