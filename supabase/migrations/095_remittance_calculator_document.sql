-- 095 — Legacy port of the hermes in-CRM calculator's storage tables.
--
-- SCOPE: the /calculadora screen and its GET/POST API (ported AS-IS from
-- hermes, branch feature/chat-first-operations-c1) need exactly two
-- tables: remittance_calculator_entries (read-only from this screen) and
-- remittance_calculator_documents (read/write — the weekly "Tarifas
-- Globales" + "Registros de la Semana" document). Table, column and
-- constraint names below are byte-identical to hermes's own migrations so
-- the calculator data already on staging (created by the real hermes
-- release) keeps working unchanged when staging switches to this codebase.
--
-- Source (verbatim, minus one deliberate cut — see below):
--   hermes migration 111 (remittance_calculator_ledger.sql)      -> remittance_calculator_entries
--   hermes migration 114 (remittance_calculator_document.sql)    -> remittance_calculator_documents
--   hermes migration 115 (remittance_calculator_document_usdt_rates.sql), Part 1 only
--                                                                 -> the three optional USDT rate
--                                                                    columns + their CHECK constraints,
--                                                                    plus the two calculator_entries
--                                                                    snapshot-shape CHECK constraints
--
-- DELIBERATE CUT (documented in sdd/port-chat-operations-calculator's
-- apply-progress): hermes migrations 112, 113, 115's Part 2, 116 and 117 —
-- the "automatic completed-operation link", an AFTER UPDATE OF status
-- trigger on remittance_operations that auto-inserts a completed_operation
-- row into remittance_calculator_entries whenever a remesa completes,
-- plus its one-time backfill. The /calculadora screen and its API only
-- ever READ existing completed_operation rows (to show them read-only
-- under "Operaciones del chat"); nothing the user does on that screen
-- today depends on that trigger existing. Porting the auto-feed mechanism
-- is a separate, larger concern already tracked as its own SDD slice, with
-- its own append-only rate-versioning design (calculator_rate_versions)
-- that supersedes 115-117's simpler mutable-document approach — pulling
-- 112/113/116/117 in now would ship a throwaway trigger. Until that slice
-- ships, remittance_calculator_entries simply never receives a
-- completed_operation row here, exactly like a fresh hermes install before
-- any remesa has ever completed.
--
-- IDEMPOTENT BY DESIGN: this file must be safe to run against a database
-- that already has these exact tables/columns/constraints — for example
-- staging, which currently runs the real hermes release with migrations
-- 111-118 already applied, INCLUDING the completion-link trigger this file
-- does not touch. Every statement is CREATE TABLE/COLUMN IF NOT EXISTS or
-- guards its ADD CONSTRAINT via pg_constraint (PostgreSQL has no ADD
-- CONSTRAINT IF NOT EXISTS), so re-running this file is a no-op on such a
-- database, and it never CREATEs, REPLACEs or DROPs the completion-link
-- function/trigger that may already exist there.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- remittance_calculator_entries (hermes migration 111, verbatim)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.remittance_calculator_entries (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  account_id         uuid NOT NULL REFERENCES public.accounts(id),

  source             text NOT NULL,
  status             text NOT NULL,
  operation_id       uuid REFERENCES public.remittance_operations(id),

  entry_date         date NOT NULL,
  day_label          text,
  period_label       text,
  customer_name      text,

  service            text NOT NULL,

  amount             numeric NOT NULL,
  amount_currency    text NOT NULL,

  discount_pct       numeric,
  cost_gyd           numeric,
  sale_gyd           numeric,
  cup_rate           numeric,
  cup_global_rate    numeric,

  -- Accounting snapshot: the economic result AT THE TIME of this entry.
  -- Never recomputed later from current rates.
  facturado_gyd      numeric,
  invertido_gyd      numeric,
  retorno_gyd        numeric,

  actor_user_id      uuid REFERENCES auth.users(id),
  source_event_id    text,

  created_at         timestamptz NOT NULL DEFAULT now(),
  completed_at       timestamptz,

  CONSTRAINT remittance_calculator_entries_source_chk
    CHECK (source IN ('manual', 'completed_operation')),

  CONSTRAINT remittance_calculator_entries_status_chk
    CHECK (status IN ('completed', 'verified_pending')),

  -- manual: no structured operation behind it, and always inserted already
  -- resolved (a manual entry is not "pending" anything).
  -- completed_operation: must point at the structured operation it was
  -- derived from; it MAY sit in verified_pending before being confirmed.
  CONSTRAINT remittance_calculator_entries_source_shape_chk
    CHECK (
      (source = 'manual' AND operation_id IS NULL AND status = 'completed')
      OR
      (source = 'completed_operation' AND operation_id IS NOT NULL)
    ),

  -- Structural completeness, not economic completeness: a row that says
  -- it's completed must at least carry a completion timestamp.
  CONSTRAINT remittance_calculator_entries_completed_at_chk
    CHECK (status <> 'completed' OR completed_at IS NOT NULL),

  CONSTRAINT remittance_calculator_entries_service_chk
    CHECK (service IN (
      'CUP', 'ZELLE', 'MLC', 'CLASICA', 'TROPICAL',
      'USDT', 'RECARGA', 'SALDO_MOVIL', 'DIRECTO'
    )),

  CONSTRAINT remittance_calculator_entries_amount_currency_chk
    CHECK (char_length(amount_currency) BETWEEN 1 AND 12),

  CONSTRAINT remittance_calculator_entries_customer_name_chk
    CHECK (customer_name IS NULL OR char_length(trim(customer_name)) BETWEEN 1 AND 240),

  -- Postgres `numeric` (unlike IEEE float) can hold the special value NaN,
  -- and NaN sorts as larger than every finite value, so a plain lower-bound
  -- CHECK does not reject it. Pairing every bound with a finite upper limit
  -- closes that hole: NaN fails the upper-bound comparison and the row is
  -- rejected. `amount` must additionally be strictly positive.
  CONSTRAINT remittance_calculator_entries_amount_chk
    CHECK (amount > 0 AND amount < 1e15),

  CONSTRAINT remittance_calculator_entries_discount_pct_chk
    CHECK (discount_pct IS NULL OR (discount_pct >= 0 AND discount_pct <= 100)),

  CONSTRAINT remittance_calculator_entries_cost_gyd_chk
    CHECK (cost_gyd IS NULL OR (cost_gyd >= 0 AND cost_gyd < 1e15)),

  CONSTRAINT remittance_calculator_entries_sale_gyd_chk
    CHECK (sale_gyd IS NULL OR (sale_gyd >= 0 AND sale_gyd < 1e15)),

  CONSTRAINT remittance_calculator_entries_cup_rate_chk
    CHECK (cup_rate IS NULL OR (cup_rate > 0 AND cup_rate < 1e9)),

  CONSTRAINT remittance_calculator_entries_cup_global_rate_chk
    CHECK (cup_global_rate IS NULL OR (cup_global_rate > 0 AND cup_global_rate < 1e9)),

  CONSTRAINT remittance_calculator_entries_facturado_gyd_chk
    CHECK (facturado_gyd IS NULL OR (facturado_gyd >= 0 AND facturado_gyd < 1e15)),

  CONSTRAINT remittance_calculator_entries_invertido_gyd_chk
    CHECK (invertido_gyd IS NULL OR (invertido_gyd >= 0 AND invertido_gyd < 1e15)),

  -- Unlike cost/sale/facturado/invertido, retorno_gyd is a net result and
  -- the calculator's formula allows it to be negative (a loss on the
  -- operation), so this is the one *_gyd column bounded on both sides
  -- around zero instead of floored at 0. The finite bounds on both ends
  -- still close the NaN hole described above.
  CONSTRAINT remittance_calculator_entries_retorno_gyd_chk
    CHECK (retorno_gyd IS NULL OR (retorno_gyd > -1e15 AND retorno_gyd < 1e15)),

  CONSTRAINT remittance_calculator_entries_source_event_id_chk
    CHECK (source_event_id IS NULL OR char_length(source_event_id) > 0)
);

