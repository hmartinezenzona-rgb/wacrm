-- ROLLBACK of 211_recarga_needs_promo.sql: cerebro_recarga_en_curso exactly as before 211 (md5 d0f1665359806fdade30df67b04c07c2 on
-- staging and production, 2026-10-04).
CREATE OR REPLACE FUNCTION public.cerebro_recarga_en_curso(p_conv uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (202) The customer asked for a recharge in that window (recarga/etecsa/cubacel) and no card is pending: the
  -- same rule cerebro_registrar_deposito used inline since 160 to file a deposit as a recharge.
  SELECT (coalesce(cerebro_textos_cliente_recientes(p_conv) ~* '(recarga|etecsa|cubacel)', false)
          AND NOT EXISTS (SELECT 1 FROM cerebro_beneficiario_parcial bp
                           WHERE bp.conversation_id = p_conv AND COALESCE(bp.tarjeta, '') <> ''))
      -- (204) or a recharge is already open (the agent opened it: asked for by audio)
      OR EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.service_type = 'recarga'
                    AND o.status NOT IN ('completed', 'cancelled'));
$function$
;
