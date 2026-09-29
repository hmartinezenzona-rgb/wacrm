-- =====================================================================
-- 146 — Silent marker for a resent (duplicate) receipt
--
-- PROBLEM (A1, production feedback 2026-09-29): when a customer resends a
-- receipt whose image hash is already in comprobantes_hashes, the Cerebro
-- drops it (no second deposit, correct) but leaves no trace anywhere.
--
-- DECISION (user, 2026-09-29): a SILENT marker. No alert, no incident, no
-- message. A resend by an anxious customer is common; alerting on each one
-- would be noise.
--
-- FIX: count the resend on the original hash row.
--   comprobantes_hashes.reenvios              how many resends were seen
--   comprobantes_hashes.ultimo_reenvio_at     when the last one arrived
--   comprobantes_hashes.ultimo_reenvio_wamid  its WhatsApp message id, so a
--                                             webhook replay of the same
--                                             resend is not counted twice
-- cerebro_marcar_reenvio_comprobante(hash, wamid) returns true when it counted
-- a NEW resend. It ignores an unknown hash, the original message itself and a
-- replay of the last counted resend. It writes nothing else.
--
-- ROLLBACK: ROLLBACK-146-duplicate-receipt-marker.sql
-- Guarded by supabase/staging/assertions/duplicate-receipt-marker.sql
-- =====================================================================

ALTER TABLE comprobantes_hashes
  ADD COLUMN IF NOT EXISTS reenvios integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ultimo_reenvio_at timestamptz,
  ADD COLUMN IF NOT EXISTS ultimo_reenvio_wamid text;

CREATE OR REPLACE FUNCTION cerebro_marcar_reenvio_comprobante(p_hash text, p_wamid text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n integer;
BEGIN
  IF p_hash IS NULL THEN RETURN false; END IF;

  UPDATE comprobantes_hashes
     SET reenvios = reenvios + 1,
         ultimo_reenvio_at = now(),
         ultimo_reenvio_wamid = p_wamid
   WHERE hash_imagen = p_hash
     AND (p_wamid IS NULL OR whatsapp_message_id IS DISTINCT FROM p_wamid)
     AND (p_wamid IS NULL OR ultimo_reenvio_wamid IS DISTINCT FROM p_wamid);
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN v_n > 0;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.cerebro_marcar_reenvio_comprobante(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_marcar_reenvio_comprobante(text, text) TO authenticated, service_role;
