-- =====================================================================
-- 304 -- Prioritize message.received when the outbox worker claims rows
--
-- With message.status_updated now durable too, a burst of delivery-status events (or a backlog after an n8n
-- outage) could fill every claim batch before the inbound messages behind it: the bot would answer late while
-- status updates drain. The claim now orders message.received first, then by due time. The lease, SKIP LOCKED
-- and limit behave as in 301.
-- Assertion: supabase/staging/assertions/outbox-prioridad.sql. Rollback: ROLLBACK-304-outbox-prioridad.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_webhook_outbox_reclamar(p_limit integer DEFAULT 20)
RETURNS SETOF public.webhook_outbox
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $function$
  UPDATE public.webhook_outbox o
     SET status = 'sending',
         locked_until = clock_timestamp() + interval '2 minutes'
   WHERE o.id IN (
           SELECT w.id
             FROM public.webhook_outbox w
            WHERE w.next_attempt_at <= clock_timestamp()
              AND (w.status = 'pending' OR (w.status = 'sending' AND w.locked_until < clock_timestamp()))
            ORDER BY (w.event = 'message.received') DESC, w.next_attempt_at
            LIMIT p_limit
              FOR UPDATE SKIP LOCKED)
  RETURNING o.*;
$function$;

COMMENT ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) IS
  'Claims due outbox rows (pending, or a sending row whose 2-minute lease expired), message.received first, and '
  'leases them to the worker.';

REVOKE ALL ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) TO service_role;
