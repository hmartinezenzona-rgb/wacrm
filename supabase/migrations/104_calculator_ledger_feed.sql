-- =====================================================================
-- 104 — Calculator ledger auto-feed
--
-- PURPOSE: today a completed remesa never reaches the calculator. Someone
-- retypes it into the shorthand textarea, or it is simply lost. This makes
-- completion itself the write: the moment an operation's status becomes
-- `completed`, a ledger entry appears carrying the rates in force at that
-- instant, and nothing later can change them.
--
-- WHY THE FORMULAS ARE DUPLICATED IN SQL (and why that is deliberate):
-- `src/lib/calculator/document-rates.ts` says it in its own docstring
-- (lines 20-23) — "the DB-side trigger that performs the actual atomic
-- snapshot write at delivery is a later slice's concern. Every function
-- here is pure and is meant to mirror that SQL 1:1 — keep both in sync if
-- either changes." This migration IS that SQL. The alternative (writing a
-- factless row and having TypeScript fill it in later) leaves a remesa
-- completed at 3am missing from the totals until somebody opens a browser,
-- and splits one atomic fact across two systems. The parity is enforced,
-- not hoped for: `assertions/feed-matrix.sql` asserts the SQL numbers and
-- the TS unit tests assert the same inputs produce the same outputs.
--
-- THE FORMULAS (mirroring formulas.ts `calculateEntry` + document-rates.ts):
--   basis = operation.quoted_source_amount (the client's GYD deposit).
--   Never quoted_destination_amount — that can be an AI/vision estimate.
--
--   CUP       amount    = basis * cup_global_rate
--             facturado = amount / cup_global_rate
--             invertido = (amount / usdt_sell_cup) * usdt_buy_gyd
--   ZELLE     amount    = ceil(basis / usdt_sell_gyd)   -- whole units, up
--   CLASICA   facturado = amount * usdt_sell_gyd
--   TROPICAL  invertido = amount * usdt_buy_gyd
--
--   retorno = facturado - invertido, always.
--
-- NEVER COMPUTED WITH A MISSING RATE: if any rate the service needs is
-- NULL, the entry is written as `verified_pending` with `missing_inputs`
-- naming exactly which ones, no financials, and it stays out of the totals
-- until an admin resolves it. A wrong number in a ledger is worse than an
-- absent one that says what it is waiting for.
--
-- REVERTING DOES NOT DELETE: a human moving an operation out of `completed`
-- flips its entry to `void` (keeping every figure for the audit trail).
-- Re-completing revives it with the rates in force at that later moment,
-- not the original ones.
--
-- THE FEED CAN NEVER BREAK A DELIVERY: every path runs inside an EXCEPTION
-- block. A feed failure logs `calculator_feed_failed` and lets the status
-- change commit. `calculator_unfed_operations` lists what was missed and
-- `crm_feed_calculator` replays it.
--
-- NO BACKFILL (assumption A1): `calculator_feed_state.feed_started_at` is
-- stamped when this migration runs. Remesas completed before that instant
-- are not the ledger's business and never appear in the unfed view.
--
-- GUARD ORDER: 096's guard 12a is a BEFORE trigger on status, so only
-- human-origin transitions into or out of `completed` ever reach this
-- AFTER trigger. Automation cannot feed or void.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Feed start marker (assumption A1 — no backfill)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS calculator_feed_state (
  -- Singleton: the CHECK plus the PK allow exactly one row, ever.
  id               boolean PRIMARY KEY DEFAULT true,
  feed_started_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT calculator_feed_state_singleton_chk CHECK (id)
);

INSERT INTO calculator_feed_state (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

ALTER TABLE calculator_feed_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS calculator_feed_state_select ON calculator_feed_state;
CREATE POLICY calculator_feed_state_select ON calculator_feed_state
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- ---------------------------------------------------------------------
-- 2. Ledger columns this slice adds to 095's table
-- ---------------------------------------------------------------------

ALTER TABLE remittance_calculator_entries
  ADD COLUMN IF NOT EXISTS rate_version_id uuid REFERENCES calculator_rate_versions(id),
  ADD COLUMN IF NOT EXISTS usdt_buy_gyd    numeric,
  ADD COLUMN IF NOT EXISTS usdt_sell_gyd   numeric,
  ADD COLUMN IF NOT EXISTS missing_inputs  text[],
  ADD COLUMN IF NOT EXISTS delivery_mode   text,
  ADD COLUMN IF NOT EXISTS voided_at       timestamptz,
  ADD COLUMN IF NOT EXISTS void_reason     text;

-- 095 already carries the other two rates of the snapshot under the names
-- the FORMULA uses rather than the names the rate table uses:
--   cup_global_rate <- calculator_rate_versions.cup_global_rate
--   cup_rate        <- calculator_rate_versions.usdt_sell_cup
-- They are reused rather than duplicated, so one entry never holds two
-- copies of one rate that could drift apart.
COMMENT ON COLUMN remittance_calculator_entries.cup_rate IS
  'Per-entry CUP rate. For an auto-fed entry this is the snapshot of '
  'calculator_rate_versions.usdt_sell_cup (formulas.ts calls it cupRate).';
COMMENT ON COLUMN remittance_calculator_entries.usdt_buy_gyd IS
  'Snapshot of calculator_rate_versions.usdt_buy_gyd (formulas.ts costGyd).';
COMMENT ON COLUMN remittance_calculator_entries.usdt_sell_gyd IS
  'Snapshot of calculator_rate_versions.usdt_sell_gyd (formulas.ts saleGyd).';
COMMENT ON COLUMN remittance_calculator_entries.missing_inputs IS
  'Which required rates were unset when this entry was fed. Non-empty only '
  'while status = verified_pending.';

ALTER TABLE remittance_calculator_entries
  ADD CONSTRAINT remittance_calculator_entries_usdt_buy_gyd_chk
  CHECK (usdt_buy_gyd IS NULL OR (usdt_buy_gyd > 0 AND usdt_buy_gyd < 1e9));
ALTER TABLE remittance_calculator_entries
  ADD CONSTRAINT remittance_calculator_entries_usdt_sell_gyd_chk
  CHECK (usdt_sell_gyd IS NULL OR (usdt_sell_gyd > 0 AND usdt_sell_gyd < 1e9));

-- `void` joins the status vocabulary. The existing
-- _pending_has_no_snapshot_chk / _completed_has_snapshot_chk are both
-- written as `status <> '<x>' OR ...`, so a voided row keeps whatever
-- figures it had without violating either.
ALTER TABLE remittance_calculator_entries DROP CONSTRAINT IF EXISTS remittance_calculator_entries_status_chk;
ALTER TABLE remittance_calculator_entries
  ADD CONSTRAINT remittance_calculator_entries_status_chk
  CHECK (status IN ('completed', 'verified_pending', 'void'));

ALTER TABLE remittance_calculator_entries
  ADD CONSTRAINT remittance_calculator_entries_void_shape_chk
  CHECK (status <> 'void' OR (voided_at IS NOT NULL AND operation_id IS NOT NULL));

-- ---------------------------------------------------------------------
-- 3. Let a completed entry be voided — and nothing else
-- ---------------------------------------------------------------------

-- 095's guard forbade EVERY update of a completed row, which would also
-- forbid the one legitimate change: a human reverting the operation. This
-- replaces it with a rule that still freezes the figures but permits the
-- completed -> void transition (and the void -> completed revival), so the
-- ledger can tell the truth about a reversal instead of lying by omission.
CREATE OR REPLACE FUNCTION remittance_calculator_entries_lock_completed()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'completed' THEN
      RAISE EXCEPTION 'remittance_calculator_entries: completed rows are append-only'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.status = 'completed' THEN
    -- The only permitted change is voiding it, and even then every figure
    -- must survive untouched so the audit trail stays readable.
    IF NEW.status <> 'void' THEN
      RAISE EXCEPTION 'remittance_calculator_entries: completed rows are append-only'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NEW.amount        IS DISTINCT FROM OLD.amount
       OR NEW.service       IS DISTINCT FROM OLD.service
       OR NEW.operation_id  IS DISTINCT FROM OLD.operation_id
       OR NEW.facturado_gyd IS DISTINCT FROM OLD.facturado_gyd
       OR NEW.invertido_gyd IS DISTINCT FROM OLD.invertido_gyd
       OR NEW.retorno_gyd   IS DISTINCT FROM OLD.retorno_gyd
       OR NEW.rate_version_id IS DISTINCT FROM OLD.rate_version_id
    THEN
      RAISE EXCEPTION 'remittance_calculator_entries: voiding must not alter the recorded figures'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- 4. Operation -> calculator service
-- ---------------------------------------------------------------------

-- Design decision 6's map. Anything else yields NULL and produces no entry
-- at all: a service the ledger cannot price is left out rather than
-- guessed at.
--
-- LIMITATION, deliberate: `multiple_distribution` maps to CUP because
-- today every split is a CUP split. A mixed split (CUP + Zelle) has no
-- single service and would be priced wrong here — slice 10 is where the
-- bot starts writing per-beneficiary rows and this map grows a row-level
-- branch. Until then a mixed split cannot be produced.
CREATE OR REPLACE FUNCTION calculator_service_for_operation(p_delivery_method text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(coalesce(p_delivery_method, ''))
           WHEN 'cuban_card'            THEN 'CUP'
           WHEN 'multiple_distribution' THEN 'CUP'
           WHEN 'zelle'                 THEN 'ZELLE'
           WHEN 'clasica'               THEN 'CLASICA'
           WHEN 'tropical'              THEN 'TROPICAL'
           ELSE NULL
         END;
$$;

-- Which of a service's required rates are unset in a given version.
-- Mirrors document-rates.ts REQUIRED_DOCUMENT_RATE_FIELDS exactly, and
-- returns the TypeScript field names so the UI can show one vocabulary.
CREATE OR REPLACE FUNCTION calculator_missing_rates(
  p_service text,
  p_rates   calculator_rate_versions
) RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_service
    WHEN 'CUP' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.cup_global_rate IS NULL THEN 'cupGlobalRate' END,
        CASE WHEN p_rates.usdt_sell_cup   IS NULL THEN 'usdtSellCup'   END,
        CASE WHEN p_rates.usdt_buy_gyd    IS NULL THEN 'usdtBuyGyd'    END
      ], NULL)
    ELSE
      array_remove(ARRAY[
        CASE WHEN p_rates.usdt_buy_gyd  IS NULL THEN 'usdtBuyGyd'  END,
        CASE WHEN p_rates.usdt_sell_gyd IS NULL THEN 'usdtSellGyd' END
      ], NULL)
  END;
$$;

-- ---------------------------------------------------------------------
-- 5. The feed itself
-- ---------------------------------------------------------------------

-- Writes (or revives) one ledger entry for a completed operation. Returns
-- the entry id, or NULL when the operation maps to no service. Raises
-- nothing the callers cannot handle: both call sites wrap it.
CREATE OR REPLACE FUNCTION calculator_feed_operation(p_operation_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op        remittance_operations;
  v_rates     calculator_rate_versions;
  v_service   text;
  v_missing   text[];
  v_basis     numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_currency  text;
  v_customer  text;
  v_entry_id  uuid;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.status <> 'completed' THEN
    RETURN NULL;
  END IF;

  v_service := calculator_service_for_operation(v_op.delivery_method);
  IF v_service IS NULL THEN
    RETURN NULL;
  END IF;

  v_basis := v_op.quoted_source_amount;
  IF v_basis IS NULL OR v_basis <= 0 THEN
    RETURN NULL;
  END IF;

  v_rates   := calculator_rates_vigentes(v_op.account_id);
  v_missing := calculator_missing_rates(v_service, v_rates);

  SELECT c.name INTO v_customer
    FROM conversations conv JOIN contacts c ON c.id = conv.contact_id
   WHERE conv.id = v_op.conversation_id;

  IF v_service = 'CUP' THEN
    v_currency := 'CUP';
    IF coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := v_basis * v_rates.cup_global_rate;
      v_facturado := v_amount / v_rates.cup_global_rate;
      v_invertido := (v_amount / v_rates.usdt_sell_cup) * v_rates.usdt_buy_gyd;
    END IF;
  ELSE
    v_currency := 'USD';
    IF coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := ceil(v_basis / v_rates.usdt_sell_gyd);
      v_facturado := v_amount * v_rates.usdt_sell_gyd;
      v_invertido := v_amount * v_rates.usdt_buy_gyd;
    END IF;
  END IF;

  -- With a rate missing there is no amount either (it is derived from one),
  -- so a pending entry records the deposit itself as its amount. 095's
  -- amount CHECK requires > 0, and the deposit is the one figure that is
  -- certainly known.
  IF v_amount IS NULL THEN
    v_amount := v_basis;
  END IF;

  INSERT INTO remittance_calculator_entries (
    account_id, source, status, operation_id, entry_date, customer_name,
    service, amount, amount_currency,
    cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id,
    facturado_gyd, invertido_gyd, retorno_gyd,
    missing_inputs, delivery_mode, actor_user_id, completed_at
  ) VALUES (
    v_op.account_id, 'completed_operation',
    CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END,
    v_op.id, coalesce(v_op.completed_at, clock_timestamp())::date, v_customer,
    v_service, v_amount, v_currency,
    v_rates.cup_global_rate, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd, v_rates.usdt_sell_gyd, v_rates.id,
    v_facturado, v_invertido,
    CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
    nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
    coalesce(v_op.completed_at, clock_timestamp())
  )
  ON CONFLICT (account_id, operation_id) WHERE source = 'completed_operation'
  DO UPDATE SET
    status          = EXCLUDED.status,
    entry_date      = EXCLUDED.entry_date,
    customer_name   = EXCLUDED.customer_name,
    service         = EXCLUDED.service,
    amount          = EXCLUDED.amount,
    amount_currency = EXCLUDED.amount_currency,
    cup_global_rate = EXCLUDED.cup_global_rate,
    cup_rate        = EXCLUDED.cup_rate,
    usdt_buy_gyd    = EXCLUDED.usdt_buy_gyd,
    usdt_sell_gyd   = EXCLUDED.usdt_sell_gyd,
    rate_version_id = EXCLUDED.rate_version_id,
    facturado_gyd   = EXCLUDED.facturado_gyd,
    invertido_gyd   = EXCLUDED.invertido_gyd,
    retorno_gyd     = EXCLUDED.retorno_gyd,
    missing_inputs  = EXCLUDED.missing_inputs,
    delivery_mode   = EXCLUDED.delivery_mode,
    actor_user_id   = EXCLUDED.actor_user_id,
    completed_at    = EXCLUDED.completed_at,
    voided_at       = NULL,
    void_reason     = NULL
  -- Only a voided entry is rewritten. A live entry is already the truth
  -- for this operation and its figures are frozen.
  WHERE remittance_calculator_entries.status = 'void'
  RETURNING id INTO v_entry_id;

  RETURN v_entry_id;
END;
$$;

-- ---------------------------------------------------------------------
-- 6. The trigger
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION remittance_operations_calculator_feed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason text;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  BEGIN
    IF NEW.status = 'completed' THEN
      PERFORM calculator_feed_operation(NEW.id);

    ELSIF OLD.status = 'completed' THEN
      v_reason := format('operation reverted from completed to %s', NEW.status);
      UPDATE remittance_calculator_entries
         SET status      = 'void',
             voided_at   = clock_timestamp(),
             void_reason = v_reason
       WHERE account_id = NEW.account_id
         AND operation_id = NEW.id
         AND source = 'completed_operation'
         AND status <> 'void';
    END IF;

  EXCEPTION WHEN OTHERS THEN
    -- A ledger problem must never cost the operator the delivery they just
    -- made. Record what broke and let the status change commit.
    BEGIN
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, action, actor, reason, before, after)
      VALUES (NEW.account_id, 'remittance_calculator_entries', NEW.id, 'calculator_feed_failed',
              wacrm_current_actor(), left(SQLERRM, 500),
              jsonb_build_object('status', OLD.status),
              jsonb_build_object('status', NEW.status, 'sqlstate', SQLSTATE));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'calculator feed failed and could not be audited for operation %: %', NEW.id, SQLERRM;
    END;
  END;

  RETURN NEW;
END;
$$;

ALTER TABLE remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit
  ADD CONSTRAINT remittance_admin_audit_action_chk
  CHECK (action IN (
    'automation_write_suppressed',
    'automation_completion_suppressed',
    'automation_revert_suppressed',
    'human_correction',
    'human_reassignment',
    'human_deposit_verification',
    'human_forced_verification',
    'human_delivery',
    'calculator_feed_failed',
    'calculator_pending_resolved'
  ));

-- `zzz_` so it sorts after 096's guard and 040's touch trigger: Postgres
-- fires same-event triggers in name order, and this one must see the final
-- committed status.
DROP TRIGGER IF EXISTS zzz_remittance_operations_calculator_feed ON remittance_operations;
CREATE TRIGGER zzz_remittance_operations_calculator_feed
  AFTER UPDATE OF status ON remittance_operations
  FOR EACH ROW EXECUTE FUNCTION remittance_operations_calculator_feed();

-- ---------------------------------------------------------------------
-- 7. Recovery: what the feed missed, and how to replay it
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW calculator_unfed_operations AS
  SELECT o.id            AS operation_id,
         o.account_id,
         o.completed_at,
         o.delivery_method,
         o.quoted_source_amount,
         calculator_service_for_operation(o.delivery_method) AS service
    FROM remittance_operations o
   CROSS JOIN calculator_feed_state s
   WHERE o.status = 'completed'
     AND o.completed_at >= s.feed_started_at
     AND calculator_service_for_operation(o.delivery_method) IS NOT NULL
     AND o.quoted_source_amount > 0
     AND NOT EXISTS (
           SELECT 1 FROM remittance_calculator_entries e
            WHERE e.account_id = o.account_id
              AND e.operation_id = o.id
              AND e.source = 'completed_operation'
              AND e.status <> 'void'
         );

COMMENT ON VIEW calculator_unfed_operations IS
  'Completed operations since feed_started_at that should have a live '
  'ledger entry and do not — the recovery list for crm_feed_calculator. '
  'Empty is the normal state.';

-- Idempotent replay, admin+. Safe to call on an operation that already has
-- a live entry: the feed only rewrites voided ones.
CREATE OR REPLACE FUNCTION crm_feed_calculator(p_operation_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id uuid;
  v_entry_id   uuid;
BEGIN
  SELECT account_id INTO v_account_id FROM remittance_operations WHERE id = p_operation_id;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'admin') THEN
    RAISE EXCEPTION 'not authorized to feed the calculator' USING ERRCODE = '42501';
  END IF;

  v_entry_id := calculator_feed_operation(p_operation_id);
  RETURN v_entry_id;
END;
$$;

REVOKE ALL ON FUNCTION crm_feed_calculator(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_feed_calculator(uuid) TO authenticated;
REVOKE ALL ON FUNCTION calculator_feed_operation(uuid) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION calculator_feed_operation(uuid) IS
  'Writes or revives the ledger entry for one completed operation, pricing '
  'it with the rates in force now. Internal: the trigger and '
  'crm_feed_calculator are its only callers.';
COMMENT ON FUNCTION crm_feed_calculator(uuid) IS
  'Admin+ idempotent replay of the ledger feed for one operation. Rewrites '
  'only a voided entry; a live one keeps its frozen figures.';
