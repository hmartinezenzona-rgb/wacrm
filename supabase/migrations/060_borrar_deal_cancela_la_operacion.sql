-- 060 — Borrar un deal CANCELA su operacion, en vez de dejarla huerfana
-- YA APLICADA EN PRODUCCION el 10-ago-2026. NO LA EJECUTES.
--
-- POR QUE
-- trg_sync_operacion_desde_deal solo disparaba en INSERT y UPDATE. Al borrar un
-- deal, su fila de remittance_operations se quedaba con el status que tuviera
-- (ready_to_transfer, incident...) y un deal_id APUNTANDO A NADA: no hay ninguna
-- clave foranea en remittance_operations, asi que la referencia queda colgando.
--
-- Y cerebro_resolver_operacion cuenta por `status NOT IN (completed,cancelled)`
-- SIN comprobar que el deal exista, asi que esas operaciones fantasma se cuentan
-- como envios VIVOS. El 10-ago el chat del revendedor mostraba 7 envios abiertos
-- que no existian.
--
-- QUE HACE
-- Anade la rama DELETE. Cancela solo las operaciones NO terminales: una
-- `completed` se queda como esta, porque el dinero se entrego de verdad y es
-- historia que las vistas de volumen necesitan.
--
-- Se CONSERVA el deal_id aunque quede colgando: es el unico rastro de de que
-- deal vino la operacion. Los uuid no se reutilizan, asi que no colisiona con
-- el ON CONFLICT (deal_id) del INSERT.
--
-- La rama DELETE lleva su PROPIO bloque de excepcion: si fallara, no puede
-- impedir que se borre el deal. Y no puede compartir el handler de abajo porque
-- ese usa NEW, que en un trigger DELETE no esta asignado.
--
-- COMO SE PROBO (deal fabricado dentro de un bloque que se revierte)
--   A) etapa "Por verificar" -> la operacion nace en `deposit_verification`
--      y al borrar el deal queda en `cancelled`.            OK
--   B) etapa "Entregada"     -> nace en `completed` y al borrar el deal
--      SIGUE en `completed`, no se toca.                    OK
--   Sin rastro despues: 0 deals y 0 operaciones de prueba.
--
-- LIMPIEZA PUNTUAL, ejecutada una sola vez tras aplicar lo de arriba:
--   UPDATE remittance_operations o
--      SET status='cancelled', cancelled_at=now(), updated_at=now()
--    WHERE o.deal_id IS NOT NULL
--      AND o.status NOT IN ('completed','cancelled')
--      AND NOT EXISTS (SELECT 1 FROM deals d WHERE d.id = o.deal_id);
--   -> 8 operaciones en 2 chats. Despues: 0 divergencias, 4 envios vivos y
--      los 4 con deal real. El chat del revendedor paso de 7 abiertos a 0.
--
-- REVERSION
--   Ejecutar ROLLBACK-060-sync-operacion-antes.sql. NO deshace la limpieza
--   puntual, y no hace falta: esas 8 operaciones no tenian deal.

CREATE OR REPLACE FUNCTION public.cerebro_sync_operacion_desde_deal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_status text;
BEGIN
  -- RAMA DELETE: el deal ya no existe, la operacion no puede seguir viva.
  IF TG_OP = 'DELETE' THEN
    BEGIN
      IF OLD.pipeline_id IS DISTINCT FROM '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid THEN
        RETURN NULL;
      END IF;
      UPDATE remittance_operations
         SET status = 'cancelled', cancelled_at = now(), updated_at = now()
       WHERE deal_id = OLD.id
         AND status NOT IN ('completed','cancelled');
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[cerebro] cancelar operacion fallo al borrar deal % : %', OLD.id, SQLERRM;
    END;
    RETURN NULL;
  END IF;

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
  AFTER INSERT OR DELETE OR UPDATE OF stage_id, value, contact_id, currency ON public.deals
  FOR EACH ROW EXECUTE FUNCTION cerebro_sync_operacion_desde_deal();
