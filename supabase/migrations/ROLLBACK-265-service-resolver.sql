-- Rollback of 265: the resolver is new and read-only, nothing else references it.
DROP FUNCTION IF EXISTS public.cerebro_resolver_servicio(uuid, text, text, numeric, timestamptz);
