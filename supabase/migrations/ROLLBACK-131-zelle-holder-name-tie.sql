-- ROLLBACK for 131. Restore the 'Merge beneficiario' node FIRST (ROLLBACK-cerebro-*-antes-nombre-zelle.json),
-- because its new SQL reads the column and the function below.
-- The column is kept on purpose (nothing historical is deleted); only the function goes.
DROP FUNCTION IF EXISTS cerebro_nombre_completa(text, text);
NOTIFY pgrst, 'reload schema';
