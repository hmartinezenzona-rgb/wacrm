-- ROLLBACK of 127. Beneficiaries already written by a reparto are real data and stay.
DROP FUNCTION IF EXISTS cerebro_aplicar_reparto(uuid, jsonb);
-- The 'automation_reparto_registered' value stays in remittance_admin_audit_action_chk while
-- audit rows use it; drop it from the CHECK only after those rows are archived.
NOTIFY pgrst, 'reload schema';
