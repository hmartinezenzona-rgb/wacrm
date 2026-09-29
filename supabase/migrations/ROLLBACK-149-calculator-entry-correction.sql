-- =====================================================================
-- ROLLBACK 149 — remove the admin calculator-entry correction RPC and
-- restore 104's original append-only guard (no correction hole).
--
-- The 'human_calculator_correction' value stays in
-- remittance_admin_audit_action_chk while any audit row already uses it
-- (same policy 127's rollback follows for its own new action value) —
-- drop it from the CHECK only after those rows are archived. Any
-- facturado_gyd/invertido_gyd/retorno_gyd values already corrected by
-- this function are real data and stay untouched.
-- =====================================================================

DROP FUNCTION IF EXISTS crm_corregir_entrada_calculadora(uuid, numeric, numeric);

CREATE OR REPLACE FUNCTION remittance_calculator_entries_lock_completed()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'completed' THEN
      RAISE EXCEPTION 'remittance_calculator_entries: completed rows are append-only'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.status = 'completed' THEN
    IF NEW.status <> 'void' THEN
      RAISE EXCEPTION 'remittance_calculator_entries: completed rows are append-only'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NEW.amount        IS DISTINCT FROM OLD.amount
       OR NEW.service       IS DISTINCT FROM OLD.service
       OR NEW.operation_id  IS DISTINCT FROM OLD.operation_id
       OR NEW.facturado_gyd IS DISTINCT FROM OLD.facturado_gyd
       OR NEW.invertido_gyd IS DISTINCT FROM OLD.invertido_gyd
       OR NEW.retorno_gyd   IS DISTINCT FROM OLD.retorno_gyd
       OR NEW.rate_version_id IS DISTINCT FROM OLD.rate_version_id
    THEN
      RAISE EXCEPTION 'remittance_calculator_entries: voiding must not alter the recorded figures'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';
