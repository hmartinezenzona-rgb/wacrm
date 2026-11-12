-- ============================================================
-- 300 — Menú de Doña Miriam (edición dona-miriam, NO aplicar en Remesas Ya)
--
-- El menú vive aquí y es la única fuente: la página web, el bot de
-- WhatsApp y la pantalla «Menú» del CRM leen lo mismo. Si Miriam apaga
-- un plato, desaparece de todos lados.
--
--   menu_config  una fila por cuenta: precio de la charola, anticipo,
--                cupo diario, días de entrega y avisos.
--   menu_items   cada opción: grupo (arroz/carne/vianda/potaje/extra),
--                nombre, precio (solo extras), disponible, y en qué días
--                de la semana se ofrece (NULL = todos).
--
-- menu_publico(cuenta) — lectura pública (anon) de lo disponible, para
-- la página web. Solo devuelve lo que Miriam dejó prendido.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.menu_config (
  account_id     UUID PRIMARY KEY REFERENCES public.accounts(id) ON DELETE CASCADE,
  precio_charola NUMERIC(10,2) NOT NULL DEFAULT 150,
  anticipo       NUMERIC(10,2) NOT NULL DEFAULT 75,
  cupo_diario    INTEGER NOT NULL DEFAULT 10 CHECK (cupo_diario >= 0),
  dias_entrega   INTEGER[] NOT NULL DEFAULT '{1,2,3,4,5,6}',
  dias_antes     INTEGER NOT NULL DEFAULT 1 CHECK (dias_antes >= 0),
  fechas_cerradas DATE[] NOT NULL DEFAULT '{}',
  aviso          TEXT,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.menu_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  grupo       TEXT NOT NULL CHECK (grupo IN ('arroz','carne','vianda','potaje','extra')),
  nombre      TEXT NOT NULL CHECK (length(trim(nombre)) > 0),
  precio      NUMERIC(10,2),
  disponible  BOOLEAN NOT NULL DEFAULT true,
  dias        INTEGER[],
  orden       INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, grupo, nombre)
);
CREATE INDEX IF NOT EXISTS idx_menu_items_account ON public.menu_items(account_id, grupo, orden);

ALTER TABLE public.menu_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_items  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS menu_config_select ON public.menu_config;
DROP POLICY IF EXISTS menu_config_write  ON public.menu_config;
CREATE POLICY menu_config_select ON public.menu_config FOR SELECT USING (is_account_member(account_id));
CREATE POLICY menu_config_write  ON public.menu_config FOR ALL
  USING (is_account_member(account_id, 'agent')) WITH CHECK (is_account_member(account_id, 'agent'));

DROP POLICY IF EXISTS menu_items_select ON public.menu_items;
DROP POLICY IF EXISTS menu_items_write  ON public.menu_items;
CREATE POLICY menu_items_select ON public.menu_items FOR SELECT USING (is_account_member(account_id));
CREATE POLICY menu_items_write  ON public.menu_items FOR ALL
  USING (is_account_member(account_id, 'agent')) WITH CHECK (is_account_member(account_id, 'agent'));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.menu_config, public.menu_items TO authenticated;
REVOKE ALL ON public.menu_config, public.menu_items FROM anon;

-- Lectura pública para la página web: solo lo prendido, sin datos internos.
CREATE OR REPLACE FUNCTION public.menu_publico(p_account UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'precio_charola', c.precio_charola,
    'anticipo',       c.anticipo,
    'cupo_diario',    c.cupo_diario,
    'dias_entrega',   to_jsonb(c.dias_entrega),
    'dias_antes',     c.dias_antes,
    'fechas_cerradas',to_jsonb(c.fechas_cerradas),
    'aviso',          c.aviso,
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('grupo', i.grupo, 'nombre', i.nombre, 'precio', i.precio, 'dias', i.dias)
                       ORDER BY i.grupo, i.orden, i.nombre)
        FROM menu_items i
       WHERE i.account_id = c.account_id AND i.disponible
    ), '[]'::jsonb)
  )
  FROM menu_config c
  WHERE c.account_id = p_account;
$$;
REVOKE ALL ON FUNCTION public.menu_publico(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.menu_publico(UUID) TO anon, authenticated, service_role;

ALTER PUBLICATION supabase_realtime ADD TABLE public.menu_items;
NOTIFY pgrst, 'reload schema';
