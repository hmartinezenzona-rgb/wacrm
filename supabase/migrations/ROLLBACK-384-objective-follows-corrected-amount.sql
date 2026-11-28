-- =====================================================================
-- ROLLBACK for 384 -- restores the 320 body of
-- public.remittance_operations_objetivo_desde_op() exactly (the third
-- branch goes away), with its COMMENT and its ACL.
--
-- The staging rollback test compares md5(pg_get_functiondef(...)) before and
-- after, so the body below is the 320 text verbatim. The trigger is not
-- touched: 384 did not recreate it.
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

REVOKE ALL ON FUNCTION public.remittance_operations_objetivo_desde_op() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.remittance_operations_objetivo_desde_op() TO service_role;
