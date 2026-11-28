-- 374: silent capture while a human of the team attends the chat.
--
-- Owner, 2026-11-15: when an admin attends a chat the bot must not answer (as today) but must still collect the data the customer sends, so
-- the operations panel is filled when the admin finishes and nobody asks the customer for data he already gave.
--
-- Production exec 736897 (2026-11-14): the Decisor routed `silencio` ("un humano del equipo acaba de escribir"); the batch carried a Zelle
-- account and the send was open (the receipt had just been registered). Cards, receipts, the destination rail and the ID photo are stored
-- by deterministic nodes that run before the Decisor, so they are already captured in silence. A Zelle account is not: the node
-- `Registrar zelle auto` is disabled since 2026-10-27 (the single-block reader overwrote what the agent registered for several
-- recipients) and the agent does not run on the silence route. This function is the Zelle reader for the silence route only, where
-- the agent cannot conflict with it.
--
-- Guards (all must hold, otherwise nothing is written and the reason is returned):
--   * the silence is a human-attending one (bot paused by hand, chat assigned, a human just wrote);
--   * the batch is not a split between several people;
--   * the batch carries exactly ONE distinct account (the snapshot can list the same number twice);
--   * no open send of the conversation already has a vigente Zelle recipient with another account (agent or admin wrote it).
-- The write itself is cerebro_guardar_zelle_auto, unchanged: with an open send the account (or holder) alone is stored, without one only
-- holder + account opens it, and the 367 history guard still applies. It never sends anything to the customer.

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

REVOKE ALL ON FUNCTION public.cerebro_capturar_en_silencio(uuid, text, text, text[], boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_capturar_en_silencio(uuid, text, text, text[], boolean, text) TO service_role;
