-- ROLLBACK 314: removes the Hermes read-only query functions.

DROP FUNCTION IF EXISTS public.hermes_buscar_conversacion(text);
DROP FUNCTION IF EXISTS public.hermes_leer_mensajes(text, integer, timestamptz);
DROP FUNCTION IF EXISTS public.hermes_listar_operaciones(text, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.hermes_ver_calculadora(date, date);
DROP FUNCTION IF EXISTS public.hermes_alertas(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.hermes_tasas();
