-- =====================================================================
-- 155 — Closing a remesa clears the bot's partial-beneficiary accumulator
--
-- PROBLEM (production, 2026-09-30, Yilian Barbara Hernandez): a Zelle remesa
--   was completed from the panel at 13:16. At 13:22 the customer wrote
--   "Gracias" and at 13:23 the bot opened a NEW remesa (0 GYD, "Awaiting
--   deposit") with the same beneficiary. Cause: `cerebro_beneficiario_parcial`
--   (037), which gathers the recipient's data across messages until it is
--   complete, is never cleared when the remesa closes; and `Merge beneficiario`
--   stamps `actualizado = now()` on every turn, so its 24 h expiry never fires
--   in an active chat. On the next message the old data is "complete" again,
--   `Zelle completo?` / `Beneficiario completo?` pass, and
--   `cerebro_resolver_operacion_beneficiario` finds no open remesa and creates
--   one. 14 such remesas were cancelled by hand in the last 45 days; 3 were
--   open when this was written.
--
-- FIX: the accumulator belongs to the remesa in progress. When a remesa of the
--   conversation becomes completed or cancelled, its row is deleted. The next
--   message starts from nothing, exactly as for a new customer. A non-closing
--   status change keeps it (the data may still be arriving).
--
-- ROLLBACK: ROLLBACK-155-reset-beneficiario-parcial-al-cerrar.sql
-- Guarded by supabase/staging/assertions/beneficiario-parcial-reset.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION cerebro_reset_beneficiario_parcial_al_cerrar()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.conversation_id IS NOT NULL THEN
    DELETE FROM cerebro_beneficiario_parcial WHERE conversation_id = NEW.conversation_id;
  END IF;
  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION cerebro_reset_beneficiario_parcial_al_cerrar() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_reset_beneficiario_parcial_al_cerrar ON remittance_operations;
CREATE TRIGGER trg_reset_beneficiario_parcial_al_cerrar
  AFTER UPDATE OF status ON remittance_operations
  FOR EACH ROW
  WHEN (NEW.status IN ('completed', 'cancelled') AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION cerebro_reset_beneficiario_parcial_al_cerrar();