-- One ledger row per structured operation per account. Partial: only
-- applies to completed_operation rows, since manual rows never carry an
-- operation_id (enforced above). Doubles as the account+operation lookup
-- index, so no separate operation index is added.
CREATE UNIQUE INDEX IF NOT EXISTS remittance_calculator_entries_account_operation_uk
  ON public.remittance_calculator_entries (account_id, operation_id)
  WHERE source = 'completed_operation';

-- Idempotency key for whatever future writer produces these rows.
CREATE UNIQUE INDEX IF NOT EXISTS remittance_calculator_entries_account_source_event_uk
  ON public.remittance_calculator_entries (account_id, source_event_id)
  WHERE source_event_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS remittance_calculator_entries_account_period_idx
  ON public.remittance_calculator_entries (account_id, period_label, entry_date);

CREATE INDEX IF NOT EXISTS remittance_calculator_entries_account_status_idx
  ON public.remittance_calculator_entries (account_id, status);

-- Rows that have reached status='completed' are append-only: a financial
-- close must be able to trust that a completed row never silently changes.
-- Rows still in 'verified_pending' are NOT touched by this trigger, so a
-- future writer remains free to edit them, including flipping them to
-- 'completed' (that UPDATE runs with OLD.status = 'verified_pending', which
-- this trigger never blocks).
CREATE OR REPLACE FUNCTION public.remittance_calculator_entries_lock_completed()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF OLD.status = 'completed' THEN
    RAISE EXCEPTION 'remittance_calculator_entries: completed rows are append-only'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  -- NEW is NULL for DELETE (it only exists for INSERT/UPDATE); returning it
  -- unconditionally would silently cancel every DELETE, including the ones
  -- on verified_pending rows this trigger is meant to allow.
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS remittance_calculator_entries_append_only ON public.remittance_calculator_entries;
CREATE TRIGGER remittance_calculator_entries_append_only
  BEFORE UPDATE OR DELETE ON public.remittance_calculator_entries
  FOR EACH ROW EXECUTE FUNCTION public.remittance_calculator_entries_lock_completed();

