-- ROLLBACK of 330: drops the six funding functions, the operation case link and the four tables.
-- Applying 330 writes no data by itself; dropping the tables discards any case created after the
-- migration (phase 2 is additive and is applied before the bot or panel writes to it).
-- =====================================================================

DROP FUNCTION IF EXISTS public.funding_case_cerrar(uuid, text, text);
DROP FUNCTION IF EXISTS public.funding_liberar(uuid, text, text, text);
DROP FUNCTION IF EXISTS public.funding_asignar(uuid, uuid, numeric, text, text, text);
DROP FUNCTION IF EXISTS public.funding_deposito_vincular(uuid, text, text);
DROP FUNCTION IF EXISTS public.funding_case_saldo(uuid);
DROP FUNCTION IF EXISTS public.funding_case_abrir(uuid, text);

DROP INDEX IF EXISTS public.remittance_operations_case_idx;
ALTER TABLE public.remittance_operations DROP COLUMN IF EXISTS case_id;

DROP TABLE IF EXISTS public.funding_movements;
DROP TABLE IF EXISTS public.funding_allocations;
DROP TABLE IF EXISTS public.case_deposits;
DROP TABLE IF EXISTS public.funding_case;
