-- =====================================================================
-- 041 — Fase 2, tramo 2A.2: escritura dual deal -> operacion
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- Mantiene `remittance_operations` al dia a partir de `deals`, que
-- SIGUE SIENDO LA FUENTE DE VERDAD. La operacion es todavia un espejo:
-- se rellena, pero no manda sobre nada.
--
-- POR QUE UN TRIGGER Y NO NODOS EN EL CEREBRO
--
--   1. No toca el workflow activo: nos ahorra el ciclo
--      desactivar/activar y la trampa de la version en memoria de n8n.
--   2. Captura TAMBIEN lo que hace un operador a mano en el CRM
--      (arrastrar un deal de etapa). El workflow no se entera de eso;
--      el trigger si. Con nodos, la operacion se desincronizaria en
--      cuanto alguien moviera una tarjeta.
--   3. Se revierte con un DROP TRIGGER, sin desplegar nada.
--
--   El patron ya existe en esta base: `trg_notify_deal_incidencia`
--   (migracion 038) es un trigger sobre la misma tabla.
--
-- ROLLBACK
--   DROP TRIGGER IF EXISTS trg_sync_operacion_desde_deal ON deals;
--   (la funcion puede quedarse: sin trigger no la llama nadie)
-- =====================================================================


-- ---------------------------------------------------------------------
-- Mapeo etapa -> estado, en un solo sitio
-- ---------------------------------------------------------------------
-- Estaba repetido en el backfill y en la vista de conciliacion de la
-- 040. Con el trigger serian tres copias, y tres copias de un CASE es
-- como se desincronizan las cosas. Se centraliza aqui.

CREATE OR REPLACE FUNCTION cerebro_estado_desde_etapa(p_stage_id uuid)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_stage_id
    WHEN '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109'::uuid THEN 'collecting_information'
    WHEN '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid THEN 'deposit_verification'
    WHEN 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63'::uuid THEN 'ready_to_transfer'
    WHEN '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b'::uuid THEN 'completed'
    WHEN 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid THEN 'incident'
    ELSE 'collecting_information'
  END;
$$;


-- ---------------------------------------------------------------------
-- El trigger
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cerebro_sync_operacion_desde_deal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
BEGIN
  -- Solo el pipeline de remesas. Otros pipelines del CRM no son
  -- operaciones de envio y no deben aparecer aqui.
  IF NEW.pipeline_id <> '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid THEN
    RETURN NULL;
  END IF;

  IF NEW.conversation_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_status := cerebro_estado_desde_etapa(NEW.stage_id);

  IF TG_OP = 'INSERT' THEN
    INSERT INTO remittance_operations (
      account_id, conversation_id, contact_id, deal_id, status,
      quoted_source_amount, source_currency, created_at,
      completed_at, cancelled_at
    ) VALUES (
      NEW.account_id, NEW.conversation_id, NEW.contact_id, NEW.id, v_status,
      NEW.value, coalesce(NEW.currency, 'GYD'), coalesce(NEW.created_at, now()),
      CASE WHEN v_status = 'completed' THEN now() END,
      CASE WHEN v_status = 'cancelled' THEN now() END
    )
    ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL DO NOTHING;

  ELSE
    -- Solo se tocan los campos que el deal manda. `delivery_method`,
    -- `deposit_method` y `quoted_destination_amount` son mas ricos en la
    -- operacion que en el deal y NO se pisan: los llenara 2C/2D.
    UPDATE remittance_operations o
       SET status               = v_status,
           quoted_source_amount = NEW.value,
           contact_id           = coalesce(NEW.contact_id, o.contact_id)
     WHERE o.deal_id = NEW.id
       AND (o.status IS DISTINCT FROM v_status
            OR o.quoted_source_amount IS DISTINCT FROM NEW.value
            OR o.contact_id IS DISTINCT FROM coalesce(NEW.contact_id, o.contact_id));

    -- Si el deal existia antes de la 040 o su operacion se perdio, se
    -- crea ahora. Evita que una fila quede fuera para siempre.
    INSERT INTO remittance_operations (
      account_id, conversation_id, contact_id, deal_id, status,
      quoted_source_amount, source_currency, created_at
    )
    SELECT NEW.account_id, NEW.conversation_id, NEW.contact_id, NEW.id, v_status,
           NEW.value, coalesce(NEW.currency,'GYD'), coalesce(NEW.created_at, now())
     WHERE NOT EXISTS (SELECT 1 FROM remittance_operations WHERE deal_id = NEW.id)
    ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL DO NOTHING;
  END IF;

  RETURN NULL;

EXCEPTION WHEN OTHERS THEN
  -- REGLA DEL PROYECTO: un fallo aqui NO puede tumbar el flujo del
  -- dinero. Un deal tiene que poder crearse y moverse aunque su espejo
  -- falle.
  --
  -- El precio es que falla en silencio. Las dos redes que lo cubren:
  --   1. `cerebro_conciliacion_operaciones` deja de dar 0 filas
  --   2. este WARNING queda en el log de Postgres
  RAISE WARNING '[cerebro] sync operacion fallo para deal % : %', NEW.id, SQLERRM;
  RETURN NULL;
END $$;


DROP TRIGGER IF EXISTS trg_sync_operacion_desde_deal ON deals;
CREATE TRIGGER trg_sync_operacion_desde_deal
  AFTER INSERT OR UPDATE OF stage_id, value, contact_id, currency ON deals
  FOR EACH ROW EXECUTE FUNCTION cerebro_sync_operacion_desde_deal();


-- ---------------------------------------------------------------------
-- La vista de conciliacion pasa a usar la funcion centralizada
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW cerebro_conciliacion_operaciones AS
  SELECT 'deal sin operacion'::text AS problema, d.id AS deal_id, NULL::uuid AS operation_id
    FROM deals d
    LEFT JOIN remittance_operations o ON o.deal_id = d.id
   WHERE d.conversation_id IS NOT NULL
     AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
     AND o.id IS NULL
  UNION ALL
  SELECT 'operacion sin deal', NULL, o.id
    FROM remittance_operations o
    LEFT JOIN deals d ON d.id = o.deal_id
   WHERE o.deal_id IS NOT NULL AND d.id IS NULL
  UNION ALL
  SELECT 'estado divergente', d.id, o.id
    FROM remittance_operations o
    JOIN deals d ON d.id = o.deal_id
   WHERE o.status <> cerebro_estado_desde_etapa(d.stage_id);


-- =====================================================================
-- COMO SE PROBO (9-ago-2026), todo en bloques DO revertidos
--
--   A. INSERT de un deal nuevo    -> se creo su operacion, estado correcto
--   B. Mover de etapa             -> la operacion siguio el estado
--   C. Cambiar el importe          -> quoted_source_amount actualizado
--   D. Deal de otro pipeline      -> NO crea operacion
--   E. Operacion borrada a mano y luego UPDATE -> se recrea
--   F. Conciliacion despues de todo -> 0 filas
--
-- ROLLBACK
--   DROP TRIGGER IF EXISTS trg_sync_operacion_desde_deal ON deals;
-- =====================================================================
