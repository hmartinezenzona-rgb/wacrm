-- Rollback for 245_saldo_catalog_produccion.sql
--
-- Removes the saldo movil catalogue row. After this, consultar_servicio('saldo') returns nothing
-- again, so the bot can no longer describe or quote saldo movil — which is the state production was
-- in before 245. The restructured prompt still routes the word 'saldo' to that tool, so with the
-- row gone the bot should say it cannot confirm the price rather than invent one; if you are rolling
-- back because the prompt is misbehaving, roll the prompt back too (see the PUNTO-DE-ROLLBACK
-- workflow copy in ~/cerebro-fase1/).
--
-- 245 touched nothing else: no schema, no other row, no function. There is nothing else to undo.

DELETE FROM cerebro_servicios WHERE clave = 'saldo';
