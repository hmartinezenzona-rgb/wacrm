-- =====================================================================
-- 187 — the operations panel reads the bot's current quote (staging first)
--
-- odd/tasks/panel-shows-quote.md. An operation opened from beneficiary data shows 0 GYD until the
-- first deposit, although the bot already quoted ("Para que lleguen *15,000 CUP* necesita depositar
-- *5,000 GYD*"). quoted_source_amount is the DEPOSITED total (cerebro_registrar_deposito overwrites
-- it), and fixing a CUP target the calcular_usd way would turn a deposit above the quote into an
-- Incidencia (owner, 2026-10-02: above the quote transfers the equivalent). So the panel only READS
-- the quote: this function changes nothing.
--
-- Source: cerebro_cotizacion (171), the latest quote per conversation, written by the trigger on the
-- bot's messages; valid exactly like cerebro_cotizacion_vigente (cotizacion_ventana_horas, and after
-- the chat's last closed remesa). The destination amount is the first "*N CUP*" / "*N USD*" of the
-- quoting message. Authorization as crm_operaciones_de_conversacion (097): viewer of the
-- conversation's account, 42501 otherwise.
--
-- Guarded by supabase/staging/assertions/panel-quote.sql.
-- ROLLBACK: ROLLBACK-187-panel-quote.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.crm_cotizacion_de_conversacion(p_conversation_id uuid)
RETURNS TABLE(gyd numeric, destino_monto numeric, destino_moneda text, cotizado_en timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id uuid;
BEGIN
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;
  SELECT c.account_id INTO v_account_id FROM conversations c WHERE c.id = p_conversation_id;
  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH q AS (
    SELECT c.gyd, c.texto, c.cotizado_en,
           regexp_match(coalesce(c.texto, ''), '\*([0-9][0-9,]*(?:\.[0-9]+)?) (CUP|USD)\*', 'i') AS m
      FROM cerebro_cotizacion c
     WHERE c.conversation_id = p_conversation_id
       AND c.gyd IS NOT DISTINCT FROM cerebro_cotizacion_vigente(p_conversation_id)
       AND cerebro_cotizacion_vigente(p_conversation_id) IS NOT NULL
  )
  SELECT q.gyd,
         CASE WHEN q.m IS NOT NULL THEN replace(q.m[1], ',', '')::numeric END,
         CASE WHEN q.m IS NOT NULL THEN upper(q.m[2]) END,
         q.cotizado_en
    FROM q;
END $$;

REVOKE ALL ON FUNCTION public.crm_cotizacion_de_conversacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_cotizacion_de_conversacion(uuid) TO authenticated;
