-- =====================================================================
-- 043 — Fase 2, tramo 2C.2 (parte SQL)
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- Arregla un fallo de ORDEN DE TRIGGERS que salio al probar 2C.2, y que
-- hacia que ningun beneficiario se registrara al crear un envio nuevo.
--
-- EL FALLO
--
--   `trg_sync_benef_desde_deal` y `trg_sync_operacion_desde_deal` son
--   los dos AFTER INSERT sobre `deals`. **Postgres los dispara en orden
--   alfabetico de nombre**, y "benef" < "operacion".
--
--   Resultado: al insertarse un deal, el de beneficiarios corria PRIMERO,
--   cuando la operacion todavia no existia. Como
--   `cerebro_sync_beneficiarios` hace JOIN contra `remittance_operations`,
--   no encontraba nada y salia sin hacer nada. En silencio.
--
--   Se vio porque una prueba end-to-end creo un envio con beneficiario y
--   la tabla se quedo vacia. La conciliacion NO lo detecta: mira
--   operaciones contra deals, no beneficiarios.
--
-- EL ARREGLO, con cinturon y tirantes
--
--   1. El trigger de operaciones llama a `cerebro_sync_beneficiarios()`
--      al final, cuando la operacion ya existe. Esto por si solo
--      resuelve el problema y no depende de nombres.
--   2. Ademas el trigger de beneficiarios se renombra a
--      `trg_sync_z_benef_desde_deal` para que quede DESPUES por orden
--      alfabetico. Redundante a proposito.
--
--   Es idempotente: sincronizar dos veces no duplica (indice unico por
--   operation_id + block_index + position).
--
-- ROLLBACK
--   Restaurar `cerebro_sync_operacion_desde_deal` de la migracion 041
--   y renombrar el trigger a `trg_sync_benef_desde_deal`.
-- =====================================================================

CREATE OR REPLACE FUNCTION cerebro_sync_operacion_desde_deal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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

  -- La operacion ya existe: ahora si se le pueden colgar los
  -- beneficiarios. Ver la explicacion de arriba.
  PERFORM cerebro_sync_beneficiarios(NEW.id);

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[cerebro] sync operacion fallo para deal % : %', NEW.id, SQLERRM;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_sync_benef_desde_deal ON deals;
CREATE TRIGGER trg_sync_z_benef_desde_deal
  AFTER INSERT OR UPDATE OF notes ON deals
  FOR EACH ROW EXECUTE FUNCTION cerebro_sync_benef_trigger();


-- =====================================================================
-- PARTE QUE NO ES SQL: las cinco tools del Cerebro
--
-- En el mismo tramo se cambiaron cinco nodos del workflow
-- `T3v07IQqtMs6AKJ4` para que dejen de coger "el deal abierto mas
-- reciente":
--
--   gestionar_beneficiario, registrar_beneficiario_zelle,
--   registrar_reparto_multiple, marcar_destino_usd,
--   Registrar beneficiario auto
--
-- En cada una:
--
--   1. Se anadio como primer CTE:
--        res AS (SELECT * FROM cerebro_resolver_operacion($1::uuid,
--          ARRAY['collecting_information','deposit_verification',
--                'ready_to_transfer']))
--      Esos tres estados son EXACTAMENTE los tres stages que las tools
--      aceptaban antes. Sin ese filtro, empezarian a escribir sobre
--      envios en Incidencia, que hoy no tocan.
--
--   2. El CTE `abierto` pasa de
--        FROM deals d WHERE ... ORDER BY d.created_at DESC LIMIT 1
--      a
--        FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
--         WHERE o.id = (SELECT operation_id FROM res)
--      Con 'ambigua' o 'ninguna', operation_id es NULL y no salen filas.
--
--   3. El CTE `ins` (crear envio nuevo) lleva ademas
--        AND (SELECT resultado FROM res) <> 'ambigua'
--      Sin esto, la ambiguedad habria creado un TERCER envio.
--
--   4. Un CTE `ambiguo` nuevo que **asigna la conversacion a una
--      persona por SQL** y devuelve un texto explicativo.
--
-- POR QUE EL PASO 4 ASIGNA EN VEZ DE SOLO AVISAR
--
--   La primera version solo devolvia un mensaje de error a la tool. Se
--   probo y **el modelo lo ignoro**: le dijo al cliente "Anotado, cambio
--   la tarjeta" cuando no se habia guardado nada. Eso es peor que el
--   fallo original: no corrompe datos, pero MIENTE al cliente.
--
--   Con la asignacion en SQL el efecto no depende de que el modelo
--   obedezca. Ademas el `Decisor` ve la conversacion asignada, corta sin
--   llamar al modelo y cierra el lote. Verificado.
--
-- Copia previa: ROLLBACK-v2-antes-2C2.json
-- =====================================================================
