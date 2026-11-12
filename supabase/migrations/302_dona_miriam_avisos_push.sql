-- ============================================================
-- 302 — Avisos push al celular (edición dona-miriam, NO aplicar en Remesas Ya)
--
-- push_suscripciones  un renglón por celular/navegador que aceptó avisos.
-- push_llaves         las llaves VAPID. Las genera el propio servidor la
--                     primera vez (nadie las copia ni las pega); sin
--                     políticas RLS: solo el service role las lee.
-- deals.avisado_en    cuándo se avisó del encargo nuevo (evita avisos dobles).
-- push_resumenes      qué día ya se mandó el resumen de la noche.
--
-- Disparadores (pg_net → la app en Vercel). La app NO confía en lo que le
-- llega: con el id vuelve a leer el encargo con el service role y solo avisa
-- si es nuevo y no se ha avisado.
--   • al crear un encargo  → /api/avisos/evento
--   • 7 pm (Monterrey) dom–vie → /api/avisos/resumen
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE TABLE IF NOT EXISTS public.push_suscripciones (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint    TEXT NOT NULL UNIQUE,
  p256dh      TEXT NOT NULL,
  auth        TEXT NOT NULL,
  dispositivo TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  ultimo_ok   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_push_suscripciones_account ON public.push_suscripciones(account_id);
ALTER TABLE public.push_suscripciones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS push_suscripciones_propias ON public.push_suscripciones;
CREATE POLICY push_suscripciones_propias ON public.push_suscripciones FOR SELECT USING (user_id = auth.uid());
REVOKE ALL ON public.push_suscripciones FROM anon;

CREATE TABLE IF NOT EXISTS public.push_llaves (
  id          INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  publica     TEXT NOT NULL,
  privada     TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.push_llaves ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_llaves FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.push_resumenes (
  account_id  UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  fecha       DATE NOT NULL,
  enviado_en  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, fecha)
);
ALTER TABLE public.push_resumenes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_resumenes FROM anon, authenticated;

ALTER TABLE public.deals ADD COLUMN IF NOT EXISTS avisado_en TIMESTAMPTZ;

-- Al crear un encargo, la app manda el aviso (en segundo plano, no frena el insert).
CREATE OR REPLACE FUNCTION public._avisar_encargo_nuevo()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
BEGIN
  PERFORM net.http_post(
    url := 'https://crm-dona-miriam.vercel.app/api/avisos/evento',
    body := jsonb_build_object('tipo', 'nuevo', 'deal_id', NEW.id),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW; -- un aviso que falla nunca debe impedir guardar el encargo
END;
$$;
REVOKE ALL ON FUNCTION public._avisar_encargo_nuevo() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_avisar_encargo_nuevo ON public.deals;
CREATE TRIGGER trg_avisar_encargo_nuevo
  AFTER INSERT ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public._avisar_encargo_nuevo();

-- Resumen de la noche: 7 pm en Saltillo (UTC-6) = 01:00 UTC del día siguiente.
-- Lun–sáb UTC = la noche de dom–vie en Saltillo, la víspera de cada día de entrega.
DO $$
BEGIN
  PERFORM cron.unschedule('dona-miriam-resumen-noche')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dona-miriam-resumen-noche');
  PERFORM cron.schedule(
    'dona-miriam-resumen-noche',
    '0 1 * * 1-6',
    $job$SELECT net.http_post(
      url := 'https://crm-dona-miriam.vercel.app/api/avisos/resumen',
      body := '{}'::jsonb,
      headers := '{"Content-Type": "application/json"}'::jsonb
    )$job$
  );
END $$;
