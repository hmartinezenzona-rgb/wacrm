-- =====================================================================
-- ROLLBACK 146 — remove the silent duplicate-receipt marker
--
-- Drops the function and the three counter columns. The counts are lost;
-- nothing else reads them. Receipt de-duplication itself is unchanged.
-- =====================================================================

DROP FUNCTION IF EXISTS public.cerebro_marcar_reenvio_comprobante(text, text);

ALTER TABLE comprobantes_hashes
  DROP COLUMN IF EXISTS reenvios,
  DROP COLUMN IF EXISTS ultimo_reenvio_at,
  DROP COLUMN IF EXISTS ultimo_reenvio_wamid;
