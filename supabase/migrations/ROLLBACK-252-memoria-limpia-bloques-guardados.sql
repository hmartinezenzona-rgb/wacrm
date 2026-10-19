-- ROLLBACK of 252_memoria_limpia_bloques_guardados.sql: every row 252 cut gets its original message back from
-- respaldos.cerebro_memoria_bloques_20261019 (rows deleted since are not recreated), then the cleanup function is dropped.
-- The backup table is kept on purpose: drop it by hand once it is no longer needed.
-- Run 251's rollback too if new customer turns must be stored with the block again.

UPDATE public.cerebro_memoria m
   SET message = b.message
  FROM respaldos.cerebro_memoria_bloques_20261019 b
 WHERE b.id = m.id
   AND m.message IS DISTINCT FROM b.message;

DROP FUNCTION IF EXISTS public.cerebro_memoria_quitar_bloques_guardados();
