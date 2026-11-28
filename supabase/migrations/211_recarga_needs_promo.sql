-- =====================================================================
-- 211 — A mentioned recharge needs a promo, and never goes by Zelle
--
-- Production 2026-10-02 (Yilian, op 89f6df7e) and 2026-09-23 (Yusmila, op 12510beb): the customer asked about a
-- recharge, there was no promo, and a later deposit for something else (a 320 USD Zelle, a cash delivery) was filed
-- as a recharge. The typed-text rule of cerebro_recarga_en_curso only looked for "recarga|etecsa|cubacel" in the last
-- 24 h and a pending card. The owner's rule is that there are no recharges without a promo (206/207).
--   * The typed-text rule now also needs a promo running or a confirmed one ahead (cerebro_promo_vigente /
--     cerebro_promo_proxima, the same test crm_registrar_numeros_recarga uses since 207), and no Zelle: neither
--     "zelle" typed in the window nor Zelle data pending in cerebro_beneficiario_parcial.
--   * An open recharge still counts as in progress, whatever the promo (204).
-- Callers (cerebro_registrar_deposito, crm_registrar_numeros_recarga, cerebro_guardar_beneficiario_auto) are not
-- touched: they all ask this function.
-- Assertion: supabase/staging/assertions/recarga-needs-promo.sql. Rollback: ROLLBACK-211-recarga-needs-promo.sql.
-- =====================================================================
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
$function$;
