-- ROLLBACK of 247_recarga_ignores_negated_mention.sql: restores cerebro_recarga_en_curso exactly as staging and production had
-- it on 2026-10-19 (pg_get_functiondef md5 4146aaff4172c6c049d07442ef889675, the 202/211 body) and cerebro_texto_pide_combo
-- as 246 left it (md5 aa4951d64887136ec30c3d831509d3ee), then drops the two helpers 247 added. ACLs are untouched by
-- CREATE OR REPLACE. 246 stays in place.

CREATE OR REPLACE FUNCTION public.cerebro_recarga_en_curso(p_conv uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (202) The customer asked for a recharge in that window (recarga/etecsa/cubacel) and no card is pending: the
  -- same rule cerebro_registrar_deposito used inline since 160 to file a deposit as a recharge.
  -- (211) Only while a promo is running or confirmed ahead, and never with Zelle typed or pending.
  SELECT (coalesce(cerebro_textos_cliente_recientes(p_conv) ~* '(recarga|etecsa|cubacel)', false)
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
$function$
;

CREATE OR REPLACE FUNCTION public.cerebro_texto_pide_combo(p_texto text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  -- (246) The 209 rule (combo/combos, or mandar/enviar comida) on one message, after dropping negated mentions.
  SELECT coalesce(
           regexp_replace(p_texto,
                          '\m(no|ni|nada|sin|nunca|tampoco)\M[^.,;:!?¡¿\n]{0,60}\m(combos?|comida)\M', ' ', 'gi')
             ~* '(\mcombos?\M|\m(mandar|enviar|mando|envio|envío)\s+(la\s+|una\s+|unas\s+|mucha\s+)?comida)',
           false);
$function$
;

DROP FUNCTION IF EXISTS public.cerebro_texto_pide_recarga(text);
DROP FUNCTION IF EXISTS public.cerebro_quitar_menciones_negadas(text, text);

NOTIFY pgrst, 'reload schema';
