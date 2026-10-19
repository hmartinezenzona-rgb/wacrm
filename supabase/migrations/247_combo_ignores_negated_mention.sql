-- =====================================================================
-- 247 -- A negated "combo" is not a combo order
--
-- Production 2026-10-19 (conversation c2bb35c0): the customer pasted Zelle payee instructions ending in
-- "NO ESCRIBIR NADA DE CUBA REMESAS NI COMBO ECT". cerebro_combo_en_curso (209) matched the bare word "combo"
-- in cerebro_textos_cliente_recientes, so the receipt that followed opened a combo operation instead of a remesa.
--
--   - cerebro_texto_pide_combo(text): the 209 text rule for ONE message, minus the mentions negated in the same
--     clause: a "combo(s)" or "comida" preceded by no / ni / nada / sin / nunca / tampoco with no . , ; : ! ? ¡ ¿ or
--     newline in between (at most 60 chars) is dropped before matching. "No, quiero un combo" still orders one.
--   - cerebro_textos_cliente_desde(conv): the start of the recent-text window, taken out of
--     cerebro_textos_cliente_recientes (202) unchanged, so the window lives in one place.
--   - cerebro_textos_cliente_recientes: same output, now reads the window from the function above.
--   - cerebro_combo_en_curso: the text branch tests each message of the window on its own. The joined text glues the
--     last word of a message to the first of the next one, so a trailing "no" would negate the next message's order.
--     The pending-card guard and the open-combo branch are unchanged.
--
-- ACLs: CREATE OR REPLACE keeps the existing ones; the new functions are service_role only.
-- Assertion: supabase/staging/assertions/combo-negated-mention.sql. Rollback: ROLLBACK-247-combo-ignores-negated-mention.sql.
-- odd/tasks/combo-negated-mention.md
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_texto_pide_combo(p_texto text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  -- (247) The 209 rule (combo/combos, or mandar/enviar comida) on one message, after dropping negated mentions.
  SELECT coalesce(
           regexp_replace(p_texto,
                          '\m(no|ni|nada|sin|nunca|tampoco)\M[^.,;:!?¡¿\n]{0,60}\m(combos?|comida)\M', ' ', 'gi')
             ~* '(\mcombos?\M|\m(mandar|enviar|mando|envio|envío)\s+(la\s+|una\s+|unas\s+|mucha\s+)?comida)',
           false);
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_textos_cliente_desde(p_conv uuid)
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (202, 247) The customer's recent texts start after the last closed operation, at most 24 h back (079/160).
  SELECT GREATEST(now() - interval '24 hours',
           COALESCE((SELECT max(op.updated_at) FROM remittance_operations op
                      WHERE op.conversation_id = p_conv AND op.status IN ('completed','cancelled')),
                    now() - interval '24 hours'));
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_textos_cliente_recientes(p_conv uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (202) What the customer TYPED since the last closed operation, at most 24 h back (the recharge window, 079/160).
  -- (247) The window comes from cerebro_textos_cliente_desde.
  SELECT string_agg(m.content_text, ' ' ORDER BY m.created_at)
    FROM messages m
   WHERE m.conversation_id = p_conv AND m.sender_type = 'customer'
     AND m.created_at > cerebro_textos_cliente_desde(p_conv);
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_combo_en_curso(p_conv uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (209) The customer asked for a combo in the recent window (combo/combos, or mandar/enviar comida) and no card is
  -- pending: the same rule shape as cerebro_recarga_en_curso.
  -- (247) Message by message, and a negated mention ("ni combo") is not an order.
  SELECT (EXISTS (SELECT 1 FROM messages m
                   WHERE m.conversation_id = p_conv AND m.sender_type = 'customer'
                     AND m.created_at > cerebro_textos_cliente_desde(p_conv)
                     AND cerebro_texto_pide_combo(m.content_text))
          AND NOT EXISTS (SELECT 1 FROM cerebro_beneficiario_parcial bp
                           WHERE bp.conversation_id = p_conv AND COALESCE(bp.tarjeta, '') <> ''))
      -- or a combo is already open (the agent opened it with its recipients)
      OR EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.service_type = 'combo'
                    AND o.status NOT IN ('completed', 'cancelled'));
$function$;

REVOKE ALL ON FUNCTION public.cerebro_texto_pide_combo(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_texto_pide_combo(text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_textos_cliente_desde(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_textos_cliente_desde(uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
