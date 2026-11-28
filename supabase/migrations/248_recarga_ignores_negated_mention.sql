-- =====================================================================
-- 248 -- A negated "recarga" is not a recharge order; one negation rule for combo and recarga
--
-- cerebro_recarga_en_curso (202/211) has the bare-word shape 247 removed from the combo rule: "no quiero recarga" was a
-- recharge order, and it read the joined window text, where a trailing "no" of one message negates the next one.
--
--   - cerebro_quitar_menciones_negadas(text, words): drops every mention of `words` (a regex alternation, matched as
--     whole words) preceded by no / ni / nada / sin / nunca / tampoco in the same clause: no . , ; : ! ? ¡ ¿ or newline
--     in between, at most 60 chars. The rule 247 inlined in cerebro_texto_pide_combo, now in one place.
--   - cerebro_texto_pide_combo: same behaviour as 247, on the shared rule.
--   - cerebro_texto_pide_recarga(text): the 202 text rule (recarga / etecsa / cubacel) for ONE message, minus negated
--     mentions (inflected forms included: recargas, recargar, recargarle).
--   - cerebro_recarga_en_curso: the text branch tests each message of the window (cerebro_textos_cliente_desde, 247).
--     The Zelle guard (any Zelle typed in the window blocks), the promo condition, the pending-card/Zelle guard and the
--     open-recharge branch are unchanged.
--
-- ACLs: CREATE OR REPLACE keeps the existing ones; the new functions are service_role only.
-- Assertion: supabase/staging/assertions/recarga-negated-mention.sql. Rollback: ROLLBACK-248-recarga-ignores-negated-mention.sql.
-- odd/tasks/combo-negated-mention.md
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_quitar_menciones_negadas(p_texto text, p_palabras text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  -- (247, 248) "ni combo", "no quiero recarga": the mention is dropped; "No, quiero un combo" keeps it (clause break).
  SELECT regexp_replace(p_texto,
                        '\m(no|ni|nada|sin|nunca|tampoco)\M[^.,;:!?¡¿\n]{0,60}\m(' || p_palabras || ')\M', ' ', 'gi');
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_texto_pide_combo(p_texto text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  -- (247) The 209 rule (combo/combos, or mandar/enviar comida) on one message, after dropping negated mentions.
  -- (248) The negation rule is shared with the recharge rule.
  SELECT coalesce(
           cerebro_quitar_menciones_negadas(p_texto, 'combos?|comida')
             ~* '(\mcombos?\M|\m(mandar|enviar|mando|envio|envío)\s+(la\s+|una\s+|unas\s+|mucha\s+)?comida)',
           false);
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_texto_pide_recarga(p_texto text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  -- (202, 248) The recharge rule (recarga/etecsa/cubacel) on one message, after dropping negated mentions.
  SELECT coalesce(
           cerebro_quitar_menciones_negadas(p_texto, 'recarga\w*|etecsa|cubacel') ~* '(recarga|etecsa|cubacel)',
           false);
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_recarga_en_curso(p_conv uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (202) The customer asked for a recharge in that window (recarga/etecsa/cubacel) and no card is pending: the
  -- same rule cerebro_registrar_deposito used inline since 160 to file a deposit as a recharge.
  -- (211) Only while a promo is running or confirmed ahead, and never with Zelle typed or pending.
  -- (248) Message by message, and a negated mention ("no quiero recarga") is not an order.
  SELECT (EXISTS (SELECT 1 FROM messages m
                   WHERE m.conversation_id = p_conv AND m.sender_type = 'customer'
                     AND m.created_at > cerebro_textos_cliente_desde(p_conv)
                     AND cerebro_texto_pide_recarga(m.content_text))
          AND NOT coalesce(cerebro_textos_cliente_recientes(p_conv) ~* 'zelle', false)
          AND (EXISTS (SELECT 1 FROM cerebro_promo_vigente()) OR EXISTS (SELECT 1 FROM cerebro_promo_proxima()))
          AND NOT EXISTS (SELECT 1 FROM cerebro_beneficiario_parcial bp
                           WHERE bp.conversation_id = p_conv
                             AND (COALESCE(bp.tarjeta, '') <> '' OR COALESCE(bp.zelle_cuenta, '') <> ''
                                  OR COALESCE(bp.zelle_nombre, '') <> '' OR COALESCE(bp.zelle_nombre_cuenta, '') <> '')))
      -- (204) or a recharge is already open (the agent opened it: asked for by audio)
      OR EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.service_type = 'recarga'
                    AND o.status NOT IN ('completed', 'cancelled'));
$function$;

REVOKE ALL ON FUNCTION public.cerebro_quitar_menciones_negadas(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_quitar_menciones_negadas(text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_texto_pide_recarga(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_texto_pide_recarga(text) TO service_role;

NOTIFY pgrst, 'reload schema';
