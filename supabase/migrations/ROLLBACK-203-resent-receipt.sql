-- ROLLBACK of 203_resent_receipt.sql. Restore the Cerebro's 'Dedup comprobantes' and 'Snapshot final' (gate97 backup) first.
DROP FUNCTION IF EXISTS public.cerebro_comprobante_reenviado(text, text, numeric, text);
