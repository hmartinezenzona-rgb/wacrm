-- ROLLBACK 158 -- money tables keyed by deal again.
-- Drops the two operation_id columns (and their indexes), the dual-write
-- triggers and their function, and the three operation-keyed functions;
-- restores cerebro_saldo_envio, cerebro_objetivo_atar and
-- cerebro_objetivo_cerrar to their 109 bodies VERBATIM.
--
-- No money row is deleted: depositos_mmg and cerebro_objetivo_envio keep
-- every row and every deal_id they had. Only the operation_id mirror this
-- migration added goes away.
--
-- Order matters in one place: the operation-keyed functions reference
-- operation_id in their bodies, so they are dropped (and the deal functions
-- restored) BEFORE the columns disappear. Postgres does not track column
-- references inside SQL function bodies, so a column dropped while a live
-- function still names it would fail at the next call, not at the DROP.

-- 1) The three operation-keyed functions
DROP FUNCTION IF EXISTS public.cerebro_saldo_operacion(uuid);
DROP FUNCTION IF EXISTS public.cerebro_objetivo_atar_op(uuid, uuid);
DROP FUNCTION IF EXISTS public.cerebro_objetivo_cerrar_op(uuid);

-- 2) The triggers, then the function they call
DROP TRIGGER IF EXISTS trg_depositos_mmg_atar_operation ON public.depositos_mmg;
DROP TRIGGER IF EXISTS trg_objetivo_envio_atar_operation ON public.cerebro_objetivo_envio;
DROP FUNCTION IF EXISTS public.cerebro_atar_operation_por_deal();

-- 3) The three deal functions exactly as in 109

-- cerebro_saldo_envio exactly as in 109
CREATE OR REPLACE FUNCTION public.cerebro_saldo_envio(p_deal uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH dep AS (
    SELECT COALESCE(sum(m.monto), 0) AS total
      FROM depositos_mmg m
     WHERE m.deal_id = p_deal
       AND m.consumido_en IS NOT NULL
       AND m.anulado_en  IS NULL
  ),
  obj AS (
    SELECT o.monto, o.moneda
      FROM cerebro_objetivo_envio o
      JOIN deals d ON d.conversation_id = o.conversation_id
     WHERE d.id = p_deal
       AND o.cerrado_en IS NULL
       AND (o.deal_id IS NULL OR o.deal_id = p_deal)
  )
  SELECT (SELECT monto FROM obj),
         (SELECT total FROM dep),
         (SELECT monto FROM obj) - (SELECT total FROM dep),
         COALESCE((SELECT moneda FROM obj), 'GYD');
$function$;

-- cerebro_objetivo_atar exactly as in 109
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_atar(p_conv uuid, p_deal uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  UPDATE cerebro_objetivo_envio
     SET deal_id = p_deal
   WHERE conversation_id = p_conv AND cerrado_en IS NULL AND deal_id IS NULL;
$function$;

-- cerebro_objetivo_cerrar exactly as in 109
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_cerrar(p_deal uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  UPDATE cerebro_objetivo_envio
     SET cerrado_en = now()
   WHERE deal_id = p_deal AND cerrado_en IS NULL;
$function$;

-- 4) The indexes, then the columns
DROP INDEX IF EXISTS public.idx_depositos_mmg_operation_id;
DROP INDEX IF EXISTS public.idx_cerebro_objetivo_envio_operation_id;

ALTER TABLE public.depositos_mmg DROP COLUMN IF EXISTS operation_id;
ALTER TABLE public.cerebro_objetivo_envio DROP COLUMN IF EXISTS operation_id;

-- 5) The grants 158 applied to the three restored functions
REVOKE EXECUTE ON FUNCTION
  cerebro_saldo_envio(uuid),
  cerebro_objetivo_atar(uuid, uuid),
  cerebro_objetivo_cerrar(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  cerebro_saldo_envio(uuid),
  cerebro_objetivo_atar(uuid, uuid),
  cerebro_objetivo_cerrar(uuid)
TO service_role;

NOTIFY pgrst, 'reload schema';
