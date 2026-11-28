-- ROLLBACK of 247_combo_ignores_negated_mention.sql: restores cerebro_combo_en_curso and cerebro_textos_cliente_recientes
-- exactly as staging and production had them on 2026-10-19 (pg_get_functiondef md5 18a50de6dbc7bffb63cde956b3348d59 = 209
-- body and 1172a0956f32cb06b5b32ecb0beccdf6 = 202 body), then drops the two helpers 247 added. ACLs are untouched by
-- CREATE OR REPLACE. Operations already opened keep their service_type.

CREATE OR REPLACE FUNCTION public.cerebro_combo_en_curso(p_conv uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (209) The customer asked for a combo in the recent window (combo/combos, or mandar/enviar comida) and no card is
  -- pending: the same rule shape as cerebro_recarga_en_curso.
  SELECT (coalesce(cerebro_textos_cliente_recientes(p_conv)
                     ~* '(\mcombos?\M|\m(mandar|enviar|mando|envio|envío)\s+(la\s+|una\s+|unas\s+|mucha\s+)?comida)', false)
          AND NOT EXISTS (SELECT 1 FROM cerebro_beneficiario_parcial bp
                           WHERE bp.conversation_id = p_conv AND COALESCE(bp.tarjeta, '') <> ''))
      -- or a combo is already open (the agent opened it with its recipients)
      OR EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.service_type = 'combo'
                    AND o.status NOT IN ('completed', 'cancelled'));
$function$
;

CREATE OR REPLACE FUNCTION public.cerebro_textos_cliente_recientes(p_conv uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (202) What the customer TYPED since the last closed operation, at most 24 h back (the recharge window, 079/160).
  SELECT string_agg(m.content_text, ' ' ORDER BY m.created_at)
    FROM messages m
   WHERE m.conversation_id = p_conv AND m.sender_type = 'customer'
     AND m.created_at > GREATEST(now() - interval '24 hours',
           COALESCE((SELECT max(op.updated_at) FROM remittance_operations op
                      WHERE op.conversation_id = p_conv AND op.status IN ('completed','cancelled')),
                    now() - interval '24 hours'));
$function$
;

DROP FUNCTION IF EXISTS public.cerebro_texto_pide_combo(text);
DROP FUNCTION IF EXISTS public.cerebro_textos_cliente_desde(uuid);

NOTIFY pgrst, 'reload schema';
