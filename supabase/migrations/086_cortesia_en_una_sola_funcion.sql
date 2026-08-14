-- 086 — La regla de cortesia, en UN solo sitio
--
-- POR QUE
-- La 085 bajo el ruido de los avisos, pero la idea buena de Osmany es otra:
-- **que el bot cierre el agradecimiento**. Si nadie deja el mensaje sin
-- responder, no hay chat atascado — para cualquier redaccion y cualquier
-- idioma. Deja de ser un filtro y pasa a ser la raiz.
--
-- Para eso el Cerebro necesita la MISMA nocion de "esto es cortesia pura" que
-- usa el vigilante. Copiarla seria pedir que se separen: ya paso con la
-- deteccion de recargas, que vive en dos sitios y lleva un comentario avisando
-- de que cambiar una es cambiar la otra. Asi que se saca a una funcion y el
-- vigilante pasa a llamarla.
--
-- LA REGLA NO CAMBIA NI UNA COMA. Es la de la 062 mas la raiz de la 085, movida
-- tal cual. Sus cuatro guardas, y que hace cada una:
--   content_type='text'  una imagen o un audio NUNCA son una despedida
--   sin '?'              si pregunta algo, espera respuesta
--   sin digitos          una tarjeta, un monto o un telefono son un DATO
--   lista de pendientes  cierra el hueco de "ok pero y mi dinero"
--
-- COMO SE APLICA
-- Igual que la 085: se lee la definicion VIVA del vigilante y se sustituye el
-- bloque por la llamada. Si el ancla no aparece, aborta y no toca nada.
--
-- REVERSION
--   Volver a poner el bloque inline en el vigilante y DROP FUNCTION.

CREATE OR REPLACE FUNCTION public.cerebro_es_cortesia(p_texto text, p_content_type text DEFAULT 'text')
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT p_content_type = 'text' AND (
    -- 1. Acuse puro: el texto ENTERO es una de estas palabras.
    btrim(lower(coalesce(p_texto, '')), E' \t\n.,!¡¿?:;-👍🙏😊😉✅❤️')
        ~ ('^(|ok|oka|okay|okey|oki|vale|listo|dale|gra[cs]ias?|muchas gra[cs]ias?|'
        || 'perfecto|perfect|bien|bueno|entendido|entiendo|de acuerdo|'
        || 'thank you|thanks|thank u|ty|got it|understood|alright|'
        || 'sure|yes|yep|yeah|si|sí)$')
    OR
    -- 2. Despedida de cortesia: LLEVA una formula de cortesia, es corta, no
    --    pregunta nada, no trae ningun dato y no menciona nada pendiente.
    ( length(btrim(coalesce(p_texto, ''))) <= 60
      AND p_texto !~ '\?'
      AND p_texto !~ '[0-9]'
      AND lower(p_texto) ~ '(gra[cs]ias?|thank|okay|okey|^ok\M|vale|perfecto|listo|bendicion|saludos|besos)'
      AND lower(p_texto) !~ '(cuando|cuándo|todavia|todavía|aun|aún|falta|esper|pendiente|dinero|plata|transferencia|demora|tarda|no me|no ha|no lle)'
    )
  );
$fn$;

REVOKE ALL ON FUNCTION public.cerebro_es_cortesia(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_es_cortesia(text, text) TO service_role;

DO $mig$
DECLARE v_def text; v_ini text; v_bloque text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'cerebro_avisar_chats_atascados';
  v_ini := v_def;

  v_bloque :=
'             a.sender_type = ''agent''
             AND u.content_type = ''text''
             AND (
               btrim(lower(coalesce(u.content_text, '''')), E'' \t\n.,!¡¿?:;-👍🙏😊😉✅❤️'')
                   ~ (''^(|ok|oka|okay|okey|oki|vale|listo|dale|gra[cs]ias?|muchas gra[cs]ias?|''
                   || ''perfecto|perfect|bien|bueno|entendido|entiendo|de acuerdo|''
                   || ''thank you|thanks|thank u|ty|got it|understood|alright|''
                   || ''sure|yes|yep|yeah|si|sí)$'')
               OR
               ( length(btrim(coalesce(u.content_text, ''''))) <= 60
                 AND u.content_text !~ ''\?''
                 AND u.content_text !~ ''[0-9]''
                 AND lower(u.content_text) ~ ''(gra[cs]ias?|thank|okay|okey|^ok\M|vale|perfecto|listo|bendicion|saludos|besos)''
                 AND lower(u.content_text) !~ ''(cuando|cuándo|todavia|todavía|aun|aún|falta|esper|pendiente|dinero|plata|transferencia|demora|tarda|no me|no ha|no lle)''
               )
             )';

  IF position(v_bloque in v_def) = 0 THEN
    RAISE EXCEPTION 'el bloque de cortesia no aparece tal cual en la funcion viva';
  END IF;

  v_def := replace(v_def, v_bloque,
'             a.sender_type = ''agent''
             AND cerebro_es_cortesia(u.content_text, u.content_type)');

  IF v_def = v_ini THEN
    RAISE EXCEPTION 'no se sustituyo nada';
  END IF;
  EXECUTE v_def;
END $mig$;