-- ============================================================
-- 063 — La conciliacion solo vigila operaciones VIVAS sin deal
-- ============================================================
-- YA APLICADA EN PRODUCCION el 11-ago-2026 (01:45 UTC) via MCP
-- apply_migration. NO LA EJECUTES: este fichero es el registro.
--
-- Problema (hallazgo 3 de la auditoria del 11-ago):
-- `cerebro_conciliacion_operaciones` daba 8 filas permanentes.
-- Eran operaciones `cancelled` de la limpieza de la 060 (deal
-- borrado a mano; la rama DELETE conserva el deal_id colgando A
-- PROPOSITO, como rastro de auditoria). La rama "operacion sin
-- deal" no filtraba por status, asi que ese rastro salia como
-- divergencia -> la alarma "debe dar 0 filas" quedo ciega.
--
-- Lo nuevo es UNA linea: `AND o.status NOT IN ('completed','cancelled')`
-- en la rama "operacion sin deal". Una operacion terminal con
-- deal_id colgando es historia, no divergencia.
--
-- Como se probo (bloque DO auto-revertido, 11-ago):
--   1. Tras aplicar: la vista da 0 filas (antes 8).
--   2. Deal de prueba en el pipeline de remesas -> el trigger crea
--      la operacion espejo -> se borra SOLO la operacion ->
--      'deal sin operacion': 1. La rama intacta sigue viva.
--   3. Operacion VIVA (deposit_verification) con deal_id colgando
--      -> 'operacion sin deal': 1 — y las 8 cancelled fuera.
--   4. RAISE EXCEPTION revirtio todo; la vista volvio a 0.
--
-- Rollback: recrear la vista sin la linea del status (definicion
-- vieja en pg_get_viewdef de cualquier backup previo al 11-ago).

CREATE OR REPLACE VIEW cerebro_conciliacion_operaciones AS
 SELECT 'deal sin operacion'::text AS problema, d.id AS deal_id, NULL::uuid AS operation_id
   FROM deals d
   LEFT JOIN remittance_operations o ON o.deal_id = d.id
  WHERE d.conversation_id IS NOT NULL
    AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid
    AND o.id IS NULL
 UNION ALL
 SELECT 'operacion sin deal', NULL::uuid, o.id
   FROM remittance_operations o
   LEFT JOIN deals d ON d.id = o.deal_id
  WHERE o.deal_id IS NOT NULL AND d.id IS NULL
    AND o.status NOT IN ('completed','cancelled')   -- <- LO NUEVO
 UNION ALL
 SELECT 'estado divergente', d.id, o.id
   FROM remittance_operations o
   JOIN deals d ON d.id = o.deal_id
  WHERE o.status <> CASE d.stage_id
      WHEN '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109'::uuid THEN 'collecting_information'
      WHEN '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid THEN 'deposit_verification'
      WHEN 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63'::uuid THEN 'ready_to_transfer'
      WHEN '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b'::uuid THEN 'completed'
      WHEN 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid THEN 'incident'
      ELSE 'collecting_information' END;
