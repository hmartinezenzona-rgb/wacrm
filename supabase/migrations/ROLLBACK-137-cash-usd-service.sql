-- ROLLBACK for 137: delete the efectivo_usd row. It is a brand-new clave
-- (verified: no migration before 137 ever inserts it), so a plain DELETE
-- is exact -- there is no prior row state to restore.

DELETE FROM cerebro_servicios WHERE clave = 'efectivo_usd';
