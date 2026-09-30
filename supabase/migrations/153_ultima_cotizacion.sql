-- =====================================================================
-- 153 — Remember the last quote, so the bot can say how much the
--        recipient gets BEFORE the deposit (B1.1)
--
-- PROBLEM (real staging test, 2026-09-30): the customer was quoted
--   "Por 10,000 GYD llegan 30,000 CUP", then gave the card and phone. The
--   bot confirmed them WITHOUT the amount. B1.1 read the amount from
--   remittance_operations.quoted_destination_amount, but the operation is
--   created when the beneficiary arrives with quoted_source_amount = 0, and
--   only gets a real amount when the deposit lands. So B1.1 could only ever
--   fire after the deposit, while the confirmation happens before it.
--   Of the four quote tools only calcular_usd left any trace (through the
--   shipment target); calcular_envio — the CUP one, the most used — kept
--   nothing and does not even receive the conversation id.
--
-- DECISION: do NOT write the quote into remittance_operations: the
--   operation amount feeds deposit matching, the reparto detector
--   (quoted_source_amount > 0) and the ledger. And do NOT reuse the shipment
--   target: A3/152 deliberately keep bare quotes out of it. Instead a tiny
--   per-conversation record of the LAST quote, used for nothing but saying
--   the number back to the customer.
--
-- WHAT
--   1. cerebro_ultima_cotizacion: one row per conversation — the GYD the
--      customer would deposit, the destination amount and currency exactly
--      as the tool computed them (no rounding rule is duplicated here), the
--      tool, and when.
--   2. cerebro_registrar_cotizacion(conv, origen_gyd, destino, moneda,
--      herramienta): upsert; NULL conversation or destination is a no-op.
--      The four n8n quote tools call it from the same query that computes
--      the quote (deterministic, same reasoning as calcular_usd -> fijar
--      objetivo in 072/075).
--   3. cerebro_monto_recibe(conv) -> (valor, moneda): what `Contexto
--      conversacion` shows the agent as monto_recibe_*. The open operation's
--      own destination amount wins when it exists (after the deposit, it is
--      the truth); otherwise the last quote, only if it is newer than the
--      conversation's last closed remesa and younger than 24 hours.
--      Otherwise NULL, and the prompt already says: no amount, don't invent.
--   Same lock-down as the other cerebro_* objects: RLS on with no policy,
--   functions executable only by postgres and service_role.
--
-- ROLLBACK: ROLLBACK-153-ultima-cotizacion.sql
-- Guarded by supabase/staging/assertions/ultima-cotizacion.sql
-- =====================================================================

CREATE TABLE IF NOT EXISTS cerebro_ultima_cotizacion (
  conversation_id uuid PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
  origen_gyd      numeric,
  destino_monto   numeric NOT NULL,
  destino_moneda  text NOT NULL CHECK (destino_moneda IN ('CUP', 'USD')),
  herramienta     text NOT NULL,
  cotizado_en     timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE cerebro_ultima_cotizacion ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON cerebro_ultima_cotizacion FROM anon, authenticated;

COMMENT ON TABLE cerebro_ultima_cotizacion IS
  '153. Last quote per conversation, only for telling the customer how much the '
  'recipient gets before the deposit (B1.1). Never used for deposit matching.';

CREATE OR REPLACE FUNCTION cerebro_registrar_cotizacion(
  p_conv        uuid,
  p_origen_gyd  numeric,
  p_destino     numeric,
  p_moneda      text,
  p_herramienta text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_conv IS NULL OR p_destino IS NULL OR upper(p_moneda) NOT IN ('CUP', 'USD') THEN
    RETURN;
  END IF;

  INSERT INTO cerebro_ultima_cotizacion AS q
    (conversation_id, origen_gyd, destino_monto, destino_moneda, herramienta, cotizado_en)
  VALUES (p_conv, p_origen_gyd, p_destino, upper(p_moneda), p_herramienta, now())
  ON CONFLICT (conversation_id) DO UPDATE
     SET origen_gyd     = EXCLUDED.origen_gyd,
         destino_monto  = EXCLUDED.destino_monto,
         destino_moneda = EXCLUDED.destino_moneda,
         herramienta    = EXCLUDED.herramienta,
         cotizado_en    = EXCLUDED.cotizado_en;
END;
$$;

CREATE OR REPLACE FUNCTION cerebro_monto_recibe(p_conv uuid)
RETURNS TABLE (valor numeric, moneda text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_valor  numeric;
  v_moneda text;
BEGIN
  -- The open remesa's own amount, when it has one (after the deposit).
  SELECT NULLIF(o.quoted_destination_amount, 0), o.destination_currency
    INTO v_valor, v_moneda
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv
     AND o.status NOT IN ('completed', 'cancelled')
   ORDER BY o.created_at DESC
   LIMIT 1;

  IF v_valor IS NOT NULL AND v_moneda IS NOT NULL THEN
    RETURN QUERY SELECT v_valor, v_moneda;
    RETURN;
  END IF;

  -- Otherwise the last quote, if it belongs to this remesa and is recent.
  RETURN QUERY
  SELECT q.destino_monto, q.destino_moneda
    FROM cerebro_ultima_cotizacion q
   WHERE q.conversation_id = p_conv
     AND q.cotizado_en > now() - interval '24 hours'
     AND q.cotizado_en > COALESCE(
           (SELECT max(COALESCE(o2.completed_at, o2.cancelled_at, o2.created_at))
              FROM remittance_operations o2
             WHERE o2.conversation_id = p_conv
               AND o2.status IN ('completed', 'cancelled')),
           '-infinity'::timestamptz);

  IF NOT FOUND THEN
    RETURN QUERY SELECT NULL::numeric, NULL::text;
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION cerebro_registrar_cotizacion(uuid, numeric, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_registrar_cotizacion(uuid, numeric, numeric, text, text) TO service_role;
REVOKE EXECUTE ON FUNCTION cerebro_monto_recibe(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_monto_recibe(uuid) TO service_role;
