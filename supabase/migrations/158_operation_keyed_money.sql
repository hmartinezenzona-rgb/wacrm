-- =====================================================================
-- 158 -- Money tables keyed by operation, so an operation without a deal
--         balances like one with a deal
--
-- PROBLEM
--   Two tables carry money and both are keyed by deal:
--     * depositos_mmg.deal_id          -- set when cerebro_cruzar_deposito(s)
--                                         consumes a bank deposit (144, 114)
--     * cerebro_objetivo_envio.deal_id -- set by cerebro_objetivo_atar
--   and three functions read them by deal:
--     cerebro_saldo_envio(p_deal), cerebro_objetivo_atar(p_conv, p_deal),
--     cerebro_objetivo_cerrar(p_deal).
--   deals is on its way out (eliminate-deals), and the writers that will
--   replace it create operations directly -- an operation with deal_id NULL.
--   For such an operation every one of those three functions is a no-op or
--   a NULL: there is no deal to look up. This unit makes the same answers
--   available by operation id, WITHOUT removing a single deal entry point.
--
-- WHAT
--   1. operation_id uuid on depositos_mmg and cerebro_objetivo_envio, FK
--      ON DELETE SET NULL, partial index on each.
--   2. Backfill: operation_id := the operation of the row's deal_id.
--   3. One BEFORE INSERT OR UPDATE OF deal_id trigger on both tables: a row
--      that names a deal also gets that deal's operation. The existing
--      writers keep writing deal_id only and are dual-written from here on.
--   4. cerebro_saldo_operacion / cerebro_objetivo_atar_op /
--      cerebro_objetivo_cerrar_op -- the operation-keyed twins.
--   5. The three deal functions delegate, keeping their signatures, return
--      types, volatility, SECURITY DEFINER and search_path.
--
-- WHY DEAL_ID IS SAFE AS A JOIN KEY HERE
--   remittance_operations has a PARTIAL UNIQUE index on deal_id
--   (remittance_operations_deal_uk, 040:78; 125 relies on it with
--   ON CONFLICT (deal_id) ... DO NOTHING). A deal maps to at most one
--   operation, so every scalar subquery below returns 0 or 1 rows and the
--   backfill cannot hit "more than one row returned by a subquery".
--
-- ROLLBACK
--   ROLLBACK-158-operation-keyed-money.sql restores the three deal
--   functions byte-for-byte from 109 and drops everything else.
--   Guarded by supabase/staging/assertions/operation-keyed-money.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The two columns and their indexes
-- ---------------------------------------------------------------------
--
-- IF NOT EXISTS plus the index IF NOT EXISTS make this re-runnable. ON
-- DELETE SET NULL: deleting an operation must not delete a bank deposit or
-- an objective -- it detaches them, exactly like the deal_id column (which
-- has no FK at all) already behaves.

ALTER TABLE public.depositos_mmg
  ADD COLUMN IF NOT EXISTS operation_id uuid
    REFERENCES public.remittance_operations(id) ON DELETE SET NULL;

ALTER TABLE public.cerebro_objetivo_envio
  ADD COLUMN IF NOT EXISTS operation_id uuid
    REFERENCES public.remittance_operations(id) ON DELETE SET NULL;

-- Partial, like idx_depositos_mmg_deal's siblings: the interesting rows
-- are the attached ones. An unfiltered index would carry every NULL.
CREATE INDEX IF NOT EXISTS idx_depositos_mmg_operation_id
  ON public.depositos_mmg (operation_id) WHERE operation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cerebro_objetivo_envio_operation_id
  ON public.cerebro_objetivo_envio (operation_id) WHERE operation_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 2. Backfill
-- ---------------------------------------------------------------------
--
-- Subquery per row, no set-based join: at most one operation per deal, so
-- this cannot fail, and it is the same expression the trigger below uses --
-- which is what makes "row had a deal before 158" and "row gets its
-- operation now" indistinguishable to every reader.

