-- ============================================================
-- 332 — Configuración por negocio: un solo CRM para todos.
--
-- negocio_config  una fila por cuenta con lo que cambia de un negocio a
--                 otro: logo, secciones del menú, textos, botón de cada
--                 columna, resumen de la tarjeta y avisos. El código la
--                 lee en src/lib/negocio/config.ts (leerNegocio); si falta
--                 algo usa sus valores por defecto.
--
-- Forma de data:
-- {
--   "nombre": "Onlinefreedom",
--   "logo": {"src": "/logo-onlinefreedom.svg", "ancho": 262, "alto": 64},
--   "menu": ["pipelines", "inbox", "catalogo", "contacts"],   -- también "cocinar", "menu"
--   "textos": {"Sidebar": {"pipelines": "Ventas"}},           -- reemplaza textos de messages/es.json
--   "tarjeta": {"resumen": ["Giro", "Reto"], "destacar": [{"clave": "Llamada", "etiqueta": "Llamada"}]},
--   "columnas": {"Propuesta enviada": {"boton": "Ya la envié", "alerta_dias": 3}},
--   "avisos": {"nuevo": {"titulo": "Nuevo prospecto", "resumen": ["Giro", "Reto"]},
--              "seguimiento": {"columna": "Propuesta enviada", "dias": 3,
--                              "singular": "propuesta", "plural": "propuestas"}}
-- }
-- La fila de cada negocio es dato de su cuenta (ver LEEME del CRM).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.negocio_config (
  account_id UUID PRIMARY KEY REFERENCES public.accounts(id) ON DELETE CASCADE,
  data       JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.negocio_config ENABLE ROW LEVEL SECURITY;

-- Cualquier miembro de la cuenta la lee; solo admin o dueño la cambia.
DROP POLICY IF EXISTS negocio_config_leer ON public.negocio_config;
CREATE POLICY negocio_config_leer ON public.negocio_config
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT account_id FROM public.profiles WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS negocio_config_editar ON public.negocio_config;
CREATE POLICY negocio_config_editar ON public.negocio_config
  FOR ALL TO authenticated
  USING (account_id IN (SELECT account_id FROM public.profiles
                         WHERE user_id = auth.uid() AND account_role IN ('owner', 'admin')))
  WITH CHECK (account_id IN (SELECT account_id FROM public.profiles
                              WHERE user_id = auth.uid() AND account_role IN ('owner', 'admin')));

GRANT SELECT, INSERT, UPDATE ON public.negocio_config TO authenticated;
GRANT ALL ON public.negocio_config TO service_role;

NOTIFY pgrst, 'reload schema';
