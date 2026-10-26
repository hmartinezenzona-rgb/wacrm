-- =====================================================================
-- 330 -- Funding case and allocation ledger (phase 2 of the no-service redesign)
--
-- The money needs a holder that is not a delivery operation. This adds:
--   * funding_case: the expediente of one send; one active case per conversation.
--   * case_deposits: verified MMG deposits linked to a case (depositos_mmg stays the source of truth).
--   * funding_allocations: GYD of the case assigned to an operation (committed / released).
--   * funding_movements: append-only audit of commits and releases.
--   * remittance_operations.case_id: the operation's expediente (nullable; existing rows untouched).
--
-- Compatible with the current operation model: additive only, no backfill, no existing function
-- changed, no bot wiring. Phase 3 runs the deterministic reconciliation against these tables; phase 4
-- adds the panel. The six functions are the only write path and are granted to service_role only in
-- this phase; the tables are RLS-protected.
--
-- Assertion: supabase/staging/assertions/funding-case.sql.
-- Rollback: ROLLBACK-330-funding-case.sql.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.funding_case (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id      uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  status          text NOT NULL DEFAULT 'open',
  opened_at       timestamptz NOT NULL DEFAULT now(),
  closed_at       timestamptz,
  created_by      text,
  closed_by       text,
  note            text,
  CONSTRAINT funding_case_status_chk CHECK (status IN ('open', 'allocating', 'closed', 'incident')),
  CONSTRAINT funding_case_closed_chk CHECK ((status = 'closed') = (closed_at IS NOT NULL))
);

-- One active case per conversation; closed cases accumulate as history.
CREATE UNIQUE INDEX IF NOT EXISTS funding_case_one_active_idx
  ON public.funding_case (conversation_id)
  WHERE status <> 'closed';
CREATE INDEX IF NOT EXISTS funding_case_account_idx
  ON public.funding_case (account_id, status);

COMMENT ON TABLE public.funding_case IS
  '330: the expediente of one send. Groups verified deposits and the balance not yet assigned; the '
  'money no longer waits inside an operation. One active case per conversation; closed cases are history.';

CREATE TABLE IF NOT EXISTS public.case_deposits (
  case_id          uuid NOT NULL REFERENCES public.funding_case(id) ON DELETE CASCADE,
  deposit_trans_id text NOT NULL REFERENCES public.depositos_mmg(trans_id) ON DELETE RESTRICT,
  linked_at        timestamptz NOT NULL DEFAULT now(),
  linked_by        text,
  PRIMARY KEY (case_id, deposit_trans_id),
  UNIQUE (deposit_trans_id)
);

COMMENT ON TABLE public.case_deposits IS
  '330: links a verified depositos_mmg row to one funding case. The deposit is the source of truth; '
  'the link does not copy or move money, and a deposit can belong to at most one case.';

