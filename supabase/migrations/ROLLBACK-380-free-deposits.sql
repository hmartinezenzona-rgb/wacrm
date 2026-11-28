-- Rollback of 380: drops the read function. Remove the panel's route and picker first.
DROP FUNCTION IF EXISTS public.crm_depositos_sin_dueno(uuid);
