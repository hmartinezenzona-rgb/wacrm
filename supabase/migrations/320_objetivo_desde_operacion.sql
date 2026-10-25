-- =====================================================================
-- 320 -- A new shipment never inherits a stale agreed amount
--
-- 319 closes the objective when a shipment ends. This covers the remaining
-- hole: a declared amount that never became a shipment (the client said "voy a
-- mandar 100" and never deposited) stays open by design, and a later shipment
-- announced without a fresh declaration would be compared against that old
-- number — exactly what happened to Miguel (1727ef31): the 22-oct objective
-- (77 USD / 20.020 GYD) was applied to a 26.000 GYD deposit.
--
-- Two moves, both on the operation:
--   1. On INSERT, close the conversation's leftover objective: an open row
--      that is unattached and older than 12 hours, or attached to an operation
--      that already ended. A declaration made for this very shipment (fresh,
--      under 12 hours) is left alone — it IS the agreed amount.
--   2. When the operation's quoted amount arrives (INSERT with it, or a later
--      UPDATE) and no objective is open, set the objective from the operation
--      itself, so the partial-deposit check keeps working. Skipped when the
--      operation already has a consumed deposit: the cross ran without an
--      objective and creating one now would only leave a residue.
--
-- Status endings keep closing it through 319.
--
-- Assertion: supabase/staging/assertions/objetivo-desde-operacion.sql.
-- Rollback: ROLLBACK-320-objetivo-desde-operacion.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.remittance_operations_objetivo_desde_op()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  -- 1. On a brand-new operation, retire leftover objectives of the conversation.
  IF TG_OP = 'INSERT' THEN
    UPDATE cerebro_objetivo_envio o
       SET cerrado_en = now()
     WHERE o.conversation_id = NEW.conversation_id
       AND o.cerrado_en IS NULL
       AND (
            (o.operation_id IS NULL AND o.fijado_en < now() - interval '12 hours')
         OR EXISTS (SELECT 1 FROM remittance_operations r
                     WHERE r.id = o.operation_id
                       AND r.status IN ('completed', 'cancelled'))
       );
  END IF;

  -- 2. The operation supplies the objective when none is open.
  IF NEW.status NOT IN ('completed', 'cancelled')
     AND NEW.quoted_source_amount IS NOT NULL
     AND NEW.quoted_source_amount > 0
     AND NOT EXISTS (SELECT 1 FROM cerebro_objetivo_envio o
                      WHERE o.conversation_id = NEW.conversation_id
                        AND o.cerrado_en IS NULL)
     AND NOT EXISTS (SELECT 1 FROM depositos_mmg d
                      WHERE d.operation_id = NEW.id
                        AND d.consumido_en IS NOT NULL)
  THEN
    INSERT INTO cerebro_objetivo_envio AS o (conversation_id, monto, moneda, pedido, operation_id)
    VALUES (NEW.conversation_id, NEW.quoted_source_amount, 'GYD', 'segun la operacion', NEW.id)
    ON CONFLICT (conversation_id) DO UPDATE
       SET monto        = EXCLUDED.monto,
           moneda       = 'GYD',
           pedido       = EXCLUDED.pedido,
           operation_id = EXCLUDED.operation_id,
           fijado_en    = now(),
           cerrado_en   = NULL
     WHERE o.cerrado_en IS NOT NULL;
  END IF;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.remittance_operations_objetivo_desde_op() IS
  '320: retires leftover agreed amounts when a shipment starts and seeds the objective from the operation own amount.';

DROP TRIGGER IF EXISTS remittance_operations_objetivo_desde_op ON public.remittance_operations;
CREATE TRIGGER remittance_operations_objetivo_desde_op
  AFTER INSERT OR UPDATE OF quoted_source_amount ON public.remittance_operations
  FOR EACH ROW
  EXECUTE FUNCTION public.remittance_operations_objetivo_desde_op();

REVOKE ALL ON FUNCTION public.remittance_operations_objetivo_desde_op() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.remittance_operations_objetivo_desde_op() TO service_role;
