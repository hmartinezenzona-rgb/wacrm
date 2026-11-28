-- ROLLBACK of 370_planned_split_panel_read.sql: the panel can no longer read the planned split.
DROP FUNCTION IF EXISTS public.crm_reparto_planeado_de_conversacion(uuid);
