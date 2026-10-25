-- =====================================================================
-- 319 -- An agreed amount closes itself when its shipment ends
--
-- Owner 2026-10-25 (Miguel, conversation 1727ef31): a client deposit fell into
-- "verificado_de_mas" because the objective still held the amount of a shipment
-- completed six days earlier (77 USD / 20.020 GYD) and the new one was 100 USD
-- (26.000 GYD). The cross compares the deposit against
-- cerebro_objetivo_envio, and that row never closes when the shipment ends:
--   * cerebro_objetivo_cerrar_op only ran from inside cerebro_cruzar_depositos
--     and only when the deposit matched exactly at cross time, so a shipment
--     that ended by any other path (panel delivery, manual close, cancel) left
--     the row open for ever.
--   * The next shipment then inherited the old amount, and any difference
--     turned into a false incident (de mas or incompleto).
-- Nine conversations carried an objective open for more than a day.
--
-- Fix: a trigger on the operation's status. When an operation reaches
-- 'completed' or 'cancelled' and no other operation of the same conversation is
-- still active, the conversation's open objective closes. Mixed sends are safe:
-- the last part to finish is the one that closes it.
--
-- The helper is exposed so the assertion can prove both directions without
-- staging a whole shipment.
--
-- Assertion: supabase/staging/assertions/objetivo-se-cierra.sql.
-- Rollback: ROLLBACK-319-objetivo-se-cierra.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_objetivo_cerrar_si_cerrada(p_conv uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_conv IS NULL THEN
    RETURN false;
  END IF;

  -- Still something in flight in this conversation: the objective stays open.
  IF EXISTS (SELECT 1 FROM remittance_operations r
              WHERE r.conversation_id = p_conv
                AND r.status NOT IN ('completed', 'cancelled')) THEN
    RETURN false;
  END IF;

  UPDATE cerebro_objetivo_envio
     SET cerrado_en = now()
   WHERE conversation_id = p_conv
     AND cerrado_en IS NULL;

  RETURN FOUND;
END;
$function$;

COMMENT ON FUNCTION public.cerebro_objetivo_cerrar_si_cerrada(uuid) IS
  'Closes the conversation''s open agreed amount when no operation of it is still active (319). Returns true when it closed a row.';

CREATE OR REPLACE FUNCTION public.remittance_operations_cierra_objetivo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status IN ('completed', 'cancelled') THEN
    PERFORM public.cerebro_objetivo_cerrar_si_cerrada(NEW.conversation_id);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS remittance_operations_cierra_objetivo ON public.remittance_operations;
CREATE TRIGGER remittance_operations_cierra_objetivo
  AFTER UPDATE OF status ON public.remittance_operations
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.status IN ('completed', 'cancelled'))
  EXECUTE FUNCTION public.remittance_operations_cierra_objetivo();

REVOKE ALL ON FUNCTION public.cerebro_objetivo_cerrar_si_cerrada(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_objetivo_cerrar_si_cerrada(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.remittance_operations_cierra_objetivo() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.remittance_operations_cierra_objetivo() TO service_role;
