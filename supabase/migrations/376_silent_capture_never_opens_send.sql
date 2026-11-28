-- 376: silent capture NEVER opens a send (fix of migration 374).
--
-- Production conversation 78e3540b (customer Elisvan, 2026-11-17): the chat was paused for a person, the previous send was already
-- COMPLETED and the customer sent holder + Zelle account so the money could be re-sent after a bounced transfer. 374 delegated to
-- cerebro_guardar_zelle_auto, whose "no open send + holder + account" branch OPENS a send: it opened 73a89429 (0 GYD, waiting for a
-- deposit). With a send waiting for a deposit the bot asked a customer who had already paid for a new deposit and a new receipt.
-- It also skipped the Decisor rule of 2026-11-06 (no open send and no new request -> ask first).
--
-- Now the function resolves the open send first (cerebro_resolver_operacion_beneficiario, same states as the automatic reader) and
-- writes only when exactly one open send is named. No open send, or several and no way to tell: nothing is written and the reason is
-- returned. The guards of 374 stay (human-attending reason, not a split, one distinct account, no other vigente Zelle recipient).
-- Rollback: ROLLBACK-376 restores the 374 body.

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
  v_res    record;
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

  -- (376) NEVER open a send. Only an open send the resolver names with certainty receives the account.
  SELECT * INTO v_res FROM cerebro_resolver_operacion_beneficiario(p_conv,
           ARRAY['collecting_information', 'deposit_verification', 'ready_to_transfer', 'incident'], v_cuenta);
  IF v_res.operation_id IS NULL THEN
    IF v_res.resultado = 'ninguna' THEN
      RETURN QUERY SELECT NULL::uuid, 'no se guarda: no hay un envio abierto donde guardarlo'::text; RETURN;
    END IF;
    RETURN QUERY SELECT NULL::uuid, 'no se guarda: hay varios envios abiertos y no se sabe a cual pertenece'::text; RETURN;
  END IF;

  RETURN QUERY SELECT * FROM cerebro_guardar_zelle(p_conv, coalesce(p_nombre, ''), v_cuenta, p_exec, v_res.operation_id, 'Registrar zelle auto');
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_capturar_en_silencio(uuid, text, text, text[], boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_capturar_en_silencio(uuid, text, text, text[], boolean, text) TO service_role;
