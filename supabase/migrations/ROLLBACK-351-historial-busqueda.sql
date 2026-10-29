-- Rollback of 351: the three new functions go; cerebro_dashboard_historial was never touched.
DROP FUNCTION IF EXISTS public.crm_historial_estados(date, date, text, text);
DROP FUNCTION IF EXISTS public.crm_historial_operaciones(date, date, text, text, text, integer, integer);
DROP FUNCTION IF EXISTS public.crm_historial_estado_grupo(text);
