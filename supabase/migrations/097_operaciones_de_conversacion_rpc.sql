-- 097 — Read-only RPC for the in-chat remesa operations panel
--
-- SCOPE (SDD change port-chat-operations-calculator, Slice 5, gap task):
--   `crm_operaciones_de_conversacion(p_conversation_id)` — the single read
--   the panel needs: every open (non-terminal) `service_type = 'remesa'`
--   operation for a conversation, each with its current (`status =
--   'vigente'`) beneficiaries, plus the resolver state from the existing
--   `cerebro_resolver_operacion` (040:178-206). No writes. No corrections,
--   deposit review or delivery actions — those are later slices (6, 7, 8).
--
-- WHY THE RESOLVER LOGIC IS INLINED, NOT CALLED BY NAME (design decision,
-- documented here per the apply-batch instruction to "pick one, document")
--
--   `cerebro_resolver_operacion` counts every non-terminal operation for
--   the conversation regardless of `service_type` — it predates
--   `service_type` (migration 040 vs 046) and 046 deliberately left it
--   untouched ("todavia no hay flujo" for non-remesa services, 046:66-93).
--   This RPC reproduces its exact 1-argument semantics (040:178-206)
--   inline rather than writing a remesa-scoped variant, because:
--     1. every operation in this system is `service_type = 'remesa'`
--        today (046's own header) — there is no live case where the two
--        views disagree yet;
--     2. a remesa-scoped resolver would be a NEW resolver semantics
--        decision (what does "ambigua" mean when it's one remesa + one
--        combo?) that the design document never made — inventing one
--        inside a read-only Slice-5 RPC would be scope creep past what
--        was asked.
--   Net effect, spelled out for the one case where it could matter: if a
--   non-remesa operation is ever live in the same conversation, the
--   resolver state (`resolver_resultado`/`resolver_candidatas`) reflects
--   ALL live operations, while `operations` below lists remesa-only rows —
--   e.g. resolver could report 'ambigua' (a remesa + a combo) while
--   `operations` shows a single remesa row. The panel's TS read model
--   (`src/lib/remittance-operations/types.ts`) documents this same
--   deviation for callers. Revisit when a non-remesa panel ships.
--
--   DISCOVERED WHILE WRITING THIS MIGRATION, OUT OF SCOPE TO FIX HERE:
--   this schema (staging, presumably production too — unconfirmed, flag
--   for the Slice-1 drift-reconciliation gate, task 1.1b) carries a SECOND
--   overload, `cerebro_resolver_operacion(p_conversation_id uuid,
--   p_estados text[] DEFAULT NULL)`, that exists nowhere in this repo's
--   migrations — undocumented drift. Both overloads share the parameter
--   name `p_conversation_id`, so neither a bare 1-argument call nor a
--   named-argument call resolves unambiguously (Postgres: "function ...
--   is not unique"). Calling either overload explicitly by supplying a
--   second argument would make this migration's correctness depend on
--   drift that may not exist on every environment (a fresh install from
--   this repo's migrations alone has only the 1-argument function).
--   Reproducing the original function's logic inline sidesteps the
--   ambiguity entirely and behaves identically to the 1-argument overload
--   everywhere, drifted or not.
--
-- WHY "RETURN NOTHING" WAS **NOT** CHOSEN FOR NON-MEMBERS (the other pick
-- offered by the apply-batch instruction)
--
--   An empty/absent result for "conversation not found or not yours" would
--   be indistinguishable from the perfectly legitimate 'ninguna' resolver
--   state (a member with zero open remesas) — the API route could not
--   tell "you have no open remesas right now" from "you can't see this
--   conversation" and would either leak a false-negative 200 or have to
--   re-derive the account check itself, duplicating this function's own
--   authorization. So this RPC RAISEs `insufficient_privilege` (SQLSTATE
--   42501) instead, mirroring the existing account-scoped RPC convention
--   (018_account_member_rpcs.sql's error contract) that the route's
--   `toErrorResponse` already maps to HTTP 403. A NULL/absent
--   `p_conversation_id`, or one that matches no conversation at all, gets
--   the exact same 42501 as a real conversation belonging to another
--   account — never a different error shape that would let a caller probe
--   which conversation ids exist.
--
-- AUTHORIZATION: `is_account_member(<the conversation's own account_id>,
-- 'viewer')` — viewer is enough to read (spec: admin-field-ownership names
-- "operator" as agent+, but this RPC has no write path; a viewer must be
-- able to SEE the panel, just not act on it — later slices' RPCs gate
-- their own writes at agent+/admin+ as decision 3 requires).
--
-- MASKING: none here. `card_number`/`phone` are returned RAW. Masking is a
-- presentation-layer concern (src/lib/remittance-operations/read-model.ts,
-- same "/resumen" convention as 053_vistas_de_volumen.sql:127-128) done
-- once, in TypeScript, with a unit test — not duplicated into SQL. A later
-- slice (6) needs the raw values anyway to let an operator correct them.
--
-- IDEMPOTENT: `CREATE OR REPLACE FUNCTION`. Safe to re-run.
--
-- ROLLBACK: ROLLBACK-097-operaciones-de-conversacion-rpc.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION crm_operaciones_de_conversacion(
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
  beneficiary_position                integer
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
  -- account the caller isn't a member of — see the file header for why.
  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  -- Inlined, NOT called by name — see the file header's "WHY THE RESOLVER
  -- LOGIC IS INLINED" section for the overload-ambiguity this sidesteps.
  -- Semantically identical to cerebro_resolver_operacion(p_conversation_id)
  -- (040:178-206).
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
    b.position
  -- A single synthetic one-row source (no FROM) rather than a set-returning
  -- call, so the resolver values still surface even when zero operations
  -- match below (the 'ninguna' case) — LEFT JOIN against zero rows on the
  -- left would otherwise return zero rows overall, not one resolver-only row.
  FROM (SELECT v_resolver_resultado AS resultado, v_resolver_operation_id AS operation_id, v_resolver_candidatas AS candidatas) r
  LEFT JOIN remittance_operations o
         ON o.conversation_id = p_conversation_id
        AND o.status NOT IN ('completed', 'cancelled')
        AND o.service_type = 'remesa'
  LEFT JOIN remittance_beneficiaries b
         ON b.operation_id = o.id
        AND b.status = 'vigente'
  ORDER BY o.created_at DESC NULLS LAST, b.position ASC NULLS LAST;
END $$;

REVOKE ALL ON FUNCTION crm_operaciones_de_conversacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_operaciones_de_conversacion(uuid) TO authenticated;

-- =====================================================================
-- VALIDATED ON STAGING (crm.onlinefreedom.site's isolated DB), inside a
-- transaction that always ends in ROLLBACK — see
-- supabase/staging/assertions/read-rpc.sql for the exact fixtures and
-- expectations.
--
-- ROLLBACK
--   supabase/migrations/ROLLBACK-097-operaciones-de-conversacion-rpc.sql
-- =====================================================================