UPDATE public.depositos_mmg t
   SET operation_id = (SELECT ro.id
                         FROM public.remittance_operations ro
                        WHERE ro.deal_id = t.deal_id)
 WHERE t.deal_id IS NOT NULL
   AND t.operation_id IS NULL;

UPDATE public.cerebro_objetivo_envio t
   SET operation_id = (SELECT ro.id
                         FROM public.remittance_operations ro
                        WHERE ro.deal_id = t.deal_id)
 WHERE t.deal_id IS NOT NULL
   AND t.operation_id IS NULL;

-- ---------------------------------------------------------------------
-- 3. Dual-write trigger
-- ---------------------------------------------------------------------
--
-- BEFORE, so the row is never visible without its operation_id -- an AFTER
-- trigger would publish the intermediate state to any concurrent reader and
-- leave a window where cerebro_saldo_operacion misses a deposit that is
-- already linked to the operation.
--
-- UPDATE OF deal_id only: a row that never changes its deal does not need
-- to be re-linked, and the other columns (monto, consumido_en, anulado_en)
-- are written far more often than deal_id. NOT re-writing operation_id on
-- those updates is what keeps cerebro_cruzar_deposito's hot path free of a
-- subquery.
--
-- When the deal has no operation, operation_id is left as it is: an
-- objective that names a deal whose operation row has not been created yet
-- must not be forced to NULL, and the backfill above will pick it up.

CREATE OR REPLACE FUNCTION public.cerebro_atar_operation_por_deal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $$
BEGIN
  IF NEW.deal_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.deal_id IS DISTINCT FROM OLD.deal_id) THEN
    NEW.operation_id := (SELECT ro.id
                           FROM public.remittance_operations ro
                          WHERE ro.deal_id = NEW.deal_id);
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.cerebro_atar_operation_por_deal() IS
  '158. BEFORE INSERT OR UPDATE OF deal_id on depositos_mmg and '
  'cerebro_objetivo_envio: a row that names a deal also names that '
  'deal''s operation. Leaves operation_id untouched when the deal has no '
  'operation yet. One function for both tables (NEW.deal_id is the only '
  'column they share in this respect).';

REVOKE EXECUTE ON FUNCTION public.cerebro_atar_operation_por_deal() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_depositos_mmg_atar_operation ON public.depositos_mmg;
CREATE TRIGGER trg_depositos_mmg_atar_operation
  BEFORE INSERT OR UPDATE OF deal_id ON public.depositos_mmg
  FOR EACH ROW
  EXECUTE FUNCTION public.cerebro_atar_operation_por_deal();

DROP TRIGGER IF EXISTS trg_objetivo_envio_atar_operation ON public.cerebro_objetivo_envio;
CREATE TRIGGER trg_objetivo_envio_atar_operation
  BEFORE INSERT OR UPDATE OF deal_id ON public.cerebro_objetivo_envio
  FOR EACH ROW
  EXECUTE FUNCTION public.cerebro_atar_operation_por_deal();

-- ---------------------------------------------------------------------
-- 4. The operation-keyed twins
-- ---------------------------------------------------------------------
--
-- cerebro_saldo_operacion is cerebro_saldo_envio with the deals join
-- replaced by the operation's own conversation_id. Same dep filters
-- (consumido_en IS NOT NULL, anulado_en IS NULL), same one-row shape.
--
-- The obj predicate is NOT simply "operation_id = p_op": an objective that
-- has never been attached to anything (deal_id and operation_id both NULL)
-- still belongs to the conversation's current remesa, and that is how
-- cerebro_objetivo_atar_op finds it in the first place. Filtering on
-- operation_id alone would make the balance read 0 for every remesa that
-- has not been attached yet -- which is most of them, since attachment
-- happens at the first deposit.

