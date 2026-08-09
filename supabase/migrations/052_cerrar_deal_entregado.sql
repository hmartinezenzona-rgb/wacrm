-- =====================================================================
-- 052 — Las remesas entregadas se cierran solas
--
--   YA APLICADA EN PRODUCCION EL 9-AGO-2026. NO LA EJECUTES DE NUEVO.
--
-- QUE ARREGLA
--
--   Cierra la deuda 10: nadie marcaba las remesas como ganadas, asi que
--   `status` no era fiable. **16 de 17 entregadas seguian en `open`.**
--
--   Consecuencia medida antes de tocar nada — el dashboard del CRM
--   mostraba el "valor de negocios abiertos" **nueve veces inflado**:
--
--     lo que mostraba .................. 467.600 GYD
--     lo que estaba de verdad en curso .. 53.000 GYD
--     entregado y contado como abierto . 414.600 GYD
--
--   Y crecia cada dia, porque el acumulado nunca bajaba.
--
-- LO QUE **NO** ARREGLA — leerlo antes de dar el problema por cerrado
--
--   **El Kanban NO filtra por `status`.** Se comprobo en
--   `src/app/(dashboard)/pipelines/page.tsx`:
--
--     .from("deals").select(...).eq("pipeline_id", pipelineId)
--
--   Trae todos los deals de cada etapa. Asi que marcar `won` **no quita
--   la tarjeta del tablero**: la columna "Entregada" sigue creciendo.
--
--   Vaciar la columna es trabajo de WaCRM (Hermes): filtrar por estado o
--   mostrar solo lo entregado en los ultimos dias. **Las dos cosas van
--   juntas**: si el CRM filtra por `status` pero nadie cierra, no cambia
--   nada; y si se cierra pero el CRM no filtra, tampoco.
--
-- ROLLBACK
--   DROP TRIGGER IF EXISTS trg_cerrar_deal_entregado ON deals;
--   DROP FUNCTION IF EXISTS cerebro_cerrar_deal_entregado();
--   -- y para deshacer el backfill (solo si hace falta):
--   -- UPDATE deals SET status='open'
--   --  WHERE stage_id='1b36b34c-1bf1-4095-9a86-5ec5ff945d2b' AND status='won';
-- =====================================================================

CREATE OR REPLACE FUNCTION cerebro_cerrar_deal_entregado()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_entregada uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';
BEGIN
  IF NEW.pipeline_id <> '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid THEN
    RETURN NEW;
  END IF;

  -- Llega a Entregada: se da por ganada.
  IF NEW.stage_id = v_entregada AND NEW.status = 'open' THEN
    NEW.status := 'won';

  -- Y al reves: si SALE de Entregada (una entrega que se corrige, o que
  -- va a Incidencia), vuelve a estar abierta. Sin esto, un envio con
  -- problema quedaria marcado como ganado para siempre.
  ELSIF TG_OP = 'UPDATE'
        AND OLD.stage_id = v_entregada
        AND NEW.stage_id <> v_entregada
        AND NEW.status = 'won' THEN
    NEW.status := 'open';
  END IF;

  RETURN NEW;
END $$;

-- BEFORE, no AFTER: modifica NEW directamente y evita un segundo UPDATE
-- (que ademas dispararia otros triggers).
DROP TRIGGER IF EXISTS trg_cerrar_deal_entregado ON deals;
CREATE TRIGGER trg_cerrar_deal_entregado
  BEFORE INSERT OR UPDATE OF stage_id ON deals
  FOR EACH ROW EXECUTE FUNCTION cerebro_cerrar_deal_entregado();


-- Backfill de las que ya estaban entregadas
UPDATE deals SET status = 'won'
 WHERE pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
   AND stage_id = '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b'
   AND status = 'open';


-- =====================================================================
-- POR QUE EL BACKFILL NO AVISA A NADIE — se verifico ANTES de ejecutarlo
--
--   Se revisaron los 8 triggers de `deals`. **Ninguno escucha `status`**:
--
--     deals_stage_notify ............ UPDATE OF stage_id
--     trg_notify_deal_incidencia .... UPDATE OF stage_id
--     deals_sync_tags ............... UPDATE OF stage_id, contact_id
--     trg_sync_operacion_desde_deal . UPDATE OF stage_id, value, contact_id, currency
--     trg_sync_z_benef_desde_deal ... UPDATE OF notes
--
--   Un UPDATE que solo toca `status` no dispara ninguno. Confirmado tras
--   el backfill: **0 notificaciones generadas**. Importaba, porque
--   `deals_stage_notify` es el que manda "su remesa fue completada" al
--   CLIENTE — 16 mensajes falsos habrian sido un problema serio.
--
-- COMO SE PROBO (bloque revertido, antes del backfill)
--   A. mover un deal a Entregada  -> open -> won
--   B. sacarlo a Incidencia       -> won -> open
--
-- RESULTADO DEL BACKFILL
--   17 ganadas, 2 abiertas, 0 notificaciones, 0 divergencias.
--   Valor de negocios abiertos: 467.600 -> **53.000 GYD**.
-- =====================================================================
