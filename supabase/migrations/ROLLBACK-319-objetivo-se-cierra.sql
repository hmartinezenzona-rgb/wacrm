-- ROLLBACK 319: the objective closes only from the cross again.
DROP TRIGGER IF EXISTS remittance_operations_cierra_objetivo ON public.remittance_operations;
DROP FUNCTION IF EXISTS public.remittance_operations_cierra_objetivo();
DROP FUNCTION IF EXISTS public.cerebro_objetivo_cerrar_si_cerrada(uuid);
