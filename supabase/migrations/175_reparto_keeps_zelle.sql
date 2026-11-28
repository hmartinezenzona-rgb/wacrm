-- =====================================================================
-- 175 — a card reparto keeps the remesa's Zelle
--
-- Real case: Kenia 5927478061 (2026-09-29) asked for 150 USD = 100 Zelle +
-- 30 + 20 USD to two Clasica cards. The notes of her deal got, in order: the
-- Zelle block, one single-card block per card as they arrived, and finally the
-- reparto between the two cards. cerebro_sync_beneficiarios keeps ONLY the
-- newest block vigente, so the Zelle (100 USD) vanished from the panel.
--
-- Decision (user, 2026-10-01): when the newest block is a reparto between
-- cards, the remesa's latest Zelle stays vigente next to the cards. A single
-- card after a Zelle still replaces it (the customer changed rail), and with
-- several Zelle blocks only the latest one comes back. If it was really a
-- correction, the team removes the extra Zelle from the panel; losing a Zelle
-- the customer wanted is worse and goes unnoticed.
--
-- Guarded by supabase/staging/assertions/reparto-keeps-zelle.sql
-- ROLLBACK: ROLLBACK-175-reparto-keeps-zelle.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_sync_beneficiarios(p_deal_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op uuid; v_notes text; v_max int; v_nuevos int := 0;
  v_locked boolean; v_account_id uuid;
  v_reparto boolean; v_zelle int;
BEGIN
  SELECT o.id, d.notes INTO v_op, v_notes
    FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
   WHERE d.id = p_deal_id;

  IF v_op IS NULL THEN RETURN 0; END IF;

  SELECT admin_locked_fields ? 'beneficiaries', account_id INTO v_locked, v_account_id
    FROM remittance_operations WHERE id = v_op;

  IF v_locked THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason)
    VALUES (v_account_id, 'remittance_beneficiaries', v_op, 'beneficiaries', 'automation_write_suppressed',
            wacrm_current_actor(), 'beneficiaries locked by operator correction');
    RETURN 0;
  END IF;

  WITH p AS (SELECT * FROM cerebro_parsear_beneficiarios(v_notes))
  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone,
    zelle_account, amount, currency, position, block_index, source, status)
  SELECT v_op, p.tipo, p.nombre, p.tarjeta, p.celular,
         p.cuenta_zelle, p.monto, p.moneda, p.posicion, p.block_index,
         'notes_parse', 'vigente'
    FROM p
  ON CONFLICT (operation_id, block_index, position) DO NOTHING;

  GET DIAGNOSTICS v_nuevos = ROW_COUNT;

  SELECT max(block_index) INTO v_max
    FROM remittance_beneficiaries WHERE operation_id = v_op;

  -- (175) The newest block is a reparto between cards: the remesa's latest Zelle
  -- block stays (or comes back) vigente next to it.
  v_reparto := EXISTS (SELECT 1 FROM remittance_beneficiaries
                        WHERE operation_id = v_op AND block_index = v_max
                          AND beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical'));
  IF v_reparto THEN
    SELECT max(block_index) INTO v_zelle
      FROM remittance_beneficiaries
     WHERE operation_id = v_op AND beneficiary_type = 'zelle' AND source = 'notes_parse';
  END IF;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = v_op AND block_index < v_max AND status <> 'reemplazado'
     AND block_index IS DISTINCT FROM v_zelle;

  UPDATE remittance_beneficiaries
     SET status = 'vigente', replaced_at = NULL
   WHERE operation_id = v_op AND (block_index = v_max OR block_index = v_zelle) AND status <> 'vigente';

  RETURN v_nuevos;
END $function$;
