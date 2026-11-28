-- ROLLBACK for 132: stops correcting names from bot confirmations. Names already corrected stay
-- (nothing historical is deleted).
DROP TRIGGER IF EXISTS trg_zz_nombre_confirmado_zelle ON messages;
DROP FUNCTION IF EXISTS trg_nombre_confirmado_zelle();
DROP FUNCTION IF EXISTS cerebro_aplicar_nombre_confirmado(uuid, text);
NOTIFY pgrst, 'reload schema';
