-- ROLLBACK 320: the operation no longer manages the agreed amount.
DROP TRIGGER IF EXISTS remittance_operations_objetivo_desde_op ON public.remittance_operations;
DROP FUNCTION IF EXISTS public.remittance_operations_objetivo_desde_op();
