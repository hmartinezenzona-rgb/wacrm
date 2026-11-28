-- =====================================================================
-- Cutover 2026-09-27 — STEP 3a (READ-ONLY): review the legacy open operations
-- before closing them. Run in the production SQL editor. Writes nothing.
--
-- Decision (user, 2026-09-26): start from zero; legacy open operations are
-- NOT carried into the new system. This lists what will be closed, and the
-- most recent ones separately: those may be live customers (Saturday is a
-- business day) and can be kept open by id in step 3b.
-- =====================================================================
BEGIN;
SET TRANSACTION READ ONLY;

-- 1. Totals by status and by what step 3b would do with them.
SELECT o.status,
       CASE WHEN o.status = 'ready_to_transfer' THEN 'completed' ELSE 'cancelled' END AS would_become,
       count(*) AS operations,
       round(sum(coalesce(o.quoted_source_amount, 0))) AS gyd,
       min(o.created_at)::date AS oldest,
       max(o.created_at)::date AS newest
  FROM remittance_operations o
 WHERE o.status NOT IN ('completed', 'cancelled')
 GROUP BY 1, 2
 ORDER BY 3 DESC;

-- 2. The ones touched in the last 48 hours: review with the team. Any id that is
--    a live customer goes into v_keep in step 3b.
SELECT o.id, o.status, o.created_at AT TIME ZONE 'America/Guyana' AS created_gy,
       o.updated_at AT TIME ZONE 'America/Guyana' AS updated_gy,
       o.quoted_source_amount AS gyd, ct.name AS client, d.status AS deal_status
  FROM remittance_operations o
  LEFT JOIN deals d ON d.id = o.deal_id
  LEFT JOIN conversations cv ON cv.id = o.conversation_id
  LEFT JOIN contacts ct ON ct.id = coalesce(o.contact_id, cv.contact_id)
 WHERE o.status NOT IN ('completed', 'cancelled')
   AND o.updated_at > now() - interval '48 hours'
 ORDER BY o.updated_at DESC;

ROLLBACK;