CREATE OR REPLACE FUNCTION public.cerebro_saldo_operacion(p_op uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH dep AS (
    SELECT COALESCE(sum(m.monto), 0) AS total
      FROM depositos_mmg m
     WHERE m.operation_id = p_op
       AND m.consumido_en IS NOT NULL
       AND m.anulado_en  IS NULL
  ),
  obj AS (
    SELECT o.monto, o.moneda
      FROM cerebro_objetivo_envio o
     WHERE o.conversation_id = (SELECT ro.conversation_id
                                  FROM remittance_operations ro
                                 WHERE ro.id = p_op)
       AND o.cerrado_en IS NULL
       AND (o.operation_id IS NULL OR o.operation_id = p_op)
  )
  SELECT (SELECT monto FROM obj),
         (SELECT total FROM dep),
         (SELECT monto FROM obj) - (SELECT total FROM dep),
         COALESCE((SELECT moneda FROM obj), 'GYD');
$function$;

COMMENT ON FUNCTION public.cerebro_saldo_operacion(uuid) IS
  '158. cerebro_saldo_envio keyed by operation instead of by deal. Always '
  'returns exactly one row: (NULL, 0, NULL, ''GYD'') when the operation has '
  'no objective and no consumed deposits. The objective is read from the '
  'operation''s conversation and is accepted when it is unattached '
  '(operation_id IS NULL) or attached to this operation.';

-- cerebro_objetivo_atar_op: cerebro_objetivo_atar for an operation that may
-- have no deal at all. The WHERE clause is unchanged (open, unattached) so
-- it still grabs exactly the row the deal version grabbed; deal_id is set
-- to whatever the operation already has, which is NULL for a deal-less
-- operation and therefore stays NULL.
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_atar_op(p_conv uuid, p_op uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  UPDATE cerebro_objetivo_envio
     SET operation_id = p_op,
         deal_id      = (SELECT ro.deal_id
                           FROM remittance_operations ro
                          WHERE ro.id = p_op)
   WHERE conversation_id = p_conv
     AND cerrado_en IS NULL
     AND operation_id IS NULL
     AND deal_id IS NULL;
$function$;

COMMENT ON FUNCTION public.cerebro_objetivo_atar_op(uuid, uuid) IS
  '158. Attaches the conversation''s open, unattached objective to an '
  'operation. Works with no deal_id involved, which is the whole point: '
  'the operation may have been created without a deal.';

CREATE OR REPLACE FUNCTION public.cerebro_objetivo_cerrar_op(p_op uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  UPDATE cerebro_objetivo_envio
     SET cerrado_en = now()
   WHERE operation_id = p_op
     AND cerrado_en IS NULL;
$function$;

COMMENT ON FUNCTION public.cerebro_objetivo_cerrar_op(uuid) IS
  '158. Closes the objective attached to an operation. Deal callers use '
  'cerebro_objetivo_cerrar(deal), which now closes by either key.';

-- ---------------------------------------------------------------------
-- 5. The deal functions delegate
-- ---------------------------------------------------------------------
--
-- Every caller's SQL is unchanged; only the lookup key moves.

-- cerebro_saldo_envio -> cerebro_saldo_operacion.
--
-- The fallback branch is not decoration: an objective can be attached to a
-- deal BEFORE that deal's operation row exists (125 creates the operation
-- from an AFTER INSERT trigger on deals, and cerebro_objetivo_atar can be
-- called first). In that window the deal-only logic is the only one that
-- can see the objective, so it stays as the fallback, byte-for-byte from
-- 109.
--
-- Exactly one row, always: `nuevo` yields a row only when an operation
-- exists, `viejo` only when none does. (A naive "delegate, else fall back"
-- UNION ALL returns two rows in the case where an operation exists but the
-- fallback also matches -- that is why the guard lives on both branches.)
--
-- LANGUAGE stays sql: the branch is a CTE guard, not a control-flow
-- statement, so the deal twin keeps the exact language it had.
CREATE OR REPLACE FUNCTION public.cerebro_saldo_envio(p_deal uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH op AS (
    SELECT (SELECT ro.id
              FROM remittance_operations ro
             WHERE ro.deal_id = p_deal) AS id
  ),
  nuevo AS (
    SELECT s.objetivo, s.depositado, s.saldo, s.moneda
      FROM op
      CROSS JOIN LATERAL cerebro_saldo_operacion(op.id) s
     WHERE op.id IS NOT NULL
  ),
  dep AS (
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
  ),
  viejo AS (
    SELECT (SELECT monto FROM obj) AS objetivo,
           (SELECT total FROM dep) AS depositado,
           (SELECT monto FROM obj) - (SELECT total FROM dep) AS saldo,
           COALESCE((SELECT moneda FROM obj), 'GYD') AS moneda
     WHERE NOT EXISTS (SELECT 1 FROM op WHERE op.id IS NOT NULL)
  )
  SELECT nuevo.objetivo, nuevo.depositado, nuevo.saldo, nuevo.moneda
    FROM nuevo
  UNION ALL
  SELECT viejo.objetivo, viejo.depositado, viejo.saldo, viejo.moneda
    FROM viejo;
$function$;

-- cerebro_objetivo_atar -> cerebro_objetivo_atar_op, with the old statement
-- kept for a deal that has no operation yet.
--
-- LANGUAGE moves sql -> plpgsql here, and only here: the fallback is a real
-- control-flow branch (which of the two statements runs depends on whether
-- an operation exists), and PERFORM is the honest way to call a RETURNS
-- void function from plpgsql. Signature, RETURNS void, SECURITY DEFINER,
-- search_path and volatility are unchanged, so every existing caller and
-- every grant keeps working.
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_atar(p_conv uuid, p_deal uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
  v_op uuid;
BEGIN
  SELECT ro.id INTO v_op
    FROM remittance_operations ro
   WHERE ro.deal_id = p_deal;

  IF v_op IS NOT NULL THEN
    PERFORM cerebro_objetivo_atar_op(p_conv, v_op);
    RETURN;
  END IF;

  -- No operation for this deal yet: the 109 statement, unchanged.
  UPDATE cerebro_objetivo_envio
     SET deal_id = p_deal
   WHERE conversation_id = p_conv
     AND cerrado_en IS NULL
     AND deal_id IS NULL;
END;
$$;

-- cerebro_objetivo_cerrar: closes by either key, in ONE statement.
--
-- Both keys are set on every row the trigger has ever touched, so the two
-- halves of the OR usually name the same row -- a single UPDATE cannot
-- double-count it, which two sequential UPDATEs would still get right but
-- would pay for with a second pass and a second MVCC version.
CREATE OR REPLACE FUNCTION public.cerebro_objetivo_cerrar(p_deal uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
SET search_path TO public
AS $function$
  UPDATE cerebro_objetivo_envio
     SET cerrado_en = now()
   WHERE cerrado_en IS NULL
     AND (deal_id = p_deal
          OR operation_id = (SELECT ro.id
                               FROM remittance_operations ro
                              WHERE ro.deal_id = p_deal));
$function$;

-- ---------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------
--
-- The three twins carry exactly {postgres=X/postgres,service_role=X/postgres}
-- live (109:699-717 reproduces that ACL: REVOKE from PUBLIC/anon/authenticated,
-- GRANT to service_role). The three new functions get the identical ACL so a
-- caller cannot tell which family it is talking to -- and so the next
-- migration does not have to re-derive it. Explicit statements, not ALTER
-- DEFAULT PRIVILEGES: order-dependent, and 109:667-682 explains why that is
-- not something to rely on.

REVOKE EXECUTE ON FUNCTION
  cerebro_saldo_envio(uuid),
  cerebro_objetivo_atar(uuid, uuid),
  cerebro_objetivo_cerrar(uuid),
  cerebro_saldo_operacion(uuid),
  cerebro_objetivo_atar_op(uuid, uuid),
  cerebro_objetivo_cerrar_op(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  cerebro_saldo_envio(uuid),
  cerebro_objetivo_atar(uuid, uuid),
  cerebro_objetivo_cerrar(uuid),
  cerebro_saldo_operacion(uuid),
  cerebro_objetivo_atar_op(uuid, uuid),
  cerebro_objetivo_cerrar_op(uuid)
TO service_role;

NOTIFY pgrst, 'reload schema';
