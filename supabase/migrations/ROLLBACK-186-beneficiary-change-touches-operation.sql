-- ROLLBACK of 186_beneficiary_change_touches_operation.sql: beneficiary changes stop touching the operation
-- (the panel again misses bot beneficiary writes until a reload).
DROP TRIGGER IF EXISTS trg_zzz_touch_operation ON public.remittance_beneficiaries;
DROP FUNCTION IF EXISTS public.remittance_beneficiaries_touch_operation();
