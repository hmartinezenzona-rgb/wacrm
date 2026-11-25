-- ============================================================
-- 337 — Marca pública del negocio (sin sesión).
--
-- El ícono de la pestaña, la app instalada (manifest) y los avisos se
-- piden antes de iniciar sesión. Esta función entrega SOLO lo que se ve
-- por fuera (nombre, tema e ícono) de la configuración del negocio de esta
-- base (una base por cliente; si hubiera varias cuentas, la más antigua).
-- Así no hace falta la llave de servidor para eso.
-- ============================================================

CREATE OR REPLACE FUNCTION public.marca_publica()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT COALESCE((
    SELECT jsonb_strip_nulls(jsonb_build_object(
             'nombre', n.data->'nombre',
             'tema',   n.data->'tema',
             'icono',  n.data->'icono'))
      FROM negocio_config n
      JOIN accounts a ON a.id = n.account_id
     ORDER BY a.created_at
     LIMIT 1
  ), '{}'::jsonb);
$$;
REVOKE ALL ON FUNCTION public.marca_publica() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marca_publica() TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
