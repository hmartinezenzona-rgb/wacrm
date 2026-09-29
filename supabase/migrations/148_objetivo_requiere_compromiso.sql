-- =====================================================================
-- 148 — cerebro_fijar_objetivo requires a real commitment, not a bare quote
--
-- PROBLEM (A3, production feedback 2026-09-29): a customer asking "¿cuánto
-- me da 100 USD?" — pure curiosity, no beneficiary given, no deposit sent
-- yet — set a persistent `cerebro_objetivo_envio` row via `calcular_usd`'s
-- deterministic side effect (072/075: "AND ALONG THE WAY IT POINTS THE
-- SHIPMENT TARGET"). That target has no expiry (`cerebro_objetivo_atar`
-- attaches ANY open, unattached target to the next deal in the same
-- conversation with no freshness check), so a stale, abandoned quote from
-- one day became the next day's UNRELATED deposit's target and raised a
-- false "DEPOSITO DE MAS". Reported by the user: "no me parece que deba
-- seguir".
--
-- DECISION (user, 2026-09-29): a bare quote must not create anything.
-- The target should only be set once there is a real commitment signal
-- for THAT conversation — the customer has already given beneficiary
-- data, or already sent a receipt/deposit.
--
-- FIX: `cerebro_fijar_objetivo` now checks, before persisting, whether
-- the conversation already has (a) a `vigente` beneficiary on one of its
-- operations, or (b) a `comprobantes_hashes` row for the contact's phone
-- (a receipt already sent). If neither is true, it returns without
-- writing anything — `calcular_usd` still returns the numeric quote to
-- the customer either way; only the side effect is gated. Every other
-- line of the function (currency parsing, the fijado/sustituido/sin
-- cambios wording, the ON CONFLICT upsert) is untouched from 075.
--
-- This does not retroactively expire an ALREADY-open, unattached target
-- from before this migration — only new `fijar_objetivo` calls are
-- gated. A pre-existing stale row still needs a human to close it by
-- hand (or a future task) if one exists when this ships.
--
-- Guarded by supabase/staging/assertions/objetivo-requiere-compromiso.sql
-- ROLLBACK: ROLLBACK-148-objetivo-requiere-compromiso.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_fijar_objetivo(
  p_conv   uuid,
  p_monto  numeric,
  p_moneda text DEFAULT 'GYD')
RETURNS TABLE(objetivo_gyd numeric, pedido text, accion text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_mon        text;
  v_gyd        numeric;
  v_pedido     text;
  v_tasa       numeric;
  v_previo     numeric;
  v_cerrado    timestamptz;
  v_accion     text;
  v_compromiso boolean;
BEGIN
  v_mon := lower(COALESCE(NULLIF(trim(p_moneda), ''), 'gyd'));

  IF p_monto IS NULL OR p_monto <= 0 THEN
    RETURN QUERY SELECT NULL::numeric, NULL::text,
      'NO se fijo nada: el importe no es valido'::text; RETURN;
  END IF;

  -- (148) Sin beneficiario ni comprobante todavia, esto es solo una
  -- cotizacion: el cliente puede estar preguntando por curiosidad, sin
  -- intencion de enviar. No se fija nada — calcular_usd ya le dio el
  -- numero, que es lo unico que pidio.
  SELECT
    EXISTS (
      SELECT 1 FROM remittance_operations o
        JOIN remittance_beneficiaries b ON b.operation_id = o.id
       WHERE o.conversation_id = p_conv AND b.status = 'vigente'
    )
    OR EXISTS (
      SELECT 1 FROM comprobantes_hashes ch
        JOIN conversations v ON v.id = p_conv
        JOIN contacts c ON c.id = v.contact_id
       WHERE ch.cliente_whatsapp = c.phone
    )
    INTO v_compromiso;

  IF NOT v_compromiso THEN
    RETURN QUERY SELECT NULL::numeric, NULL::text,
      'NO se fijo nada: sin beneficiario ni comprobante todavia (solo cotizacion)'::text;
    RETURN;
  END IF;

  IF v_mon = 'gyd' THEN
    v_gyd    := round(p_monto);
    v_pedido := rtrim(trim(to_char(v_gyd,'FM999,999,999,990.99')),'.') || ' GYD';
  ELSIF v_mon = 'usd' THEN
    SELECT t.tasa_cup INTO v_tasa FROM tasas t
     WHERE t.moneda = 'usd' ORDER BY t.fecha DESC, t.actualizada_at DESC LIMIT 1;
    IF v_tasa IS NULL THEN
      RETURN QUERY SELECT NULL::numeric, NULL::text,
        'NO se fijo nada: no hay tasa de USD'::text; RETURN;
    END IF;
    -- floor, igual que calcular_usd: los dolares se entregan enteros.
    v_gyd    := round(floor(p_monto) * v_tasa);
    v_pedido := rtrim(trim(to_char(floor(p_monto),'FM999,999,999,990')),'.') || ' USD';
  ELSE
    RETURN QUERY SELECT NULL::numeric, NULL::text,
      ('NO se fijo nada: moneda no soportada (' || p_moneda || '). Solo GYD o USD')::text; RETURN;
  END IF;

  SELECT o.monto, o.cerrado_en INTO v_previo, v_cerrado
    FROM cerebro_objetivo_envio o WHERE o.conversation_id = p_conv;

  IF v_previo IS NULL THEN
    v_accion := 'objetivo fijado';
  ELSIF v_cerrado IS NOT NULL THEN
    v_accion := 'envio nuevo: el anterior ya se completo';
  ELSIF v_previo = v_gyd THEN
    v_accion := 'sin cambios, ya estaba fijado';
  ELSE
    v_accion := 'objetivo sustituido (antes '
                || rtrim(trim(to_char(v_previo,'FM999,999,999,990.99')),'.') || ' GYD)';
  END IF;

  INSERT INTO cerebro_objetivo_envio AS o (conversation_id, monto, moneda, pedido)
  VALUES (p_conv, v_gyd, 'GYD', v_pedido)
  ON CONFLICT (conversation_id) DO UPDATE
     SET monto      = EXCLUDED.monto,
         moneda     = 'GYD',
         pedido     = EXCLUDED.pedido,
         fijado_en  = now(),
         deal_id    = CASE WHEN o.cerrado_en IS NOT NULL THEN NULL ELSE o.deal_id END,
         cerrado_en = NULL;

  RETURN QUERY SELECT v_gyd, v_pedido, v_accion;
END;
$function$;
