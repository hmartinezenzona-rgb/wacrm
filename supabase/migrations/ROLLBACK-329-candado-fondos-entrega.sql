-- ROLLBACK of 329: restores cerebro_saldo_operacion and crm_entregar_operacion exactly as read from
-- staging (pg_get_functiondef, 2026-10-26) and drops the helper.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.cerebro_saldo_operacion(p_op uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH dep AS (
    SELECT COALESCE(sum(m.monto), 0) AS total
      FROM depositos_mmg m
     WHERE m.operation_id = p_op
       AND m.consumido_en IS NOT NULL
       AND m.anulado_en  IS NULL
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
  ),
  gdep AS (
    SELECT COALESCE(sum(m.monto), 0) AS total
      FROM depositos_mmg m
     WHERE m.operation_id IN (SELECT ro.id FROM remittance_operations ro
                               WHERE ro.mixed_group_id = (SELECT g FROM grp))
       AND m.consumido_en IS NOT NULL
       AND m.anulado_en  IS NULL
  )
  SELECT CASE WHEN (SELECT g FROM grp) IS NULL THEN (SELECT monto FROM obj) ELSE (SELECT monto FROM gobj) END,
         CASE WHEN (SELECT g FROM grp) IS NULL THEN (SELECT total FROM dep) ELSE (SELECT total FROM gdep) END,
         CASE WHEN (SELECT g FROM grp) IS NULL
              THEN (SELECT monto FROM obj) - (SELECT total FROM dep)
              ELSE (SELECT monto FROM gobj) - (SELECT total FROM gdep) END,
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
  v_zn            int;
  v_znull         int;
  v_zsum          numeric;
  v_zdest         numeric;
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

  -- (328) ZELLE: the recipients' amounts must add up to what the operation sends. This gate only
  -- applies when every vigente Zelle recipient has an amount (the per-recipient amount is optional)
  -- and compares whole dollars, because Zelle delivers whole dollars. Yoandrys 2026-10-26: a 1,100 USD
  -- Zelle was delivered with 800 + 200 recipients, leaving 100 USD unassigned in the record.
  IF cerebro_riel_op(p_operation_id) = 'zelle' THEN
    SELECT o.quoted_destination_amount INTO v_zdest
      FROM remittance_operations o WHERE o.id = p_operation_id;
    SELECT count(*),
           count(*) FILTER (WHERE b.amount IS NULL),
           coalesce(sum(b.amount), 0)
      INTO v_zn, v_znull, v_zsum
      FROM remittance_beneficiaries b
     WHERE b.operation_id = p_operation_id AND b.status = 'vigente' AND b.beneficiary_type = 'zelle';
    IF coalesce(v_zdest, 0) > 0 AND v_zn > 0 AND v_znull = 0
       AND round(v_zsum) <> round(v_zdest) THEN
      RAISE EXCEPTION 'zelle recipients add up to % USD but the operation sends % USD: complete the recipients before delivering',
        round(v_zsum)::text, round(v_zdest)::text USING ERRCODE = '22023';
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

DROP FUNCTION IF EXISTS public.cerebro_fondos_operacion(uuid);
