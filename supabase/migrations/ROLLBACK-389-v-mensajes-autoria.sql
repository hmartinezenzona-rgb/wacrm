-- ROLLBACK-389-v-mensajes-autoria.sql
-- Removes the read-only authorship view.

DROP VIEW IF EXISTS public.v_mensajes_autoria;
