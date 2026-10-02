-- =====================================================================
-- 186 — a beneficiary change touches its operation, so the panel's Realtime fires (staging first)
--
-- odd/tasks/panel-realtime-beneficiaries.md. The operations panel listens to remittance_operations
-- (3b5f5dc, eliminate-deals WU8; publication 181). A bot beneficiary write (a phone added to a saved
-- card, a reparto slot, a partial beneficiary) never UPDATEs the operation row: the writers only
-- touch remittance_beneficiaries, and the recalc triggers update the operation only when the
-- delivery method or the computed amount change. So the panel showed the new data only after a
-- reload. Before WU8 the panel listened to deals, whose notes every such write changed.
--
-- This row trigger touches the parent operation (updated_at) on every beneficiary INSERT, UPDATE or
-- DELETE. On an updated_at-only UPDATE the operation's own triggers stay inert: the status, recalc,
-- calculator-feed and destino triggers are `UPDATE OF <column>`, and the admin lock guard acts only
-- on changed fields. cerebro_op_touch bumps `version`, as on any other write. A failure here never
-- blocks the beneficiary write.
--
-- Guarded by supabase/staging/assertions/beneficiary-touches-operation.sql.
-- ROLLBACK: ROLLBACK-186-beneficiary-change-touches-operation.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.remittance_beneficiaries_touch_operation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new uuid := CASE WHEN TG_OP <> 'DELETE' THEN NEW.operation_id END;
  v_old uuid := CASE WHEN TG_OP <> 'INSERT' THEN OLD.operation_id END;
BEGIN
  UPDATE remittance_operations SET updated_at = now()
   WHERE id IN (v_new, v_old);
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[wacrm] remittance_beneficiaries_touch_operation failed for operation %: %', coalesce(v_new, v_old), SQLERRM;
  RETURN NULL;
END $$;

REVOKE ALL ON FUNCTION public.remittance_beneficiaries_touch_operation() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_zzz_touch_operation ON public.remittance_beneficiaries;
CREATE TRIGGER trg_zzz_touch_operation
  AFTER INSERT OR UPDATE OR DELETE ON public.remittance_beneficiaries
  FOR EACH ROW EXECUTE FUNCTION public.remittance_beneficiaries_touch_operation();
