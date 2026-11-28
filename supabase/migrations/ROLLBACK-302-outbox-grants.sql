-- ROLLBACK 302: removes the service_role grants on the durable-delivery outbox.

REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLE public.webhook_outbox FROM service_role;
REVOKE EXECUTE ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) FROM service_role;
REVOKE EXECUTE ON FUNCTION public.cerebro_webhook_outbox_ping() FROM service_role;
