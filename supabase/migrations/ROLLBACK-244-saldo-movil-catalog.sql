-- ROLLBACK of 244_saldo_movil_catalog.sql: removes the 'saldo' catalogue row and gives the keyword
-- back to `recargas`, restoring the pre-244 state of migration 138
-- (ARRAY['recarga','saldo','etecsa','cubacel']).
--
-- Safe to run: `cerebro_servicios` is a catalogue the bot reads, and nothing references it by
-- foreign key -- operations carry their service in `remittance_operations.service_type`, guarded by
-- a CHECK constraint that migration 223 taught about 'saldo' and that neither 244 nor this file
-- touches. So rolling back only makes saldo invisible to the BOT again; existing saldo operations
-- keep working and the admin panel is unaffected.
--
-- After this, consultar_servicio('saldo') returns nothing again and questions about saldo route
-- back to the Etecsa recharge service. No BEGIN/COMMIT.

DELETE FROM cerebro_servicios WHERE clave = 'saldo';

UPDATE cerebro_servicios
   SET palabras_clave = array_append(palabras_clave, 'saldo'),
       actualizado    = now()
 WHERE clave = 'recargas'
   AND NOT ('saldo' = ANY(palabras_clave));
