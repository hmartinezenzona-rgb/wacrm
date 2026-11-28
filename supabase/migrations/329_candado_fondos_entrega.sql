-- =====================================================================
-- 329 -- Money guards: no delivery without verified funding, and recipient sums on every rail.
--
-- crm_entregar_operacion only checked beneficiary completeness and (328) the Zelle sums. A ready
-- operation with no consumed MMG deposit could be delivered; the same mismatch on a CUP, Clasica,
-- Tropical, Mexico or cash operation was invisible. cerebro_saldo_operacion ignored a deposit
-- consumed with operation_id NULL (the admin typed-TransID path) even when a receipt of the
-- operation carries its TransID.
--
-- This migration adds cerebro_fondos_operacion (group-aware verified funding, matching unlinked
-- deposits through a receipt reference), makes cerebro_saldo_operacion use the same definition, and
-- gates delivery on funding plus a general recipient-sum check. Under-funding blocks delivery;
-- over-funding is allowed in phase 1. 328 was never applied in production (schema_migrations ended
-- at 327), so it ships in the same bundle.
--
-- Assertion: supabase/staging/assertions/candado-fondos-entrega.sql.
-- Rollback: ROLLBACK-329-candado-fondos-entrega.sql.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.cerebro_fondos_operacion(p_op uuid)
 RETURNS TABLE(requerido numeric, depositado numeric, cubierto boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH base AS (
    SELECT ro.id, ro.mixed_group_id
      FROM remittance_operations ro
     WHERE ro.id = p_op
  ),
  miembros AS (
    SELECT m.id, m.quoted_source_amount
      FROM base b
      JOIN remittance_operations m
        ON (b.mixed_group_id IS NOT NULL AND m.mixed_group_id = b.mixed_group_id AND m.status <> 'cancelled')
        OR (b.mixed_group_id IS NULL AND m.id = b.id)
  ),
  depositos AS (
    -- A verified GYD deposit counts once: linked to a member, or unlinked but carrying the TransID of
    -- a member's receipt (the admin typed-TransID path consumes it with operation_id NULL).
    SELECT DISTINCT d.trans_id, d.monto
      FROM depositos_mmg d
     WHERE d.consumido_en IS NOT NULL
       AND d.anulado_en IS NULL
       AND d.descartado_en IS NULL
       AND COALESCE(d.moneda, 'GYD') = 'GYD'
       AND (d.operation_id IN (SELECT id FROM miembros)
            OR (d.operation_id IS NULL
                AND EXISTS (SELECT 1 FROM remittance_operation_receipts r
                             WHERE r.operation_id IN (SELECT id FROM miembros)
                               AND r.reference ~ ('(^|[^0-9])' || d.trans_id || '([^0-9]|$)'))))
  )
  SELECT (SELECT COALESCE(sum(quoted_source_amount), 0) FROM miembros),
         (SELECT COALESCE(sum(monto), 0) FROM depositos),
         ((SELECT COALESCE(sum(quoted_source_amount), 0) FROM miembros) > 0
          AND (SELECT COALESCE(sum(monto), 0) FROM depositos)
              >= (SELECT COALESCE(sum(quoted_source_amount), 0) FROM miembros));
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_saldo_operacion(p_op uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH miembro AS (
    SELECT ro.id, ro.quoted_source_amount
      FROM remittance_operations base
      JOIN remittance_operations ro
        ON (base.mixed_group_id IS NOT NULL
            AND ro.mixed_group_id = base.mixed_group_id
            AND ro.status <> 'cancelled')
        OR (base.mixed_group_id IS NULL AND ro.id = base.id)
     WHERE base.id = p_op
  ),
  dep AS (
    -- Same verified money as cerebro_fondos_operacion: linked deposits plus unlinked deposits whose
    -- TransID appears in a receipt of a member (the admin typed-TransID path). A linked deposit never
    -- counts for another operation through a receipt.
    SELECT DISTINCT d.trans_id, d.monto
      FROM depositos_mmg d
     WHERE d.consumido_en IS NOT NULL
       AND d.anulado_en IS NULL
       AND d.descartado_en IS NULL
       AND COALESCE(d.moneda, 'GYD') = 'GYD'
       AND (d.operation_id IN (SELECT id FROM miembro)
            OR (d.operation_id IS NULL
                AND EXISTS (SELECT 1 FROM remittance_operation_receipts r
                             WHERE r.operation_id IN (SELECT id FROM miembro)
                               AND r.reference ~ ('(^|[^0-9])' || d.trans_id || '([^0-9]|$)'))))
  ),
  obj AS (
    SELECT o.monto, o.moneda
      FROM cerebro_objetivo_envio o
     WHERE o.conversation_id = (SELECT ro.conversation_id
                                  FROM remittance_operations ro
                                 WHERE ro.id = p_op)
       AND o.cerrado_en IS NULL
       AND (o.operation_id IS NULL OR o.operation_id = p_op)
  ),
  grp AS (
    SELECT ro.mixed_group_id AS g FROM remittance_operations ro WHERE ro.id = p_op
  ),
  gobj AS (
    SELECT sum(ro.quoted_source_amount) AS monto
      FROM remittance_operations ro
     WHERE ro.mixed_group_id = (SELECT g FROM grp)
       AND ro.status <> 'cancelled'
  )
  SELECT CASE WHEN (SELECT g FROM grp) IS NULL THEN (SELECT monto FROM obj) ELSE (SELECT monto FROM gobj) END,
         (SELECT COALESCE(sum(monto), 0) FROM dep),
         CASE WHEN (SELECT g FROM grp) IS NULL
              THEN (SELECT monto FROM obj) - (SELECT COALESCE(sum(monto), 0) FROM dep)
              ELSE (SELECT monto FROM gobj) - (SELECT COALESCE(sum(monto), 0) FROM dep) END,
         CASE WHEN (SELECT g FROM grp) IS NULL THEN COALESCE((SELECT moneda FROM obj), 'GYD') ELSE 'GYD' END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb, p_notify boolean DEFAULT true, p_cup_source_card_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_deal_id       uuid;

  v_status_before text;
  v_status_after  text;
  v_completed_at  timestamptz;

  v_mode          text;
  v_wamid         text;
  v_path          text;
  v_n             int;
  v_nnull         int;
  v_sum           numeric;
  v_dest          numeric;
  v_cur           text;
  v_cur_ok        boolean;
  v_riel          text;
  v_req           numeric;
  v_dep           numeric;
  v_cov           boolean;
BEGIN
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to deliver this operation' USING ERRCODE = '42501';
  END IF;

  IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'evidence must be a JSON object' USING ERRCODE = '22023';
  END IF;

  -- (257) The optional CUP sending card: one of this account's active cards, else refused before anything changes.
  PERFORM cup_validar_tarjeta_origen(v_account_id, p_cup_source_card_id);

  v_mode := p_evidence ->> 'mode';
  IF v_mode IS NULL OR v_mode NOT IN ('proof_sent', 'no_proof', 'skip_proof') THEN
    RAISE EXCEPTION 'evidence mode must be proof_sent, no_proof or skip_proof' USING ERRCODE = '22023';
  END IF;

  IF p_evidence ? 'wamid' AND (p_evidence -> 'wamid') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'wamid') <> 'string' THEN
      RAISE EXCEPTION 'evidence wamid must be a string' USING ERRCODE = '22023';
    END IF;
    v_wamid := p_evidence ->> 'wamid';
    IF v_wamid = '' OR length(v_wamid) > 500 THEN
      RAISE EXCEPTION 'evidence wamid must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_evidence ? 'path' AND (p_evidence -> 'path') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'path') <> 'string' THEN
      RAISE EXCEPTION 'evidence path must be a string' USING ERRCODE = '22023';
    END IF;
    v_path := p_evidence ->> 'path';
    IF v_path = '' OR length(v_path) > 500 THEN
      RAISE EXCEPTION 'evidence path must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- (164) The ordering lock that stood here — a `FOR UPDATE` on the legacy
  -- deal row — was removed with the legacy table. It only serialized
  -- against retired n8n notes/value writes and touched no result.

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  IF NOT crm_beneficiarios_completos(p_operation_id) THEN
    RAISE EXCEPTION 'beneficiary data is incomplete' USING ERRCODE = '22023';
  END IF;

  -- (329) No delivery with unverified money: the operation, or its mixed group as a whole, must be
  -- covered by consumed, unvoided MMG deposits. Over-funding is allowed in phase 1 and stays visible
  -- as a negative balance in cerebro_saldo_operacion.
  SELECT s.requerido, s.depositado, s.cubierto INTO v_req, v_dep, v_cov
    FROM cerebro_fondos_operacion(p_operation_id) s;
  IF coalesce(v_req, 0) <= 0 THEN
    RAISE EXCEPTION 'the operation has no source amount to fund' USING ERRCODE = '22023';
  END IF;
  IF NOT coalesce(v_cov, false) THEN
    RAISE EXCEPTION 'the operation has % GYD of verified funding but needs % GYD: verify the deposit before delivering',
      v_dep, v_req USING ERRCODE = '22023';
  END IF;

  -- (329) EVERY RAIL: the recipients' amounts must add up to what the operation sends. The gate only
  -- applies when every vigente recipient has an amount and all their currencies equal the destination
  -- currency (a null destination only accepts null currencies). Zelle compares whole dollars; the
  -- other rails compare cents. Yoandrys 2026-10-26: a 1,100 USD Zelle was delivered with 800 + 200.
  SELECT o.quoted_destination_amount, o.destination_currency
    INTO v_dest, v_cur
    FROM remittance_operations o WHERE o.id = p_operation_id;
  SELECT count(*),
         count(*) FILTER (WHERE b.amount IS NULL),
         coalesce(sum(b.amount), 0),
         coalesce(bool_and(b.currency IS NOT DISTINCT FROM v_cur), true)
    INTO v_n, v_nnull, v_sum, v_cur_ok
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_operation_id AND b.status = 'vigente';
  v_riel := cerebro_riel_op(p_operation_id);
  IF coalesce(v_dest, 0) > 0 AND v_n > 0 AND v_nnull = 0 AND v_cur_ok THEN
    IF (v_riel = 'zelle' AND round(v_sum) <> round(v_dest))
       OR (v_riel IS DISTINCT FROM 'zelle' AND round(v_sum, 2) <> round(v_dest, 2)) THEN
      RAISE EXCEPTION 'the recipients add up to % % but the operation sends % %: complete them before delivering',
        round(v_sum, 2)::text, coalesce(v_cur, ''), round(v_dest, 2)::text, coalesce(v_cur, '')
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- (143) With proof and 2+ current beneficiaries, every beneficiary needs
  -- its own proof (crm_registrar_prueba_beneficiario) before delivering.
  IF v_mode = 'proof_sent' AND crm_pruebas_faltantes(p_operation_id) > 0 THEN
    RAISE EXCEPTION 'every beneficiary needs its delivery proof before delivering (% missing)',
      crm_pruebas_faltantes(p_operation_id)
      USING ERRCODE = '22023';
  END IF;

  -- (114) One statement: status, evidence, completed_at (the latter set
  -- automatically by trg_remittance_operations_touch, 040) all land in
  -- the same NEW row image the calculator feed trigger reads.
  UPDATE remittance_operations
     SET status = 'completed',
         -- (191) The panel's notify-customer choice, in the row image the notifier reads.
         customer_notice_muted_for = CASE WHEN p_notify THEN NULL ELSE 'completed' END,
         delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid(),
         -- (257) In the SAME statement, so the calculator feed (AFTER UPDATE OF status) sees the chosen card.
         cup_source_card_id = p_cup_source_card_id
   WHERE id = p_operation_id
     AND status = 'ready_to_transfer'
  RETURNING status, completed_at INTO v_status_after, v_completed_at;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer'),
          jsonb_build_object('status', 'completed', 'evidence', p_evidence)
            || CASE WHEN p_cup_source_card_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('cup_source_card_id', p_cup_source_card_id) END);

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_fondos_operacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_fondos_operacion(uuid) TO service_role, authenticated;
