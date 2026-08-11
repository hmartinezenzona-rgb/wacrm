-- COPIA DE SEGURIDAD ANTES DE LA 060.
-- Para revertir: ejecutar este fichero tal cual. Devuelve la funcion SIN la
-- rama DELETE y el trigger SIN el evento DELETE.
-- OJO: no deshace la limpieza puntual de las 8 operaciones divergentes.

CREATE OR REPLACE FUNCTION public.cerebro_sync_operacion_desde_deal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_status text;
BEGIN
  IF NEW.pipeline_id <> '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid THEN RETURN NULL; END IF;
  IF NEW.conversation_id IS NULL THEN RETURN NULL; END IF;

  v_status := cerebro_estado_desde_etapa(NEW.stage_id);

  IF TG_OP = 'INSERT' THEN
    INSERT INTO remittance_operations (
      account_id, conversation_id, contact_id, deal_id, status,
      quoted_source_amount, source_currency, created_at, completed_at, cancelled_at)
    VALUES (NEW.account_id, NEW.conversation_id, NEW.contact_id, NEW.id, v_status,
      NEW.value, coalesce(NEW.currency,'GYD'), coalesce(NEW.created_at, now()),
      CASE WHEN v_status='completed' THEN now() END,
      CASE WHEN v_status='cancelled' THEN now() END)
    ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL DO NOTHING;
  ELSE
    UPDATE remittance_operations o
       SET status = v_status,
           quoted_source_amount = NEW.value,
           contact_id = coalesce(NEW.contact_id, o.contact_id)
     WHERE o.deal_id = NEW.id
       AND (o.status IS DISTINCT FROM v_status
            OR o.quoted_source_amount IS DISTINCT FROM NEW.value
            OR o.contact_id IS DISTINCT FROM coalesce(NEW.contact_id, o.contact_id));

    INSERT INTO remittance_operations (
      account_id, conversation_id, contact_id, deal_id, status,
      quoted_source_amount, source_currency, created_at)
    SELECT NEW.account_id, NEW.conversation_id, NEW.contact_id, NEW.id, v_status,
           NEW.value, coalesce(NEW.currency,'GYD'), coalesce(NEW.created_at, now())
     WHERE NOT EXISTS (SELECT 1 FROM remittance_operations WHERE deal_id = NEW.id)
    ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL DO NOTHING;
  END IF;

  -- Ya existe la operacion: ahora si se pueden colgar los beneficiarios.
  PERFORM cerebro_sync_beneficiarios(NEW.id);

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] sync operacion fallo para deal % : %', NEW.id, SQLERRM;
  RETURN NULL;
END $function$;

DROP TRIGGER IF EXISTS trg_sync_operacion_desde_deal ON public.deals;
CREATE TRIGGER trg_sync_operacion_desde_deal
  AFTER INSERT OR UPDATE OF stage_id, value, contact_id, currency ON public.deals
  FOR EACH ROW EXECUTE FUNCTION cerebro_sync_operacion_desde_deal();