CREATE TABLE IF NOT EXISTS public.funding_allocations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id         uuid NOT NULL REFERENCES public.funding_case(id) ON DELETE CASCADE,
  operation_id    uuid NOT NULL REFERENCES public.remittance_operations(id) ON DELETE CASCADE,
  amount_gyd      numeric NOT NULL CHECK (amount_gyd > 0),
  status          text NOT NULL DEFAULT 'committed',
  evidence_type   text NOT NULL DEFAULT 'operator',
  idempotency_key text NOT NULL UNIQUE CHECK (btrim(idempotency_key) <> ''),
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      text,
  released_at     timestamptz,
  release_reason  text,
  CONSTRAINT funding_allocations_status_chk CHECK (status IN ('proposed', 'committed', 'released')),
  CONSTRAINT funding_allocations_evidence_chk CHECK (evidence_type IN ('data', 'explicit_choice', 'operator', 'minimum_suggestion')),
  CONSTRAINT funding_allocations_released_chk CHECK ((status = 'released') = (released_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS funding_allocations_case_idx
  ON public.funding_allocations (case_id, status);
CREATE INDEX IF NOT EXISTS funding_allocations_operation_idx
  ON public.funding_allocations (operation_id, status);

COMMENT ON TABLE public.funding_allocations IS
  '330: how many GYD of a funding case are assigned to an operation. Only committed rows count '
  'against the available balance; a release returns them through a funding_movements row.';

CREATE TABLE IF NOT EXISTS public.funding_movements (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id         uuid NOT NULL REFERENCES public.funding_case(id) ON DELETE CASCADE,
  allocation_id   uuid REFERENCES public.funding_allocations(id) ON DELETE SET NULL,
  operation_id    uuid REFERENCES public.remittance_operations(id) ON DELETE SET NULL,
  kind            text NOT NULL,
  amount_gyd      numeric NOT NULL CHECK (amount_gyd > 0),
  idempotency_key text NOT NULL UNIQUE CHECK (btrim(idempotency_key) <> ''),
  reason          text,
  actor           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT funding_movements_kind_chk CHECK (kind IN ('commit', 'release', 'refund', 'adjustment'))
);

CREATE INDEX IF NOT EXISTS funding_movements_case_idx
  ON public.funding_movements (case_id, created_at);

COMMENT ON TABLE public.funding_movements IS
  '330: append-only audit of the funding ledger (commit, release, refund, adjustment). The balance '
  'comes from committed allocations, never from summing this table.';

ALTER TABLE public.funding_case ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.case_deposits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.funding_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.funding_movements ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.funding_case FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.case_deposits FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.funding_allocations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.funding_movements FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.funding_case TO service_role;
GRANT ALL ON TABLE public.case_deposits TO service_role;
GRANT ALL ON TABLE public.funding_allocations TO service_role;
GRANT ALL ON TABLE public.funding_movements TO service_role;

ALTER TABLE public.remittance_operations
  ADD COLUMN IF NOT EXISTS case_id uuid REFERENCES public.funding_case(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS remittance_operations_case_idx
  ON public.remittance_operations (case_id)
  WHERE case_id IS NOT NULL;

COMMENT ON COLUMN public.remittance_operations.case_id IS
  '330: the funding case that owns the money assigned to this operation. Nullable; legacy rows are untouched.';

-- ---------------------------------------------------------------------
-- Open (or return) the active case of a conversation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.funding_case_abrir(p_conv uuid, p_actor text DEFAULT NULL)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_case    uuid;
BEGIN
  IF p_conv IS NULL THEN
    RAISE EXCEPTION 'conversation is required' USING ERRCODE = '22023';
  END IF;

  SELECT c.account_id INTO v_account FROM conversations c WHERE c.id = p_conv;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'conversation not found' USING ERRCODE = 'P0002';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('funding_case:' || p_conv::text, 0));

  SELECT fc.id INTO v_case
    FROM funding_case fc
   WHERE fc.conversation_id = p_conv AND fc.status <> 'closed'
   ORDER BY fc.opened_at DESC
   LIMIT 1;
  IF v_case IS NOT NULL THEN
    RETURN v_case;
  END IF;

  INSERT INTO funding_case (account_id, conversation_id, created_by)
  VALUES (v_account, p_conv, COALESCE(p_actor, wacrm_current_actor()))
  RETURNING id INTO v_case;
  RETURN v_case;
END $function$;

COMMENT ON FUNCTION public.funding_case_abrir(uuid, text) IS
  '330: returns the active funding case of the conversation, creating it if needed. Advisory lock + '
  'partial unique index keep one active case per conversation.';

-- ---------------------------------------------------------------------
-- The case balance: verified deposits, committed allocations, available.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.funding_case_saldo(p_case uuid)
 RETURNS TABLE(depositado numeric, asignado numeric, disponible numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH dep AS (
    SELECT COALESCE(sum(d.monto), 0) AS total
      FROM case_deposits cd
      JOIN depositos_mmg d ON d.trans_id = cd.deposit_trans_id
     WHERE cd.case_id = p_case
       AND d.consumido_en IS NOT NULL
       AND d.anulado_en IS NULL
       AND d.descartado_en IS NULL
       AND COALESCE(d.moneda, 'GYD') = 'GYD'
  ),
  alloc AS (
    SELECT COALESCE(sum(a.amount_gyd), 0) AS total
      FROM funding_allocations a
     WHERE a.case_id = p_case AND a.status = 'committed'
  )
  SELECT dep.total, alloc.total, dep.total - alloc.total, 'GYD'
    FROM dep, alloc;
$function$;

COMMENT ON FUNCTION public.funding_case_saldo(uuid) IS
  '330: verified GYD linked to the case, committed allocations, and the difference. A voided or '
  'discarded deposit stops counting even if it was linked earlier.';

-- ---------------------------------------------------------------------
-- Link a verified deposit to a case (idempotent).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.funding_deposito_vincular(p_case uuid, p_trans_id text, p_actor text DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status text;
  v_dep    depositos_mmg%ROWTYPE;
  v_other  uuid;
BEGIN
  IF p_case IS NULL OR NULLIF(btrim(p_trans_id), '') IS NULL THEN
    RAISE EXCEPTION 'case and deposit reference are required' USING ERRCODE = '22023';
  END IF;

  SELECT status INTO v_status FROM funding_case WHERE id = p_case FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'funding case not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_status = 'closed' THEN
    RAISE EXCEPTION 'the funding case is closed' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_dep FROM depositos_mmg WHERE trans_id = p_trans_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'deposit not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_dep.consumido_en IS NULL THEN
    RAISE EXCEPTION 'the deposit is not verified' USING ERRCODE = '22023';
  END IF;
  IF v_dep.anulado_en IS NOT NULL THEN
    RAISE EXCEPTION 'the deposit is voided' USING ERRCODE = '22023';
  END IF;
  IF v_dep.descartado_en IS NOT NULL THEN
    RAISE EXCEPTION 'the deposit is discarded' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(v_dep.moneda, 'GYD') <> 'GYD' THEN
    RAISE EXCEPTION 'the deposit is not in GYD' USING ERRCODE = '22023';
  END IF;

  SELECT cd.case_id INTO v_other FROM case_deposits cd WHERE cd.deposit_trans_id = p_trans_id;
  IF v_other = p_case THEN
    RETURN;
  END IF;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'the deposit already belongs to another funding case' USING ERRCODE = '22023';
  END IF;

  IF v_dep.operation_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.id = v_dep.operation_id
                    AND o.case_id IS NOT NULL AND o.case_id <> p_case) THEN
    RAISE EXCEPTION 'the deposit funds an operation of another funding case' USING ERRCODE = '22023';
  END IF;

  INSERT INTO case_deposits (case_id, deposit_trans_id, linked_by)
  VALUES (p_case, p_trans_id, COALESCE(p_actor, wacrm_current_actor()));
END $function$;

COMMENT ON FUNCTION public.funding_deposito_vincular(uuid, text, text) IS
  '330: links a consumed, non-void, non-discarded GYD depositos_mmg row to one case. Idempotent; '
  'refuses a deposit that is already in another case or funds an operation of another case.';

-- ---------------------------------------------------------------------
-- Commit GYD of the case to an operation (idempotent).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.funding_asignar(
  p_case uuid,
  p_operation_id uuid,
  p_amount_gyd numeric,
  p_evidence_type text DEFAULT 'operator',
  p_idempotency_key text DEFAULT NULL,
  p_actor text DEFAULT NULL
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_case     funding_case%ROWTYPE;
  v_op       remittance_operations%ROWTYPE;
  v_existing funding_allocations%ROWTYPE;
  v_disp     numeric;
  v_id       uuid;
BEGIN
  IF p_case IS NULL OR p_operation_id IS NULL OR p_amount_gyd IS NULL OR p_amount_gyd <= 0 THEN
    RAISE EXCEPTION 'case, operation and a positive amount are required' USING ERRCODE = '22023';
  END IF;
  IF NULLIF(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'an idempotency key is required' USING ERRCODE = '22023';
  END IF;
  IF p_evidence_type NOT IN ('data', 'explicit_choice', 'operator', 'minimum_suggestion') THEN
    RAISE EXCEPTION 'unknown evidence type %', p_evidence_type USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing FROM funding_allocations WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.case_id <> p_case OR v_existing.operation_id <> p_operation_id
       OR v_existing.amount_gyd <> p_amount_gyd THEN
      RAISE EXCEPTION 'the idempotency key was reused with different arguments' USING ERRCODE = '22023';
    END IF;
    RETURN v_existing.id;
  END IF;

  SELECT * INTO v_case FROM funding_case WHERE id = p_case FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'funding case not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_case.status = 'closed' THEN
    RAISE EXCEPTION 'the funding case is closed' USING ERRCODE = '22023';
  END IF;
  IF v_case.status = 'incident' THEN
    RAISE EXCEPTION 'the funding case is in incident' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_op.conversation_id <> v_case.conversation_id THEN
    RAISE EXCEPTION 'the operation and the case belong to different conversations' USING ERRCODE = '22023';
  END IF;
  IF v_op.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'cannot allocate to a closed operation' USING ERRCODE = '22023';
  END IF;
  IF v_op.case_id IS NOT NULL AND v_op.case_id <> p_case THEN
    RAISE EXCEPTION 'the operation belongs to another funding case' USING ERRCODE = '22023';
  END IF;

  SELECT s.disponible INTO v_disp FROM funding_case_saldo(p_case) s;
  IF p_amount_gyd > COALESCE(v_disp, 0) THEN
    RAISE EXCEPTION 'the allocation is % GYD but only % GYD are available', p_amount_gyd, COALESCE(v_disp, 0)
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO funding_allocations (case_id, operation_id, amount_gyd, status, evidence_type, idempotency_key, created_by)
  VALUES (p_case, p_operation_id, p_amount_gyd, 'committed', p_evidence_type, p_idempotency_key,
          COALESCE(p_actor, wacrm_current_actor()))
  RETURNING id INTO v_id;

  UPDATE remittance_operations
     SET case_id = p_case
   WHERE id = p_operation_id AND case_id IS NULL;

  INSERT INTO funding_movements (case_id, allocation_id, operation_id, kind, amount_gyd, idempotency_key, reason, actor)
  VALUES (p_case, v_id, p_operation_id, 'commit', p_amount_gyd, 'commit:' || p_idempotency_key,
          'allocation committed', COALESCE(p_actor, wacrm_current_actor()));

  RETURN v_id;
END $function$;

COMMENT ON FUNCTION public.funding_asignar(uuid, uuid, numeric, text, text, text) IS
  '330: commits GYD of the case to an operation, within the available balance, and links the '
  'operation to the case. Idempotent by key; refuses closed/incident cases, closed operations, '
  'another conversation, another case, and over-allocation.';

-- ---------------------------------------------------------------------
-- Release a committed allocation (idempotent).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.funding_liberar(
  p_allocation_id uuid,
  p_idempotency_key text DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_actor text DEFAULT NULL
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_alloc     funding_allocations%ROWTYPE;
  v_op_status text;
BEGIN
  IF p_allocation_id IS NULL OR NULLIF(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'allocation and idempotency key are required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_alloc FROM funding_allocations WHERE id = p_allocation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'allocation not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_alloc.status = 'released' THEN
    RETURN;
  END IF;

  PERFORM 1 FROM funding_case WHERE id = v_alloc.case_id FOR UPDATE;

  SELECT status INTO v_op_status FROM remittance_operations WHERE id = v_alloc.operation_id;
  IF v_op_status = 'completed' THEN
    RAISE EXCEPTION 'cannot release the funding of a completed operation' USING ERRCODE = '22023';
  END IF;

  UPDATE funding_allocations
     SET status = 'released', released_at = now(), release_reason = p_reason
   WHERE id = p_allocation_id;

  INSERT INTO funding_movements (case_id, allocation_id, operation_id, kind, amount_gyd, idempotency_key, reason, actor)
  VALUES (v_alloc.case_id, v_alloc.id, v_alloc.operation_id, 'release', v_alloc.amount_gyd,
          'release:' || p_idempotency_key, COALESCE(p_reason, 'allocation released'),
          COALESCE(p_actor, wacrm_current_actor()));
END $function$;

COMMENT ON FUNCTION public.funding_liberar(uuid, text, text, text) IS
  '330: releases a committed allocation, returning its GYD to the available balance. Idempotent; a '
  'completed operation keeps its allocation.';

-- ---------------------------------------------------------------------
-- Close the case only when nothing is unassigned.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.funding_case_cerrar(p_case uuid, p_reason text DEFAULT NULL, p_actor text DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status text;
  v_disp   numeric;
BEGIN
  IF p_case IS NULL THEN
    RAISE EXCEPTION 'case is required' USING ERRCODE = '22023';
  END IF;

  SELECT status INTO v_status FROM funding_case WHERE id = p_case FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'funding case not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_status = 'closed' THEN
    RETURN;
  END IF;

  SELECT s.disponible INTO v_disp FROM funding_case_saldo(p_case) s;
  IF COALESCE(v_disp, 0) <> 0 THEN
    RAISE EXCEPTION 'cannot close: % GYD remain unassigned', v_disp USING ERRCODE = '22023';
  END IF;

  UPDATE funding_case
     SET status = 'closed',
         closed_at = now(),
         closed_by = COALESCE(p_actor, wacrm_current_actor()),
         note = COALESCE(p_reason, note)
   WHERE id = p_case;
END $function$;

COMMENT ON FUNCTION public.funding_case_cerrar(uuid, text, text) IS
  '330: closes a case only when the available balance is zero; committed allocations may remain. '
  'Idempotent; a closed case accepts no new deposits or allocations.';

-- ---------------------------------------------------------------------
-- Grants: service_role only in phase 2. The panel gets access in phase 4.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.funding_case_abrir(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.funding_case_saldo(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.funding_deposito_vincular(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.funding_asignar(uuid, uuid, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.funding_liberar(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.funding_case_cerrar(uuid, text, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.funding_case_abrir(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.funding_case_saldo(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.funding_deposito_vincular(uuid, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.funding_asignar(uuid, uuid, numeric, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.funding_liberar(uuid, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.funding_case_cerrar(uuid, text, text) TO service_role;
