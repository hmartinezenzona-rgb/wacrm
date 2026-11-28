-- Rollback of 265 (service resolver v2): the table, its trigger and the two functions are new, nothing else references them
-- before 266-268 are applied. Dependency order: trigger, then its function, then the functions, then the table.
DROP TRIGGER IF EXISTS trg_remittance_operations_limpia_servicio_declarado ON public.remittance_operations;
DROP FUNCTION IF EXISTS public.cerebro_limpiar_servicio_declarado();
DROP FUNCTION IF EXISTS public.cerebro_resolver_servicio(uuid, text, text, numeric, timestamptz);
DROP FUNCTION IF EXISTS public.cerebro_declarar_servicio(uuid, text, text);
DROP TABLE IF EXISTS public.cerebro_servicio_declarado;
