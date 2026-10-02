-- ROLLBACK for 185_recarga_minimum_range.sql
DELETE FROM cerebro_config WHERE clave = 'minimo_gyd_recarga_hasta';
