-- =====================================================================
-- 183 — the 179/180 beneficiary functions store without deals (STAGING ONLY for now)
--
-- Part of odd/tasks/align-staging-with-production.md (T3). 179/180 (production) keep their merge
-- rules in cerebro_guardar_beneficiario|zelle|reparto(_auto) and store the merged state through ONE
-- writer, cerebro_escribir_bloque_beneficiario, which appended a block to deals.notes and let the
-- notes trigger (043) parse it into remittance_beneficiaries. On the deal-free path (161/172) a deal
-- no longer creates an operation, so on staging those functions answered "guardado" and stored
-- nothing (measured: partial-beneficiary-tools.sql case 1a, RED).
--
-- This replaces ONLY that writer, keeping its signature, so every merge rule stays untouched:
--   * no open operation -> cerebro_crear_operacion (161), deal_id NULL;
--   * the block is parsed with cerebro_parsear_beneficiarios (179, partial-aware) and written as a new
--     generation (block_index = max + 1), the same structured write the 162 writers use;
--   * then the replacement rule of cerebro_sync_beneficiarios (175): the newest generation is
--     vigente, older rows reemplazado, except the latest Zelle when the newest is a card reparto;
--   * an operation whose beneficiaries an operator locked is not written (audit row), as in sync.
-- Returns the operation id (the deal-free convention: callers already treat it as "the id").
--
-- Guarded by supabase/staging/assertions/partial-beneficiary-tools.sql + partial-beneficiary-auto.sql
-- (now on a deal-free database) and a no-deal check.
-- ROLLBACK: ROLLBACK-183-deal-free-beneficiary-block.sql (179's writer)
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_escribir_bloque_beneficiario(p_conv uuid, p_op uuid, p_bloque text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op      uuid := p_op;
  v_bi      integer;
  v_reparto boolean;
  v_zelle   integer;
  v_locked  boolean;
  v_account uuid;
BEGIN
  IF v_op IS NULL THEN
    v_op := cerebro_crear_operacion(p_conv);
  END IF;

  SELECT admin_locked_fields ? 'beneficiaries', account_id INTO v_locked, v_account
    FROM remittance_operations WHERE id = v_op;
  IF v_locked THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason)
    VALUES (v_account, 'remittance_beneficiaries', v_op, 'beneficiaries', 'automation_write_suppressed',
            wacrm_current_actor(), 'beneficiaries locked by operator correction');
    RETURN v_op;
  END IF;

  SELECT coalesce(max(b.block_index), 0) + 1 INTO v_bi FROM remittance_beneficiaries b WHERE b.operation_id = v_op;

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone,
                                        zelle_account, amount, currency, position, block_index, source, status)
  SELECT v_op, p.tipo, p.nombre, p.tarjeta, p.celular, p.cuenta_zelle, p.monto, p.moneda, p.posicion, v_bi,
         'notes_parse', 'vigente'
    FROM cerebro_parsear_beneficiarios(p_bloque) p;

  -- (175) The newest generation is a reparto between cards: the latest Zelle stays vigente next to it.
  v_reparto := EXISTS (SELECT 1 FROM remittance_beneficiaries
                        WHERE operation_id = v_op AND block_index = v_bi
                          AND beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical'));
  IF v_reparto THEN
    SELECT max(block_index) INTO v_zelle FROM remittance_beneficiaries
     WHERE operation_id = v_op AND beneficiary_type = 'zelle' AND block_index < v_bi;
  END IF;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = v_op AND block_index < v_bi AND status <> 'reemplazado'
     AND block_index IS DISTINCT FROM v_zelle;

  UPDATE remittance_beneficiaries
     SET status = 'vigente', replaced_at = NULL
   WHERE operation_id = v_op AND block_index = v_zelle AND beneficiary_type = 'zelle' AND status <> 'vigente';

  RETURN v_op;
END $$;

REVOKE ALL ON FUNCTION public.cerebro_escribir_bloque_beneficiario(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
