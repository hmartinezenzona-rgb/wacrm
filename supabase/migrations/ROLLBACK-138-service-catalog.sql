-- ROLLBACK for 138: drop the catalog function and the two new columns.
-- No prior state to restore for palabras_clave/resumen: they did not exist
-- before this migration (verified: no migration before 138 ever adds them).

REVOKE EXECUTE ON FUNCTION cerebro_catalogo_servicios() FROM service_role;
DROP FUNCTION IF EXISTS cerebro_catalogo_servicios();

ALTER TABLE cerebro_servicios
  DROP COLUMN IF EXISTS palabras_clave,
  DROP COLUMN IF EXISTS resumen;