ALTER TABLE public.remittance_calculator_entries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.remittance_calculator_entries FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.remittance_calculator_entries TO service_role;

COMMENT ON TABLE public.remittance_calculator_entries IS
  'Internal financial control ledger for the remittance calculator. Records manual entries and completed-operation snapshots for accounting purposes ONLY; a row here never transfers money or triggers a transfer. completed rows are append-only (see remittance_calculator_entries_append_only trigger); verified_pending rows may still be edited or promoted to completed by a future writer. No completed_operation writer exists yet in this codebase (see the deliberate-cut note at the top of this file): WRITES_CONNECTED=NO.';

-- ---------------------------------------------------------------------
-- remittance_calculator_documents (hermes migration 114, verbatim)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.remittance_calculator_documents (
  account_id uuid PRIMARY KEY REFERENCES public.accounts(id),
  raw_text text NOT NULL DEFAULT '',
  period_label text NOT NULL DEFAULT '',
  cup_global_rate numeric NOT NULL DEFAULT 3.0,
  updated_by uuid REFERENCES auth.users(id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT remittance_calculator_documents_rate_chk
    CHECK (cup_global_rate > 0 AND cup_global_rate < 1e9)
);

ALTER TABLE public.remittance_calculator_documents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.remittance_calculator_documents FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.remittance_calculator_documents TO service_role;

COMMENT ON TABLE public.remittance_calculator_documents IS
  'Weekly calculator document ("Tarifas Globales" + "Registros de la Semana") ported as-is from the hermes in-CRM calculator. Manual bookkeeping only; never transfers money.';

-- ---------------------------------------------------------------------
-- USDT global rate columns (hermes migration 115, Part 1, verbatim)
-- ---------------------------------------------------------------------

ALTER TABLE public.remittance_calculator_documents
  ADD COLUMN IF NOT EXISTS usdt_buy_gyd numeric,
  ADD COLUMN IF NOT EXISTS usdt_sell_gyd numeric,
  ADD COLUMN IF NOT EXISTS usdt_sell_cup numeric;

-- Same NaN-closing shape as the existing cup_global_rate_chk: a plain lower
-- bound does not reject Postgres numeric NaN, so every bound is paired with
-- a finite upper limit. All three are optional (NULL = not yet entered).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'remittance_calculator_documents_usdt_buy_gyd_chk'
  ) THEN
    ALTER TABLE public.remittance_calculator_documents
      ADD CONSTRAINT remittance_calculator_documents_usdt_buy_gyd_chk
        CHECK (usdt_buy_gyd IS NULL OR (usdt_buy_gyd > 0 AND usdt_buy_gyd < 1e9));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'remittance_calculator_documents_usdt_sell_gyd_chk'
  ) THEN
    ALTER TABLE public.remittance_calculator_documents
      ADD CONSTRAINT remittance_calculator_documents_usdt_sell_gyd_chk
        CHECK (usdt_sell_gyd IS NULL OR (usdt_sell_gyd > 0 AND usdt_sell_gyd < 1e9));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'remittance_calculator_documents_usdt_sell_cup_chk'
  ) THEN
    ALTER TABLE public.remittance_calculator_documents
      ADD CONSTRAINT remittance_calculator_documents_usdt_sell_cup_chk
        CHECK (usdt_sell_cup IS NULL OR (usdt_sell_cup > 0 AND usdt_sell_cup < 1e9));
  END IF;
END $$;

COMMENT ON COLUMN public.remittance_calculator_documents.usdt_buy_gyd IS
  'Global reference rate: GYD paid per USDT bought ("Compra USDT (GYD)").';
COMMENT ON COLUMN public.remittance_calculator_documents.usdt_sell_gyd IS
  'Global reference rate: GYD charged per USDT sold via Zelle ("Venta USDT/Zelle (GYD)").';
COMMENT ON COLUMN public.remittance_calculator_documents.usdt_sell_cup IS
  'Global reference rate: CUP charged per USDT sold ("Venta USDT (CUP)").';

-- ---------------------------------------------------------------------
-- Snapshot-shape constraints on remittance_calculator_entries (hermes
-- migration 115, Part 2 — CONSTRAINTS ONLY, not the trigger function that
-- accompanied them there; see the deliberate-cut note at the top).
-- ---------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'remittance_calculator_entries_pending_has_no_snapshot_chk'
  ) THEN
    ALTER TABLE public.remittance_calculator_entries
      ADD CONSTRAINT remittance_calculator_entries_pending_has_no_snapshot_chk
        CHECK (
          status <> 'verified_pending'
          OR (facturado_gyd IS NULL AND invertido_gyd IS NULL AND retorno_gyd IS NULL)
        );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'remittance_calculator_entries_completed_has_snapshot_chk'
  ) THEN
    ALTER TABLE public.remittance_calculator_entries
      ADD CONSTRAINT remittance_calculator_entries_completed_has_snapshot_chk
        CHECK (
          status <> 'completed'
          OR (facturado_gyd IS NOT NULL AND invertido_gyd IS NOT NULL AND retorno_gyd IS NOT NULL)
        );
  END IF;
END $$;
