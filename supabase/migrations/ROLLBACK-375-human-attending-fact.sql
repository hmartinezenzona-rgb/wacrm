-- Rollback of 375: drops the read-only fact. Remove the notifier's `humano_atendiendo` reader (node "Leer secreto") first.
DROP FUNCTION IF EXISTS public.cerebro_humano_atendiendo(uuid);
