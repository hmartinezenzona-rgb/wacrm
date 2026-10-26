-- =====================================================================
-- 331 -- Deterministic reconciliation (phase 3a of the no-service redesign)
--
-- Phase 2 created the ledger but nothing wrote to it. This migration makes the database reconcile:
--   * funding_reconciliar(conv): opens/gets the case, links every verified customer deposit
--     attributable to the conversation, detects confirmed card-prefix conflicts, and commits the
--     case's GYD to the open operations that have a service, a positive amount and complete data.
--   * The engine runs after a verified cross (cerebro_cruzar_deposito), after a split
--     (_repartir_envio_core) and after a beneficiary insert/update (trigger, only when a case exists).
--   * cerebro_riel_por_prefijo/cerebro_op_conflicto: only 9760 Clasica, 9240 Tropical and 9234 CUP
--     are confirmed; any other prefix is unknown and never conflicts.
--   * A confirmed conflict or a void that leaves the case over-allocated sets it to incident; delivery
--     is blocked until funding_case_resolver clears it.
--   * cerebro_fondos_operacion uses committed allocations for an operation/group that has them, and
--     keeps the linked deposits for a scope without allocations. cerebro_saldo_operacion is unchanged
--     in this phase, so the bot's deposit routing keeps the 329 behaviour.
--
-- Additive to the bot and panel: the engine is called from the existing SQL paths; no Decisor, n8n or
-- panel change. Allocations are append-only in this phase; a target decrease returns pending for an
-- operator to release.
--
-- Assertion: supabase/staging/assertions/funding-reconciliacion.sql.
-- Rollback: ROLLBACK-331-funding-reconciliacion.sql.
-- =====================================================================

ALTER TABLE public.funding_case ADD COLUMN IF NOT EXISTS resolved_by text;
ALTER TABLE public.funding_case ADD COLUMN IF NOT EXISTS resolved_at timestamptz;

