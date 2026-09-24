-- =====================================================================
-- 119 — RPC: oldest in-flight remittance operations for /dashboard
--
-- WHY
--   The operations funnel (118) shows HOW MANY operations sit at each
--   non-terminal stage right now, but not WHICH ones, or how long
--   they've been stuck. This RPC answers that: the 20 oldest
--   non-terminal operations across all six stages, so the business
--   can act on whichever one has been sitting longest instead of
--   scrolling the full operations list looking for it.
--
-- WHY THE SAME SIX STAGES AS 118
--   Same process (migration 040's CHECK constraint), same exits
--   excluded: `completed`/`cancelled`/`incident` are not "stuck", they're
--   done. Listing the same six non-terminal stages keeps this queue and
--   the funnel above it describing the exact same population.
--
-- WHY A FUNCTION, WHY NO account_id FILTER
--   Same reasoning as 055/116/117/118: remittance_operations has RLS
--   with no policies for authenticated, and this subsystem has no
--   account-scoped access anywhere in it (confirmed again here, not
--   assumed).
--
-- WHY LEFT JOIN contacts, WHY NO PHONE FALLBACK
--   `remittance_operations.contact_id` is nullable, and not every
--   operation has one. A LEFT JOIN keeps a contact-less operation in
--   the result instead of dropping it. Unlike other dashboard widgets
--   that fall back to a contact's phone when its name is unset (e.g.
--   the activity feed), this RPC never selects `contacts.phone` — it
--   wasn't asked for and adding it would widen this function's
--   surface for a UI convenience the caller can add later if needed.
--   `contact_name` staying null is handled by the caller.
--
-- ROLLBACK
--   See ROLLBACK-119-dashboard-aged-operations-rpc.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION cerebro_dashboard_operaciones_envejecidas()
RETURNS TABLE (
  id                   uuid,
  conversation_id      uuid,
  contact_name         text,
  delivery_method      text,
  quoted_source_amount numeric,
  status               text,
  created_at           timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT o.id,
         o.conversation_id,
         c.name,
         o.delivery_method,
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
