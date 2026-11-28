-- =====================================================================
-- 384 -- The deposit objective follows a corrected amount
--
-- 320 syncs the objective from the operation only when the conversation has
-- no open objective. When the open objective already belongs to the same
-- operation, a correction of the operation's quoted source amount left the
-- objective behind, and the panel showed a card that contradicted itself.
--
-- Observed on staging (2026-11-17): operation 83988f69-3b25-4afe-ae0e-035a5f557c0c
-- was corrected from 24400 to 29000 (audit action human_correction, 19:34:30)
-- while cerebro_objetivo_envio.monto stayed at 24400. The card header read
-- 29,000 GYD and the same card still reported 24,400 GYD missing.
--
-- This redefines public.remittance_operations_objetivo_desde_op(). Branches 1
-- and 2 are the 320 body unchanged. A third branch then lets an open objective
-- that belongs to this very operation follow a corrected amount: the panel
-- asks the customer for the objective, so a correction that leaves it behind
-- makes the card contradict itself. A conversation-level objective
-- (operation_id NULL), another operation's objective, a closed operation and
-- an operation with a consumed deposit stay untouched.
--
-- The trigger is NOT recreated: the 320 trigger already fires AFTER INSERT OR
-- UPDATE OF quoted_source_amount, which is exactly the path the new branch
-- needs.
--
-- Assertion: supabase/staging/assertions/objective-follows-corrected-amount.sql.
-- Rollback: ROLLBACK-384-objective-follows-corrected-amount.sql.
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

  -- 3. (384) An open objective that belongs to this same operation follows a corrected amount: the panel
  -- asks the customer for the objective, so a correction that leaves it behind makes the card contradict
  -- itself. A conversation-level objective (operation_id NULL), another operation's objective, a closed
  -- operation and an operation with a consumed deposit are left untouched.
  IF TG_OP = 'UPDATE'
     AND NEW.status NOT IN ('completed', 'cancelled')
     AND NEW.quoted_source_amount IS NOT NULL
     AND NEW.quoted_source_amount > 0
     AND NEW.quoted_source_amount IS DISTINCT FROM OLD.quoted_source_amount
     AND NOT EXISTS (SELECT 1 FROM depositos_mmg d
                      WHERE d.operation_id = NEW.id
                        AND d.consumido_en IS NOT NULL)
  THEN
    UPDATE cerebro_objetivo_envio o
       SET monto = NEW.quoted_source_amount
     WHERE o.conversation_id = NEW.conversation_id
       AND o.operation_id = NEW.id
       AND o.cerrado_en IS NULL
       AND o.monto IS DISTINCT FROM NEW.quoted_source_amount;
  END IF;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.remittance_operations_objetivo_desde_op() IS
  '384: retires leftover agreed amounts when a shipment starts, seeds the objective from the operation own amount, and lets an open objective that belongs to the operation follow a corrected amount.';

REVOKE ALL ON FUNCTION public.remittance_operations_objetivo_desde_op() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.remittance_operations_objetivo_desde_op() TO service_role;
