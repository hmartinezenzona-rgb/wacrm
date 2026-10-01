-- ROLLBACK for 168: stops the job and drops the function. Audit rows already written stay; the
-- constraint keeps the new action so they remain valid.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'recruzar-depositos-tardios';
DROP FUNCTION IF EXISTS public.cerebro_recruzar_depositos_tardios();
