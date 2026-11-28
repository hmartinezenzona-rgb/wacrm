-- ROLLBACK 310: removes the admin-aware registrar wrapper.

DROP FUNCTION IF EXISTS public.cerebro_registrar_deposito_si_cliente(uuid, numeric, text, uuid, text, text);