CREATE OR REPLACE FUNCTION public.cerebro_riel_por_prefijo(p_card text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  -- Only the confirmed prefixes: 9760 Clasica, 9240 Tropical, 9234 CUP. Any other number is unknown
  -- and never produces a conflict (the table still needs Osmany's confirmation).
  SELECT CASE WHEN digits LIKE '9760%' THEN 'clasica'
              WHEN digits LIKE '9240%' THEN 'tropical'
              WHEN digits LIKE '9234%' THEN 'cuban_card'
         END
    FROM (SELECT regexp_replace(COALESCE(p_card, ''), '[^0-9]', '', 'g') AS digits) t;
$function$;;

CREATE OR REPLACE FUNCTION public.cerebro_op_conflicto(p_op uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT string_agg(DISTINCT
           format('la tarjeta con prefijo %s es %s pero la operación es %s',
                  left(regexp_replace(b.card_number, '[^0-9]', '', 'g'), 4),
                  cerebro_riel_por_prefijo(b.card_number),
                  cerebro_riel_op(p_op)), '; ')
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_op
     AND b.status = 'vigente'
     AND b.card_number IS NOT NULL
     AND cerebro_riel_por_prefijo(b.card_number) IS NOT NULL
     AND cerebro_riel_op(p_op) IS NOT NULL
     AND cerebro_riel_por_prefijo(b.card_number) <> cerebro_riel_op(p_op);
$function$;;

CREATE OR REPLACE FUNCTION public.funding_case_resolver(p_case uuid, p_actor text DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status text;
BEGIN
  IF p_case IS NULL THEN
    RAISE EXCEPTION 'case is required' USING ERRCODE = '22023';
  END IF;

  SELECT status INTO v_status FROM funding_case WHERE id = p_case FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'funding case not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_status = 'incident' THEN
    UPDATE funding_case
       SET status = 'open',
           resolved_by = COALESCE(p_actor, wacrm_current_actor()),
           resolved_at = now()
     WHERE id = p_case;
  END IF;
END $function$;;

CREATE OR REPLACE FUNCTION public.funding_reconciliar(p_conv uuid, p_actor text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_case       uuid;
  v_status     text;
  v_dep        record;
  v_linked     int := 0;
  v_skipped    int := 0;
  v_depositado numeric;
  v_asignado   numeric;
  v_disponible numeric;
  v_conflict   text;
  v_pending    text;
  v_candidates int := 0;
  v_delta_sum  numeric := 0;
  v_delta      numeric;
  v_allocated  int := 0;
  v_op         record;
BEGIN
  IF p_conv IS NULL THEN
    RAISE EXCEPTION 'conversation is required' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('funding_recon:' || p_conv::text, 0));

  SELECT fc.id, fc.status INTO v_case, v_status
    FROM funding_case fc
   WHERE fc.conversation_id = p_conv AND fc.status <> 'closed'
   ORDER BY fc.opened_at DESC
   LIMIT 1;

  IF v_case IS NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM depositos_mmg d
       WHERE d.consumido_en IS NOT NULL AND d.anulado_en IS NULL AND d.descartado_en IS NULL
         AND COALESCE(d.moneda, 'GYD') = 'GYD'
         AND (d.operation_id IN (SELECT o.id FROM remittance_operations o WHERE o.conversation_id = p_conv)
              OR (d.operation_id IS NULL AND EXISTS (
                   SELECT 1 FROM remittance_operation_receipts r
                   JOIN remittance_operations o ON o.id = r.operation_id
                   WHERE o.conversation_id = p_conv
                     AND r.reference ~ ('(^|[^0-9])' || d.trans_id || '([^0-9]|$)'))))
    ) THEN
      RETURN jsonb_build_object('case_id', NULL, 'status', 'no_case', 'linked', 0, 'skipped', 0,
                                'depositado', 0, 'asignado', 0, 'disponible', 0, 'allocated', 0,
                                'candidates', 0, 'pending', NULL, 'conflict', NULL);
    END IF;
    v_case := funding_case_abrir(p_conv, p_actor);
  END IF;

  FOR v_dep IN
    SELECT DISTINCT d.trans_id
      FROM depositos_mmg d
     WHERE d.consumido_en IS NOT NULL AND d.anulado_en IS NULL AND d.descartado_en IS NULL
       AND COALESCE(d.moneda, 'GYD') = 'GYD'
       AND (d.operation_id IN (SELECT o.id FROM remittance_operations o WHERE o.conversation_id = p_conv)
            OR (d.operation_id IS NULL AND EXISTS (
                 SELECT 1 FROM remittance_operation_receipts r
                 JOIN remittance_operations o ON o.id = r.operation_id
                 WHERE o.conversation_id = p_conv
                   AND r.reference ~ ('(^|[^0-9])' || d.trans_id || '([^0-9]|$)'))))
  LOOP
    IF EXISTS (SELECT 1 FROM case_deposits cd
                WHERE cd.deposit_trans_id = v_dep.trans_id AND cd.case_id <> v_case) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM case_deposits cd
                    WHERE cd.deposit_trans_id = v_dep.trans_id AND cd.case_id = v_case) THEN
      PERFORM funding_deposito_vincular(v_case, v_dep.trans_id, p_actor);
      v_linked := v_linked + 1;
    END IF;
  END LOOP;

  SELECT fc.status INTO v_status FROM funding_case fc WHERE fc.id = v_case;
  IF v_status = 'closed' THEN
    RETURN jsonb_build_object('case_id', v_case, 'status', 'closed', 'linked', v_linked, 'skipped', v_skipped,
                              'depositado', 0, 'asignado', 0, 'disponible', 0, 'allocated', 0,
                              'candidates', 0, 'pending', NULL, 'conflict', NULL);
  END IF;

  -- Every open operation of the conversation belongs to its active case, even before an allocation.
  UPDATE remittance_operations
     SET case_id = v_case
   WHERE conversation_id = p_conv
     AND status NOT IN ('completed', 'cancelled')
     AND case_id IS NULL;

  SELECT depositado, asignado, disponible INTO v_depositado, v_asignado, v_disponible
    FROM funding_case_saldo(v_case) s;

  IF v_disponible < 0 THEN
    UPDATE funding_case
       SET status = 'incident', note = 'el caso quedó sobre-asignado: ' || v_disponible || ' GYD'
     WHERE id = v_case AND status <> 'closed';
    RETURN jsonb_build_object('case_id', v_case, 'status', 'incident', 'linked', v_linked, 'skipped', v_skipped,
                              'depositado', v_depositado, 'asignado', v_asignado, 'disponible', v_disponible,
                              'allocated', 0, 'candidates', 0, 'pending', NULL,
                              'conflict', 'el caso quedó sobre-asignado');
  END IF;

  SELECT string_agg(DISTINCT cerebro_op_conflicto(o.id), '; ')
    INTO v_conflict
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv
     AND o.status NOT IN ('completed', 'cancelled')
     AND cerebro_op_conflicto(o.id) IS NOT NULL;

  IF v_conflict IS NOT NULL THEN
    UPDATE funding_case
       SET status = 'incident', note = 'conflicto: ' || v_conflict
     WHERE id = v_case AND status <> 'closed';
    RETURN jsonb_build_object('case_id', v_case, 'status', 'incident', 'linked', v_linked, 'skipped', v_skipped,
                              'depositado', v_depositado, 'asignado', v_asignado, 'disponible', v_disponible,
                              'allocated', 0, 'candidates', 0, 'pending', NULL, 'conflict', v_conflict);
  END IF;

  IF v_status = 'incident' THEN
    RETURN jsonb_build_object('case_id', v_case, 'status', 'incident', 'linked', v_linked, 'skipped', v_skipped,
                              'depositado', v_depositado, 'asignado', v_asignado, 'disponible', v_disponible,
                              'allocated', 0, 'candidates', 0, 'pending', NULL,
                              'conflict', (SELECT note FROM funding_case WHERE id = v_case));
  END IF;

  v_delta_sum := 0;
  v_pending := NULL;
  FOR v_op IN
    SELECT o.id, o.quoted_source_amount AS target,
           COALESCE((SELECT sum(a.amount_gyd) FROM funding_allocations a
                      WHERE a.operation_id = o.id AND a.status = 'committed'), 0) AS current
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv
       AND o.status NOT IN ('completed', 'cancelled', 'incident')
       AND o.quoted_source_amount > 0
       AND (o.case_id IS NULL OR o.case_id = v_case)
       AND cerebro_riel_op(o.id) IS NOT NULL
       AND crm_beneficiarios_completos(o.id)
     ORDER BY o.created_at, o.id
  LOOP
    v_candidates := v_candidates + 1;
    v_delta := v_op.target - v_op.current;
    IF v_delta < 0 THEN
      v_pending := 'la operación ' || v_op.id || ' tiene más asignado que su objetivo; revisar antes de reasignar';
      v_delta_sum := NULL;
      EXIT;
    END IF;
    v_delta_sum := v_delta_sum + v_delta;
  END LOOP;

  IF v_delta_sum IS NULL THEN
    RETURN jsonb_build_object('case_id', v_case, 'status', (SELECT status FROM funding_case WHERE id = v_case),
                              'linked', v_linked, 'skipped', v_skipped, 'depositado', v_depositado,
                              'asignado', v_asignado, 'disponible', v_disponible, 'allocated', 0,
                              'candidates', v_candidates, 'pending', v_pending, 'conflict', NULL);
  END IF;

  IF v_delta_sum > v_disponible THEN
    RETURN jsonb_build_object('case_id', v_case, 'status', (SELECT status FROM funding_case WHERE id = v_case),
                              'linked', v_linked, 'skipped', v_skipped, 'depositado', v_depositado,
                              'asignado', v_asignado, 'disponible', v_disponible, 'allocated', 0,
                              'candidates', v_candidates,
                              'pending', 'las partes necesitan ' || v_delta_sum || ' GYD pero solo hay ' || v_disponible || ' GYD',
                              'conflict', NULL);
  END IF;

  FOR v_op IN
    SELECT o.id, o.quoted_source_amount AS target,
           COALESCE((SELECT sum(a.amount_gyd) FROM funding_allocations a
                      WHERE a.operation_id = o.id AND a.status = 'committed'), 0) AS current
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv
       AND o.status NOT IN ('completed', 'cancelled', 'incident')
       AND o.quoted_source_amount > 0
       AND (o.case_id IS NULL OR o.case_id = v_case)
       AND cerebro_riel_op(o.id) IS NOT NULL
       AND crm_beneficiarios_completos(o.id)
     ORDER BY o.created_at, o.id
  LOOP
    v_delta := v_op.target - v_op.current;
    IF v_delta > 0 THEN
      BEGIN
        PERFORM funding_asignar(v_case, v_op.id, v_delta, 'data',
          'recon:' || v_case::text || ':' || v_op.id::text || ':' || v_op.current::text || ':' || v_op.target::text,
          p_actor);
        v_allocated := v_allocated + 1;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'funding_reconciliar: allocation failed for operation %: %', v_op.id, SQLERRM;
        v_pending := COALESCE(v_pending || '; ', '') || 'no se pudo asignar una parte';
      END;
    END IF;
  END LOOP;

  SELECT depositado, asignado, disponible INTO v_depositado, v_asignado, v_disponible
    FROM funding_case_saldo(v_case) s;

  IF v_asignado > 0 THEN
    UPDATE funding_case SET status = 'allocating' WHERE id = v_case AND status = 'open';
  END IF;

  RETURN jsonb_build_object('case_id', v_case, 'status', (SELECT status FROM funding_case WHERE id = v_case),
                            'linked', v_linked, 'skipped', v_skipped, 'depositado', v_depositado,
                            'asignado', v_asignado, 'disponible', v_disponible, 'allocated', v_allocated,
                            'candidates', v_candidates, 'pending', v_pending, 'conflict', NULL);
END $function$;;

CREATE OR REPLACE FUNCTION public.funding_reconciliar_beneficiario()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_conv uuid;
BEGIN
  SELECT o.conversation_id INTO v_conv
    FROM remittance_operations o
   WHERE o.id = NEW.operation_id;
  IF v_conv IS NULL THEN
    RETURN NULL;
  END IF;
  -- Only conversations that already have an active case: the case is created by the verified deposit.
  IF NOT EXISTS (SELECT 1 FROM funding_case fc
                  WHERE fc.conversation_id = v_conv AND fc.status <> 'closed') THEN
    RETURN NULL;
  END IF;
  BEGIN
    PERFORM funding_reconciliar(v_conv, 'automation:beneficiario');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'funding_reconciliar (beneficiary %) failed for conversation %: %', NEW.id, v_conv, SQLERRM;
  END;
  RETURN NULL;
END $function$;;

DROP TRIGGER IF EXISTS funding_reconciliar_beneficiario_trg ON public.remittance_beneficiaries;
CREATE TRIGGER funding_reconciliar_beneficiario_trg
AFTER INSERT OR UPDATE OF status, amount, card_number, phone, zelle_account, clabe, beneficiary_type
ON public.remittance_beneficiaries
FOR EACH ROW EXECUTE FUNCTION public.funding_reconciliar_beneficiario();

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
    SELECT m.id, m.quoted_source_amount, m.case_id
      FROM base b
      JOIN remittance_operations m
        ON (b.mixed_group_id IS NOT NULL AND m.mixed_group_id = b.mixed_group_id AND m.status <> 'cancelled')
        OR (b.mixed_group_id IS NULL AND m.id = b.id)
  ),
  depositos AS (
    -- Verification evidence for a case with no allocations yet: linked deposits plus unlinked deposits
    -- whose TransID appears in a receipt of a member (the admin typed-TransID path).
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
  ),
  scope_case AS (
    SELECT m.case_id
      FROM miembros m
     WHERE m.case_id IS NOT NULL
     ORDER BY m.case_id
     LIMIT 1
  ),
  caso AS (
    SELECT fc.status FROM funding_case fc WHERE fc.id = (SELECT case_id FROM scope_case)
  ),
  member_alloc AS (
    SELECT COALESCE(sum(a.amount_gyd), 0) AS total
      FROM funding_allocations a
     WHERE a.status = 'committed' AND a.operation_id IN (SELECT id FROM miembros)
  ),
  linked AS (SELECT COALESCE(sum(monto), 0) AS total FROM depositos),
  req AS (SELECT COALESCE(sum(quoted_source_amount), 0) AS total FROM miembros),
  evidence AS (
    -- A scope with its own committed allocations uses them; a scope without allocations keeps the
    -- linked deposits (the 329 behaviour). This keeps cerebro_saldo_operacion and the bot's routing
    -- unchanged while the engine fills the case.
    SELECT CASE WHEN (SELECT total FROM member_alloc) > 0
                THEN (SELECT total FROM member_alloc)
                ELSE (SELECT total FROM linked) END AS total
  )
  SELECT (SELECT total FROM req),
         (SELECT total FROM evidence),
         ((SELECT total FROM req) > 0
          AND (SELECT total FROM evidence) >= (SELECT total FROM req)
          AND NOT EXISTS (SELECT 1 FROM caso WHERE status = 'incident'));
$function$;;

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

  -- (331) A case in incident blocks delivery: a confirmed card-prefix conflict or an over-allocated
  -- case after a void. An operator resolves it with funding_case_resolver. The case is found through
  -- the conversation because an operation may still have case_id NULL (no allocation yet).
  IF EXISTS (SELECT 1 FROM funding_case fc
              WHERE fc.status = 'incident'
                AND fc.conversation_id = (SELECT o.conversation_id
                                            FROM remittance_operations o
                                           WHERE o.id = p_operation_id)) THEN
    RAISE EXCEPTION 'the funding case has a conflict: %',
      COALESCE((SELECT fc.note FROM funding_case fc
                 WHERE fc.status = 'incident'
                   AND fc.conversation_id = (SELECT o.conversation_id
                                               FROM remittance_operations o
                                              WHERE o.id = p_operation_id)
                 ORDER BY fc.opened_at DESC LIMIT 1), 'resolve it before delivering')
      USING ERRCODE = '22023';
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

CREATE OR REPLACE FUNCTION public._repartir_envio_core(p_operation_id uuid, p_partes jsonb, p_audit_action text, p_actor text, p_reason text, p_parcial boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_services   constant text[] := ARRAY['cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo', 'mexico'];
  v_op         remittance_operations%ROWTYPE;
  v_anchor     remittance_operations%ROWTYPE;
  v_anchor_id  uuid;
  v_anchor_key text;
  v_el         jsonb;
  v_keys       text[] := ARRAY[]::text[];
  v_amts       numeric[] := ARRAY[]::numeric[];
  v_total      numeric;
  v_sum        numeric := 0;
  v_member     record;
  v_i          integer;
  v_key        text;
  v_target     uuid;
  v_created    boolean;
  v_type       text;
  v_dm         text;
  v_before     remittance_operations%ROWTYPE;
  v_after      remittance_operations%ROWTYPE;
  v_ids        uuid[] := ARRAY[]::uuid[];
  v_new        boolean[] := ARRAY[]::boolean[];
  v_obj        numeric;
  v_dep        numeric;
  v_saldo      numeric;
  v_partes     jsonb := '[]'::jsonb;
  v_dep0       numeric;
  v_min        numeric;
  v_single     boolean := false;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  -- The anchor is the group's anchor when the operation is already a member, else the operation itself.
  v_anchor_id := COALESCE(v_op.mixed_group_id, v_op.id);
  SELECT * INTO v_anchor FROM remittance_operations WHERE id = v_anchor_id FOR UPDATE;
  PERFORM 1 FROM remittance_operations WHERE mixed_group_id = v_anchor_id ORDER BY id FOR UPDATE;

  IF v_anchor.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  -- Parts: an array of at least two {servicio, monto_gyd}, distinct services, positive amounts.
  IF p_partes IS NULL OR jsonb_typeof(p_partes) <> 'array' OR jsonb_array_length(p_partes) < (2 - p_parcial::int) THEN
    RAISE EXCEPTION 'at least two parts are required' USING ERRCODE = '22023';
  END IF;
  FOR v_el IN SELECT * FROM jsonb_array_elements(p_partes) LOOP
    IF jsonb_typeof(v_el) <> 'object' OR jsonb_typeof(v_el -> 'servicio') <> 'string'
       OR jsonb_typeof(v_el -> 'monto_gyd') <> 'number' THEN
      RAISE EXCEPTION 'each part needs a servicio (text) and a monto_gyd (number)' USING ERRCODE = '22023';
    END IF;
    v_key := lower(btrim(v_el ->> 'servicio'));
    IF NOT (v_key = ANY (v_services)) THEN
      RAISE EXCEPTION 'unknown service: %', v_el ->> 'servicio' USING ERRCODE = '22023';
    END IF;
    IF v_key = ANY (v_keys) THEN
      RAISE EXCEPTION 'service % appears more than once', v_key USING ERRCODE = '22023';
    END IF;
    IF (v_el ->> 'monto_gyd')::numeric <= 0 THEN
      RAISE EXCEPTION 'every part must be greater than 0' USING ERRCODE = '22023';
    END IF;
    v_keys := v_keys || v_key;
    v_amts := v_amts || (v_el ->> 'monto_gyd')::numeric;
    v_sum  := v_sum + (v_el ->> 'monto_gyd')::numeric;
  END LOOP;

  -- The money being split: the group's total (non-cancelled members), or the lone operation's own amount.
  IF v_op.mixed_group_id IS NOT NULL THEN
    SELECT sum(quoted_source_amount) INTO v_total
      FROM remittance_operations WHERE mixed_group_id = v_anchor_id AND status <> 'cancelled';
  ELSE
    v_total := v_anchor.quoted_source_amount;
  END IF;
  IF p_parcial THEN
    -- (280) Partial deposit: the parts are the ones to apply now. They must fit inside the verified deposit; the rest of the plan stays pending.
    SELECT s.depositado INTO v_dep0 FROM cerebro_saldo_operacion(v_anchor_id) s;
    IF COALESCE(v_dep0, 0) <= 0 THEN
      RAISE EXCEPTION 'there is no verified deposit to cover the parts' USING ERRCODE = '22023';
    END IF;
    IF v_sum > v_dep0 THEN
      RAISE EXCEPTION 'the parts add up to % but the verified deposit is only %', v_sum, v_dep0 USING ERRCODE = '22023';
    END IF;
    v_single := array_length(v_keys, 1) = 1;
  ELSE
    IF v_total IS NULL OR v_total <= 0 THEN
      RAISE EXCEPTION 'there is no money to split: the total is %', COALESCE(v_total::text, 'empty') USING ERRCODE = '22023';
    END IF;
    IF v_sum <> v_total THEN
      RAISE EXCEPTION 'the parts add up to % but the total to split is %', v_sum, v_total USING ERRCODE = '22023';
    END IF;
  END IF;

  -- The anchor's own service must be one of the parts.
  v_anchor_key := cerebro_riel_op(v_anchor_id);
  IF v_anchor_key IS NULL OR NOT (v_anchor_key = ANY (v_keys)) THEN
    RAISE EXCEPTION 'the operation''s own service (%) must be one of the parts', COALESCE(v_anchor_key, 'unknown') USING ERRCODE = '22023';
  END IF;

  -- Every open member of the group needs its part; a completed member cannot be re-priced.
  FOR v_member IN SELECT id, status FROM remittance_operations
                   WHERE mixed_group_id = v_anchor_id AND status <> 'cancelled' LOOP
    IF v_member.status = 'completed' THEN
      RAISE EXCEPTION 'group member % is completed and cannot be re-split', v_member.id USING ERRCODE = '22023';
    END IF;
    IF NOT (COALESCE(cerebro_riel_op(v_member.id), '') = ANY (v_keys)) THEN
      RAISE EXCEPTION 'group member % (service %) has no part', v_member.id, cerebro_riel_op(v_member.id) USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF (SELECT count(*) - count(DISTINCT cerebro_riel_op(id)) FROM remittance_operations
       WHERE mixed_group_id = v_anchor_id AND status <> 'cancelled') > 0 THEN
    RAISE EXCEPTION 'two group members share one service' USING ERRCODE = '22023';
  END IF;

  FOR v_i IN 1 .. array_length(v_keys, 1) LOOP
    v_key := v_keys[v_i];
    v_created := false;

    IF v_key = v_anchor_key THEN
      v_target := v_anchor_id;
    ELSE
      -- An open operation of that service in the conversation, not in another group: the group's own first, then the newest.
      -- An ungrouped one that already holds money of its own (a deposit or a receipt) is never reused: its money would
      -- join the group and be re-priced. A fresh operation is created instead.
      SELECT o.id INTO v_target
        FROM remittance_operations o
       WHERE o.conversation_id = v_anchor.conversation_id
         AND o.status NOT IN ('completed', 'cancelled')
         AND (o.mixed_group_id = v_anchor_id
              OR (o.mixed_group_id IS NULL
                  AND NOT EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.anulado_en IS NULL)
                  AND NOT EXISTS (SELECT 1 FROM remittance_operation_receipts rr WHERE rr.operation_id = o.id)))
         AND cerebro_riel_op(o.id) = v_key
       ORDER BY (o.mixed_group_id IS NOT NULL) DESC, o.created_at DESC
       LIMIT 1
       FOR UPDATE;

      IF v_target IS NULL THEN
        -- Same mapping as _cambiar_servicio_core; the destination amount and currency come from the calculation.
        v_type := CASE WHEN v_key IN ('recarga', 'combo', 'visa', 'saldo', 'mexico') THEN v_key ELSE 'remesa' END;
        v_dm   := CASE WHEN v_type = 'remesa' THEN v_key END;
        INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                           deposit_method, source_country, source_currency, destination_currency)
        VALUES (v_anchor.account_id, v_anchor.conversation_id, v_anchor.contact_id, 'collecting_information', v_type, v_dm,
                v_anchor.deposit_method, v_anchor.source_country, v_anchor.source_currency,
                CASE WHEN v_type = 'mexico' THEN 'MXN' END)
        RETURNING id INTO v_target;
        v_created := true;
      END IF;
    END IF;

    SELECT * INTO v_before FROM remittance_operations WHERE id = v_target;

    -- (280) every part sent in a partial application must reach the minimum of its service.
    IF p_parcial THEN
      v_min := cerebro_minimo_gyd(v_target);
      IF v_min IS NOT NULL AND v_amts[v_i] < v_min THEN
        RAISE EXCEPTION 'part % (%) is below its minimum of %', v_key, v_amts[v_i], v_min USING ERRCODE = '22023';
      END IF;
    END IF;

    -- The share is written by a human, so the 096 guard locks quoted_source_amount; the explicit lock covers an
    -- unchanged amount. The remesa recalculation then writes the destination as a human too: release those locks unless
    -- an earlier correction had set them.
    UPDATE remittance_operations
       SET quoted_source_amount = v_amts[v_i],
           mixed_group_id = CASE WHEN v_single THEN v_op.mixed_group_id ELSE v_anchor_id END,
           admin_locked_fields = COALESCE(admin_locked_fields, '{}'::jsonb)
             || jsonb_build_object('quoted_source_amount', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
     WHERE id = v_target;

    UPDATE remittance_operations
       SET admin_locked_fields = admin_locked_fields
             - CASE WHEN v_before.admin_locked_fields ? 'quoted_destination_amount' THEN '' ELSE 'quoted_destination_amount' END
             - CASE WHEN v_before.admin_locked_fields ? 'destination_currency' THEN '' ELSE 'destination_currency' END
     WHERE id = v_target
       AND admin_locked_fields ?| ARRAY['quoted_destination_amount', 'destination_currency'];

    SELECT * INTO v_after FROM remittance_operations WHERE id = v_target;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_after.account_id, 'remittance_operations', v_target, 'mixed_split', p_audit_action,
            p_actor, p_reason,
            jsonb_build_object('quoted_source_amount', v_before.quoted_source_amount, 'mixed_group_id', v_before.mixed_group_id),
            jsonb_build_object('quoted_source_amount', v_after.quoted_source_amount, 'mixed_group_id', v_after.mixed_group_id,
                               'service', v_key, 'created', v_created));

    v_ids := v_ids || v_target;
    v_new := v_new || v_created;
  END LOOP;

  -- A fully deposited group is ready: every open member, with its objective closed.
  SELECT s.objetivo, s.depositado, s.saldo INTO v_obj, v_dep, v_saldo FROM cerebro_saldo_operacion(v_anchor_id) s;
  IF v_dep > 0 AND v_saldo = 0 THEN
    UPDATE remittance_operations
       SET status = 'ready_to_transfer', incident_reason = NULL, updated_at = now()
     WHERE mixed_group_id = v_anchor_id
       AND status IN ('incident', 'collecting_information', 'deposit_verification');
    FOR v_member IN SELECT id FROM remittance_operations WHERE mixed_group_id = v_anchor_id LOOP
      PERFORM cerebro_objetivo_cerrar_op(v_member.id);
    END LOOP;
  END IF;

  FOR v_i IN 1 .. array_length(v_ids, 1) LOOP
    SELECT * INTO v_after FROM remittance_operations WHERE id = v_ids[v_i];
    v_partes := v_partes || jsonb_build_object('operation_id', v_ids[v_i], 'servicio', v_keys[v_i], 'monto_gyd', v_amts[v_i],
                                                'creada', v_new[v_i], 'status', v_after.status);
  END LOOP;

  -- (331) The split is the instruction: the engine assigns the parts against the funding case.
  BEGIN
    PERFORM funding_reconciliar(v_anchor.conversation_id, 'automation:reparto');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'funding_reconciliar failed after split for conversation %: %', v_anchor.conversation_id, SQLERRM;
  END;

  RETURN jsonb_build_object('grupo', v_anchor_id, 'depositado', v_dep, 'saldo', v_saldo, 'partes', v_partes,
                            'parcial', p_parcial, 'asignado', v_sum,
                            'deposito_verificado', v_dep0,
                            'sobrante', CASE WHEN p_parcial THEN v_dep0 - v_sum END);
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_cruzar_deposito(p_deal uuid, p_ref text, p_monto numeric, p_stage_ok uuid, p_stage_incidencia uuid, p_stage_esperado uuid, p_simular boolean DEFAULT false)
 RETURNS TABLE(resultado text, trans_id text, deal_actualizado integer, metodo text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ref        text;
  v_aplica     boolean;
  v_res        text;
  v_trans      text;
  v_recibido   timestamptz;
  v_metodo     text := 'exacto';
  v_nota       text;
  v_stage      uuid;
  v_tocados    int  := 0;
  v_horas      int;
  v_maxhoras   int;
  v_candidatos int := 0;
  v_conv       uuid;
  v_phone      text;
  v_op_id      uuid;
BEGIN
  -- (160) Resolve either flavour of id to an operation id.
  v_op_id := cerebro_resolve_op_id(p_deal);

  v_ref := NULLIF(regexp_replace(COALESCE(p_ref, ''), '[^0-9]', '', 'g'), '');

  -- (311) An admin verification has no operation (the registrar wrapper
  -- returns a NULL deal on purpose): the cross must still run and consume
  -- the deposit with operation_id NULL. With an operation, the old gate stays.
  IF v_op_id IS NULL THEN
    v_aplica := true;
  ELSE
    SELECT COALESCE(
             (SELECT ro.status FROM remittance_operations ro WHERE ro.id = v_op_id)
               = cerebro_estado_desde_etapa(p_stage_esperado),
             false)
      INTO v_aplica;
  END IF;

  IF NOT v_aplica THEN
    RETURN QUERY SELECT 'no_aplica'::text, v_ref, 0, 'ninguno'::text; RETURN;
  END IF;

  IF v_ref IS NULL THEN
    RETURN QUERY SELECT 'sin_referencia'::text, v_ref, 0, 'ninguno'::text; RETURN;
  END IF;

  v_maxhoras := COALESCE(NULLIF(cerebro_config_get('cruce_antiguedad_max_horas'), '')::int, 72);

  SELECT d.trans_id, d.recibido_en INTO v_trans, v_recibido
    FROM depositos_mmg d
   WHERE d.trans_id = v_ref AND d.consumido_en IS NULL AND d.monto = p_monto
     AND d.anulado_en IS NULL
   FOR UPDATE;

  IF v_trans IS NOT NULL AND v_recibido < now() - make_interval(hours => v_maxhoras) THEN
    v_res    := 'deposito_antiguo';
    v_metodo := 'antiguo';
  ELSIF v_trans IS NOT NULL THEN
    IF NOT p_simular THEN
      -- (160) Compatibility shim: mirror the legacy deal_id onto
      -- depositos_mmg so the 159 reader's WHERE deal_id = v_deal_id
      -- query continues to resolve consumed deposits. When the
      -- resolved operation has deal_id IS NULL we leave it untouched.
      UPDATE depositos_mmg d
         SET consumido_en = now(), operation_id = v_op_id,
             deal_id = COALESCE(deal_id, (SELECT deal_id FROM remittance_operations WHERE id = v_op_id))
       WHERE d.trans_id = v_trans AND d.consumido_en IS NULL;
    END IF;
    v_res := 'verificado';
  ELSIF EXISTS (SELECT 1 FROM depositos_mmg x
                 WHERE x.trans_id = v_ref AND x.anulado_en IS NOT NULL) THEN
    v_res := 'deposito_anulado';
  ELSIF EXISTS (SELECT 1 FROM depositos_mmg x
                 WHERE x.trans_id = v_ref AND x.consumido_en IS NOT NULL) THEN
    v_res := 'ya_reclamado';
  ELSIF EXISTS (SELECT 1 FROM depositos_mmg x WHERE x.trans_id = v_ref) THEN
    v_res := 'monto_no_coincide';
  ELSE
    v_res := 'sin_correo';
  END IF;

  IF v_res = 'sin_correo' THEN
    v_horas := COALESCE(NULLIF(cerebro_config_get('cruce_ventana_horas'), '')::int, 6);

    SELECT count(*) INTO v_candidatos
      FROM depositos_mmg m
     WHERE m.consumido_en IS NULL
       AND m.anulado_en IS NULL
       AND m.monto        = p_monto
       AND m.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                             AND now() + interval '15 minutes'
       -- (197) was: same length, first 5 and last 4 digits
       AND cerebro_ref_parecida(v_ref, m.trans_id);

    IF v_candidatos = 1 THEN
      IF p_simular THEN
        SELECT m.trans_id INTO v_trans
          FROM depositos_mmg m
         WHERE m.consumido_en IS NULL AND m.anulado_en IS NULL AND m.monto = p_monto
           AND m.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                                 AND now() + interval '15 minutes'
           -- (197) was: same length, first 5 and last 4 digits
       AND cerebro_ref_parecida(v_ref, m.trans_id);
      ELSE
        UPDATE depositos_mmg m
           SET consumido_en = now(), operation_id = v_op_id,
               deal_id = COALESCE(deal_id, (SELECT deal_id FROM remittance_operations WHERE id = v_op_id))
         WHERE m.trans_id = (
                 SELECT x.trans_id FROM depositos_mmg x
                  WHERE x.consumido_en IS NULL
                    AND x.anulado_en IS NULL
                    AND x.monto = p_monto
                    AND x.recibido_en BETWEEN now() - make_interval(hours => v_horas)
                                          AND now() + interval '15 minutes'
                    -- (197) was: same length, first 5 and last 4 digits
       AND cerebro_ref_parecida(v_ref, x.trans_id)
                  LIMIT 1 FOR UPDATE SKIP LOCKED)
        RETURNING m.trans_id INTO v_trans;
      END IF;

      IF v_trans IS NOT NULL THEN
        v_res := 'verificado'; v_metodo := 'aproximado';
      END IF;
    ELSIF v_candidatos > 1 THEN
      v_metodo := 'ambiguo';
    END IF;
  END IF;

  IF v_res IN ('verificado','ya_reclamado','monto_no_coincide','deposito_antiguo','deposito_anulado') THEN
    v_stage := CASE WHEN v_res = 'verificado' THEN p_stage_ok ELSE p_stage_incidencia END;

    v_nota := CASE
      WHEN v_res = 'verificado' AND v_metodo = 'aproximado' THEN
        'VERIFICADO: casa con el correo de MMG (TransID ' || v_trans || ') '
        || '- COINCIDENCIA APROXIMADA: el comprobante decia ' || v_ref
        || '. Coinciden importe y hora, la referencia difiere en 2 digitos o menos, y era el unico'
        || ' candidato posible. CONFIRMAR VISUALMENTE el comprobante.'
      WHEN v_res = 'verificado' THEN
        'VERIFICADO: casa con el correo de MMG (TransID ' || v_ref || ')'
      WHEN v_res = 'deposito_anulado' THEN
        'SIN VERIFICAR - DEPOSITO ANULADO: el TransID ' || v_ref || ' figura como'
        || ' ANULADO en el libro de MMG. NO se ha dado por bueno. Motivo registrado: '
        || COALESCE((SELECT x.motivo_anulacion FROM depositos_mmg x WHERE x.trans_id = v_ref LIMIT 1), 'sin motivo')
      WHEN v_res = 'deposito_antiguo' THEN
        'SIN VERIFICAR - DEPOSITO ANTIGUO: el TransID ' || v_ref || ' si existe y el'
        || ' importe cuadra, pero el deposito se recibio el '
        || to_char(v_recibido AT TIME ZONE 'America/Guyana', 'DD/MM/YYYY HH24:MI')
        || ' (hace ' || floor(EXTRACT(epoch FROM (now() - v_recibido))/3600)::int || ' horas).'
        || ' NO se ha dado por bueno ni se ha consumido. Compruebe que esta remesa no'
        || ' se pago ya por otra via antes de transferir.'
      WHEN v_res = 'ya_reclamado' THEN
        'ALERTA: el TransID ' || v_ref || ' ya fue usado en otro envio'
      ELSE
        'ALERTA: el TransID ' || v_ref || ' existe en MMG pero el monto no coincide'
    END;

    IF NOT p_simular THEN
      -- (160) Compatibility shim: write deal_id on depositos_mmg so the
      -- 159 reader's WHERE deal_id = v_deal_id still resolves consumed
      -- deposits for legacy operations.
      UPDATE remittance_operations
         SET status = cerebro_estado_desde_etapa(v_stage),
             incident_reason = CASE WHEN cerebro_estado_desde_etapa(v_stage) = 'incident'
                                    THEN v_nota ELSE NULL END,
             updated_at = now()
       WHERE id = v_op_id;
      GET DIAGNOSTICS v_tocados = ROW_COUNT;
    ELSE
      v_tocados := 1;
    END IF;
  END IF;

  -- (331) A verified deposit enters the funding case; the engine links it and allocates the parts.
  IF NOT p_simular AND v_res = 'verificado' AND v_op_id IS NOT NULL THEN
    SELECT o.conversation_id INTO v_conv FROM remittance_operations o WHERE o.id = v_op_id;
    IF v_conv IS NOT NULL THEN
      BEGIN
        PERFORM funding_reconciliar(v_conv, 'automation:cruce_deposito');
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'funding_reconciliar failed for conversation %: %', v_conv, SQLERRM;
      END;
    END IF;
  END IF;

  IF NOT p_simular AND v_metodo IN ('aproximado','ambiguo') THEN
    SELECT o.conversation_id INTO v_conv FROM remittance_operations o WHERE o.id = v_op_id;
    SELECT c.phone INTO v_phone FROM conversations v JOIN contacts c ON c.id = v.contact_id
     WHERE v.id = v_conv;

    PERFORM net.http_post(
      url     := cerebro_config_get('notify_url'),
      body    := jsonb_build_object('type','CRUCE_APROXIMADO','metodo',v_metodo,
                   'cliente_phone',COALESCE(v_phone,'?'),'monto',p_monto,
                   'ref_leida',v_ref,'ref_hallada',v_trans,'candidatos',v_candidatos),
      headers := jsonb_build_object('Content-Type','application/json',
                   'X-Cerebro-Secret', cerebro_config_get('notify_secret')));
  END IF;

  RETURN QUERY SELECT v_res, COALESCE(v_trans, v_ref), v_tocados, v_metodo;
END;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_riel_por_prefijo(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_op_conflicto(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.funding_reconciliar(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.funding_case_resolver(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.funding_reconciliar_beneficiario() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.cerebro_riel_por_prefijo(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_op_conflicto(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.funding_reconciliar(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.funding_case_resolver(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.funding_reconciliar_beneficiario() TO service_role;

COMMENT ON FUNCTION public.funding_reconciliar(uuid, text) IS
  '331: links the conversation verified deposits to its case and commits GYD to the open operations '
  'with a service, a positive amount and complete data. Conflicts and over-allocation set the case '
  'incident. Append-only allocations in phase 3a.';
COMMENT ON FUNCTION public.cerebro_riel_por_prefijo(text) IS
  '331: maps the confirmed card prefixes to a rail: 9760 Clasica, 9240 Tropical, 9234 CUP. Unknown '
  'prefixes return NULL and never produce a conflict.';
COMMENT ON FUNCTION public.cerebro_op_conflicto(uuid) IS
  '331: a human-readable conflict when a vigente beneficiary card carries a confirmed prefix that '
  'belongs to a different rail than the operation.';
COMMENT ON FUNCTION public.funding_case_resolver(uuid, text) IS
  '331: clears an incident after the operator fixes the data; the next reconciliation re-evaluates.';
