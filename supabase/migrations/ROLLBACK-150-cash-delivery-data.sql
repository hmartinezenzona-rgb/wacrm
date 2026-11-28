-- =====================================================================
-- ROLLBACK 150 — remove the cash-delivery data RPC and the new
-- efectivo_usd beneficiary_type/columns.
--
-- The 'automation_cash_delivery_data_registered' value stays in
-- remittance_admin_audit_action_chk while any audit row already uses it
-- (same policy 127's and 149's own rollbacks follow) — drop it from the
-- CHECK only after those rows are archived. Any address/id_photo_wamid/
-- efectivo_usd beneficiary rows already written are real data and stay
-- untouched; this only removes the write path and the schema that made
-- it possible, matching every other ROLLBACK in this repo.
-- =====================================================================

DROP FUNCTION IF EXISTS crm_registrar_datos_entrega_efectivo(uuid, text, text, text);

ALTER TABLE remittance_beneficiaries DROP CONSTRAINT IF EXISTS rb_type_chk;
ALTER TABLE remittance_beneficiaries
  ADD CONSTRAINT rb_type_chk CHECK (beneficiary_type IN
    ('cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution'));

-- address/id_photo_wamid columns are intentionally NOT dropped here: a
-- DROP COLUMN would destroy any real efectivo_usd delivery data already
-- captured while this migration was live, and this repo's convention
-- (see 042's own header) is to preserve history rather than lose it.
-- Re-running 150 after this rollback is safe (idempotent ADD COLUMN IF
-- NOT EXISTS / CHECK replace).

NOTIFY pgrst, 'reload schema';
