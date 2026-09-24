-- =====================================================================
-- 120 — Add destination_currency to the aged-operations RPC (119)
--
-- WHY
--   119's `delivery_method` is structurally almost never set on a
--   non-terminal operation in this business's real flow — confirmed
--   against live data: 0 of 4 in-flight operations had it, vs 8 of 11
--   completed ones. `calculator_feed_operation()` (migration 104) only
--   ever creates a ledger row once an operation is `completed` AND
--   `delivery_method` resolves to a known service, which is exactly why
--   it always has one there but not here.
--
--   `destination_currency`, however, IS already known well before that:
--   the same live-data check showed all 4 in-flight operations already
--   had it set (3x CUP, 1x USD), while delivery_method was null on all
--   four. It's a coarser signal than delivery_method (CUP/USD doesn't
--   distinguish zelle/clasica/tropical within USD), but it's real,
--   already-known information the queue was previously showing as a
--   blank dash for no reason.
--
-- WHY DROP THEN CREATE, NOT CREATE OR REPLACE
--   Postgres refuses `CREATE OR REPLACE FUNCTION` when a `RETURNS TABLE`
--   function's row type changes (42P13: "cannot change return type of
--   existing function... Row type defined by OUT parameters is
--   different"), even to only ADD a column. Confirmed against the live
--   database. The function is pure `SELECT`, `SECURITY DEFINER`, no
--   state of its own — dropping and recreating it loses nothing, only
--   the brief window where the RPC doesn't exist.
--
-- ROLLBACK
--   Re-run 119's DROP + its original CREATE FUNCTION body (same DROP-
--   then-CREATE requirement applies) — see ROLLBACK-119, which fully
--   drops it if a clean removal is preferred instead.
-- =====================================================================

DROP FUNCTION IF EXISTS cerebro_dashboard_operaciones_envejecidas();

CREATE FUNCTION cerebro_dashboard_operaciones_envejecidas()
RETURNS TABLE (
  id                   uuid,
  conversation_id      uuid,
  contact_name         text,
  delivery_method      text,
  destination_currency text,
  quoted_source_amount numeric,
  status               text,
  created_at           timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT o.id,
         o.conversation_id,
         c.name,
         o.delivery_method,
         o.destination_currency,
         o.quoted_source_amount,
         o.status,
         o.created_at
    FROM remittance_operations o
    LEFT JOIN contacts c ON c.id = o.contact_id
   WHERE o.status IN (
     'collecting_information',
     'awaiting_deposit',
     'deposit_received',
     'deposit_verification',
     'ready_to_transfer',
     'transferring'
   )
   ORDER BY o.created_at ASC
   LIMIT 20;
$$;

GRANT EXECUTE ON FUNCTION cerebro_dashboard_operaciones_envejecidas() TO authenticated;


-- =====================================================================
-- QUIEN LA USA
--   `src/app/(dashboard)/dashboard/page.tsx`, via
--   `src/lib/dashboard/queries.ts`'s `loadAgedOperations`, rendered by
--   `src/components/dashboard/aged-operations-queue.tsx`.
-- =====================================================================
