-- ROLLBACK 155 — stop clearing the partial-beneficiary accumulator on close.
DROP TRIGGER IF EXISTS trg_reset_beneficiario_parcial_al_cerrar ON remittance_operations;
DROP FUNCTION IF EXISTS cerebro_reset_beneficiario_parcial_al_cerrar();
