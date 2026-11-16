-- ============================================================
-- 312 — AP Suministros: el estado de la cotización sigue a su columna
--        (edición ap-suministros, NO aplicar en Remesas Ya ni en Doña Miriam)
--
-- Ganada / Entregado → won · Perdida → lost · cualquier otra → open.
-- Así «Ganadas este mes» y «Perdidas este mes» cuentan solas.
-- Solo actúa en el tablero «Cotizaciones».
-- ============================================================

CREATE OR REPLACE FUNCTION public._ap_estado_por_columna()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_columna TEXT;
BEGIN
  SELECT s.name INTO v_columna
    FROM pipeline_stages s
    JOIN pipelines p ON p.id = s.pipeline_id
   WHERE s.id = NEW.stage_id AND p.name = 'Cotizaciones';
  IF v_columna IS NULL THEN
    RETURN NEW;
  END IF;
  NEW.status := CASE
    WHEN v_columna ILIKE 'ganad%' OR v_columna ILIKE 'entregad%' THEN 'won'
    WHEN v_columna ILIKE 'perdid%' THEN 'lost'
    ELSE 'open'
  END;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._ap_estado_por_columna() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_ap_estado_por_columna ON public.deals;
CREATE TRIGGER trg_ap_estado_por_columna
  BEFORE INSERT OR UPDATE OF stage_id ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public._ap_estado_por_columna();

-- Las cotizaciones son en pesos.
UPDATE public.accounts SET default_currency = 'MXN' WHERE default_currency IS DISTINCT FROM 'MXN';
UPDATE public.deals SET currency = 'MXN' WHERE currency IS DISTINCT FROM 'MXN';
