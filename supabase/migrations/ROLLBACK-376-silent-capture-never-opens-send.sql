-- Rollback of 376: restores the body of migration 374 (the version that can open a send). Not recommended: see 376.

CREATE OR REPLACE FUNCTION public.cerebro_capturar_en_silencio(
  p_conv uuid, p_motivo text, p_nombre text, p_cuentas text[], p_multi boolean, p_exec text)
 RETURNS TABLE(deal_id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_normas text[];
  v_cuenta text;
BEGIN
  IF p_conv IS NULL OR coalesce(p_motivo, '') !~* '(bot pausado|chat asignado|un humano del equipo)' THEN
    RETURN QUERY SELECT NULL::uuid, 'no aplica: el silencio no es por atencion humana'::text; RETURN;
  END IF;
  IF coalesce(p_multi, false) THEN
    RETURN QUERY SELECT NULL::uuid, 'no se guarda: el lote es un reparto entre varias personas'::text; RETURN;
  END IF;

  SELECT array_agg(DISTINCT t.n) INTO v_normas
    FROM (SELECT cerebro_norm_cuenta_zelle(x) AS n FROM unnest(coalesce(p_cuentas, ARRAY[]::text[])) x) t
   WHERE t.n IS NOT NULL;
  IF v_normas IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, 'sin cuenta Zelle en este lote'::text; RETURN;
  END IF;
  IF cardinality(v_normas) > 1 THEN
    RETURN QUERY SELECT NULL::uuid, 'no se guarda: el lote trae varias cuentas Zelle'::text; RETURN;
  END IF;
  -- the account as the customer wrote it
  SELECT x INTO v_cuenta FROM unnest(p_cuentas) x WHERE cerebro_norm_cuenta_zelle(x) = v_normas[1] LIMIT 1;

  IF EXISTS (
    SELECT 1
      FROM remittance_beneficiaries b
      JOIN remittance_operations o ON o.id = b.operation_id
     WHERE o.conversation_id = p_conv
       AND o.status IN ('collecting_information', 'deposit_verification', 'ready_to_transfer', 'incident')
       AND b.status = 'vigente' AND b.beneficiary_type = 'zelle'
       AND cerebro_norm_cuenta_zelle(b.zelle_account) IS NOT NULL
       AND cerebro_norm_cuenta_zelle(b.zelle_account) <> v_normas[1]
  ) THEN
    RETURN QUERY SELECT NULL::uuid, 'no se guarda: el envio ya tiene otro destinatario Zelle'::text; RETURN;
  END IF;

  RETURN QUERY SELECT * FROM cerebro_guardar_zelle_auto(p_conv, coalesce(p_nombre, ''), v_cuenta, p_exec);
END $function$;
