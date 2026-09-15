-- =====================================================================
-- 102 — Operations history rows + beneficiary-completeness delivery gate
--
-- PURPOSE: two related product rules for the operations panel.
--
--   A. The panel keeps completed remittances as read-only history of the
--      client: `crm_operaciones_de_conversacion` now surfaces, alongside
--      the current open (non-terminal) remesa operations it already
--      returns, the 10 most recently completed remesa operations of the
--      same conversation (ordered by `completed_at DESC`). Cancelled
--      operations are still never surfaced — history means "delivered",
--      not "no longer open". Four new output columns mark which rows are
--      history and carry their delivery facts: `operation_is_history`,
--      `operation_beneficiaries_complete`, `operation_delivery_mode`,
--      `operation_delivered_at`.
--
--   B. An operation is only deliverable once its beneficiary data is
--      complete: every `vigente` beneficiary on it must be complete, and
--      there must be at least one. Complete means `beneficiary_type =
--      'zelle'` -> non-empty `name` AND non-empty `zelle_account`; any
--      other type -> non-empty `card_number` AND non-empty `phone`
--      (blank/whitespace-only counts as empty). `crm_beneficiarios_completos`
--      is the single source of truth for this rule, and
--      `crm_entregar_operacion` (101) now enforces it: a ready_to_transfer
--      operation with incomplete beneficiary data cannot be delivered.
--
-- RESOLVER UNCHANGED: `resolver_resultado` / `resolver_operation_id` /
-- resolver_candidatas` keep being computed over live (non-terminal)
-- operations only, exactly as before — history rows never affect which
-- operation the resolver points at.
--
-- ZERO-BENEFICIARY OPERATIONS: `crm_operaciones_de_conversacion` still
-- surfaces an operation with zero `vigente` beneficiaries as a single row
-- with NULL beneficiary columns (LEFT JOIN, never fabricated) — same
-- behavior the live 100 version already has for open operations, now also
-- true for history rows. `crm_beneficiarios_completos` treats "zero
-- vigente beneficiaries" as incomplete (false), per rule B's "at least
-- one" requirement.
--
-- ROLLBACK: ROLLBACK-102-operations-history-and-delivery-readiness.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. crm_beneficiarios_completos — the single source of truth for rule B.
-- ---------------------------------------------------------------------
-- Exposed to `authenticated` directly (unlike crm_calcular_monto_destino /
-- crm_tasa_vigente in 100, which are pure internal trigger helpers): the
-- panel may want this readiness flag for an operation without paying for
-- a full crm_operaciones_de_conversacion round trip.

CREATE OR REPLACE FUNCTION crm_beneficiarios_completos(p_operation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    count(*) > 0
    AND bool_and(
      CASE
        WHEN beneficiary_type = 'zelle' THEN
          btrim(coalesce(name, '')) <> '' AND btrim(coalesce(zelle_account, '')) <> ''
        ELSE
          btrim(coalesce(card_number, '')) <> '' AND btrim(coalesce(phone, '')) <> ''
      END
    )
  FROM remittance_beneficiaries
  WHERE operation_id = p_operation_id
    AND status = 'vigente';
$$;

REVOKE ALL ON FUNCTION crm_beneficiarios_completos(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_beneficiarios_completos(uuid) TO authenticated;


-- ---------------------------------------------------------------------
-- 2. crm_operaciones_de_conversacion — history rows + readiness columns.
-- ---------------------------------------------------------------------
-- Same body as the live 100 version (see that file's header for the full
-- resolver/authorization/masking design rationale), with the operations
-- set widened to include recent completed history and four columns
-- appended. RETURNS TABLE shape changes, so DROP + CREATE, not REPLACE.

DROP FUNCTION crm_operaciones_de_conversacion(uuid);

CREATE FUNCTION crm_operaciones_de_conversacion(
  p_conversation_id uuid
) RETURNS TABLE (
  resolver_resultado                  text,
  resolver_operation_id               uuid,
  resolver_candidatas                 integer,
  operation_id                        uuid,
  operation_status                    text,
  operation_service_type              text,
  operation_source_currency           text,
  operation_destination_currency      text,
  operation_delivery_method           text,
  operation_deposit_method            text,
  operation_quoted_source_amount      numeric,
  operation_quoted_destination_amount numeric,
  operation_admin_locked_fields       jsonb,
  operation_created_at                timestamptz,
  operation_completed_at              timestamptz,
  beneficiary_id                      uuid,
  beneficiary_type                    text,
  beneficiary_name                    text,
  beneficiary_card_number             text,
  beneficiary_phone                   text,
  beneficiary_zelle_account           text,
  beneficiary_delivery_method         text,
  beneficiary_amount                  numeric,
  beneficiary_currency                text,
  beneficiary_position                integer,
  operation_quoted_destination_rate   numeric,
  operation_quoted_destination_origin text,
  beneficiary_amount_origin           text,
  operation_is_history                boolean,
  operation_beneficiaries_complete    boolean,
  operation_delivery_mode             text,
  operation_delivered_at              timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id            uuid;
  v_resolver_resultado    text;
  v_resolver_operation_id uuid;
  v_resolver_candidatas   integer;
BEGIN
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  SELECT c.account_id INTO v_account_id
    FROM conversations c
   WHERE c.id = p_conversation_id;

  -- Same 42501 whether the conversation doesn't exist or belongs to an
  -- account the caller isn't a member of — see 097's file header for why.
  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  -- Inlined, NOT called by name — see 097's file header's "WHY THE
  -- RESOLVER LOGIC IS INLINED" section. Unchanged by this migration: the
  -- resolver only ever looks at live (non-terminal) operations, regardless
  -- of the history rows the RETURN QUERY below now also surfaces.
  SELECT count(*) INTO v_resolver_candidatas
    FROM remittance_operations
   WHERE conversation_id = p_conversation_id
     AND status NOT IN ('completed', 'cancelled');

  IF v_resolver_candidatas = 0 THEN
    v_resolver_resultado := 'ninguna';
    v_resolver_operation_id := NULL;
  ELSIF v_resolver_candidatas = 1 THEN
    v_resolver_resultado := 'unica';
    SELECT o.id INTO v_resolver_operation_id
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled');
  ELSE
    v_resolver_resultado := 'ambigua';
    v_resolver_operation_id := NULL;
  END IF;

  RETURN QUERY
  WITH ops AS (
    -- Current open (non-terminal) remesa operations — same set the RPC
    -- has always returned.
    SELECT o.*, false AS is_history
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled')
       AND o.service_type = 'remesa'
    UNION ALL
    -- The 10 most recently completed remesa operations of the same
    -- conversation — read-only history. A completed operation can never
    -- also match the branch above (status is exclusive), so UNION ALL
    -- cannot duplicate a row.
    SELECT h.*, true AS is_history
      FROM (
        SELECT o2.*
          FROM remittance_operations o2
         WHERE o2.conversation_id = p_conversation_id
           AND o2.status = 'completed'
           AND o2.service_type = 'remesa'
         ORDER BY o2.completed_at DESC
         LIMIT 10
      ) h
  )
  SELECT
    r.resultado,
    r.operation_id,
    r.candidatas,
    o.id,
    o.status,
    o.service_type,
    o.source_currency,
    o.destination_currency,
    o.delivery_method,
    o.deposit_method,
    o.quoted_source_amount,
    o.quoted_destination_amount,
    o.admin_locked_fields,
    o.created_at,
    o.completed_at,
    b.id,
    b.beneficiary_type,
    b.name,
    b.card_number,
    b.phone,
    b.zelle_account,
    b.delivery_method,
    b.amount,
    b.currency,
    b.position,
    o.quoted_destination_rate,
    o.quoted_destination_origin,
    b.amount_origin,
    o.is_history,
    CASE WHEN o.id IS NULL THEN NULL ELSE crm_beneficiarios_completos(o.id) END,
    o.delivery_mode,
    CASE WHEN o.is_history THEN o.completed_at ELSE NULL END
  -- A single synthetic one-row source (no FROM) rather than a set-returning
  -- call, so the resolver values still surface even when zero operations
  -- match below (the 'ninguna' case) — LEFT JOIN against zero rows on the
  -- left would otherwise return zero rows overall, not one resolver-only row.
  FROM (SELECT v_resolver_resultado AS resultado, v_resolver_operation_id AS operation_id, v_resolver_candidatas AS candidatas) r
  LEFT JOIN ops o ON true
  LEFT JOIN remittance_beneficiaries b
         ON b.operation_id = o.id
        AND b.status = 'vigente'
  ORDER BY o.is_history ASC NULLS LAST, o.created_at DESC NULLS LAST, o.completed_at DESC NULLS LAST, b.position ASC NULLS LAST;
END $$;

REVOKE ALL ON FUNCTION crm_operaciones_de_conversacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_operaciones_de_conversacion(uuid) TO authenticated;


-- ---------------------------------------------------------------------
-- 3. crm_entregar_operacion — enforce the beneficiary-completeness gate.
-- ---------------------------------------------------------------------
-- Same body as the live 101 version, with one new check inserted right
-- after the status/stage readiness check and before any UPDATE. Signature
-- is unchanged, so CREATE OR REPLACE is enough.

CREATE OR REPLACE FUNCTION crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lista         CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_entregada     CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';

  v_account_id    uuid;
  v_deal_id       uuid;
  v_conversation  uuid;

  v_stage         uuid;
  v_locked_deal   uuid;

  v_status_before text;
  v_status_after  text;
  v_completed_at  timestamptz;

  v_mode          text;
  v_wamid         text;
  v_path          text;
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

  IF v_deal_id IS NULL THEN
    RAISE EXCEPTION 'operation has no linked deal' USING ERRCODE = '22023';
  END IF;

  -- Evidence validation happens before any locking, so a bad payload
  -- never touches deal/operation state regardless of their current status.
  IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'evidence must be a JSON object' USING ERRCODE = '22023';
  END IF;

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

  -- Lock order deal -> operation, the same order automation uses (see 099).
  SELECT stage_id, conversation_id INTO v_stage, v_conversation FROM deals WHERE id = v_deal_id FOR UPDATE;

  SELECT status, deal_id
    INTO v_status_before, v_locked_deal
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_locked_deal IS DISTINCT FROM v_deal_id THEN
    RAISE EXCEPTION 'operation changed concurrently, retry' USING ERRCODE = '40001';
  END IF;

  IF v_status_before IS DISTINCT FROM 'ready_to_transfer' OR v_stage IS DISTINCT FROM v_lista THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  -- Rule B: deliverable only once every vigente beneficiary is complete,
  -- and there is at least one. See crm_beneficiarios_completos above.
  IF NOT crm_beneficiarios_completos(p_operation_id) THEN
    RAISE EXCEPTION 'beneficiary data is incomplete' USING ERRCODE = '22023';
  END IF;

  -- Reuse the legacy stage path: this is exactly the UPDATE the old
  -- Kanban board performs by hand when a card is dragged into Entregada.
  UPDATE deals SET stage_id = v_entregada, updated_at = now() WHERE id = v_deal_id;

  SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  UPDATE remittance_operations
     SET delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid()
   WHERE id = p_operation_id
  RETURNING completed_at INTO v_completed_at;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer', 'deal_stage', v_lista),
          jsonb_build_object('status', 'completed', 'deal_stage', v_entregada, 'evidence', p_evidence));

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $$;

REVOKE ALL ON FUNCTION crm_entregar_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_entregar_operacion(uuid, jsonb) TO authenticated;

-- =====================================================================
-- VALIDATED ON STAGING (crm.onlinefreedom.site's isolated DB), inside a
-- transaction that always ends in ROLLBACK — see
-- supabase/staging/assertions/history-readiness.sql for the exact
-- fixtures and expectations.
--
-- ROLLBACK
--   supabase/migrations/ROLLBACK-102-operations-history-and-delivery-readiness.sql
-- =====================================================================
