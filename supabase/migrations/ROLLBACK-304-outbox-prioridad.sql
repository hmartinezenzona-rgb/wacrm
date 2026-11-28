-- ROLLBACK 304: restores the claim without the message.received priority (301 body).

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
            ORDER BY w.next_attempt_at
            LIMIT p_limit
              FOR UPDATE SKIP LOCKED)
  RETURNING o.*;
$function$;

COMMENT ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) IS
  'Claims due outbox rows (pending, or a sending row whose 2-minute lease expired) and leases them to the worker.';

REVOKE ALL ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) TO service_role;
