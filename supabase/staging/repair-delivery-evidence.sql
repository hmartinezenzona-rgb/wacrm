-- repair-delivery-evidence.sql — one-off repair for ledger entries fed
-- before migration 108 reordered crm_entregar_operacion.
--
-- WHAT IS BROKEN
-- Entries fed before 108 carry NULL delivery_mode / actor_user_id, because
-- the calculator feed read the operation row one statement before the
-- delivery evidence was stamped on it. Every other figure is correct.
--
-- WHY THIS IS NOT A MIGRATION
-- 095's append-only trigger (as amended by 104) permits exactly one change
-- to a completed entry: voiding it, with every figure untouched. So the
-- only route to refill delivery_mode is void -> let calculator_feed_operation
-- revive the row. The revive recomputes every figure from the rate version
-- current AT THAT MOMENT. Where rates have moved since the entry was
-- written, that silently rewrites money — which is precisely what the
-- append-only guard exists to refuse. A migration cannot know the rate drift
-- of an environment it has not run in yet, so this stays a deliberate,
-- per-environment operation a human runs and reads the output of.
--
-- THE SAFETY RULE
-- This script repairs a row ONLY if the revive reproduces every recorded
-- figure byte-identically (amount, facturado, invertido, retorno, currency,
-- service, each rate, and the rate_version_id). If a single one differs, it
-- RAISEs and the whole transaction rolls back, repairing nothing. It is
-- therefore safe to attempt anywhere: where rates have drifted it refuses
-- rather than rewrites.
--
-- HOW TO RUN (never against production without reading the output first):
--   BEGIN;
--   \i supabase/staging/repair-delivery-evidence.sql
--   -- read the NOTICEs, then:
--   COMMIT;   -- or ROLLBACK; to abandon
--
-- It is idempotent: once repaired, a row no longer matches and is skipped.

DO $$
DECLARE
  r            record;
  v_before     remittance_calculator_entries;
  v_after      remittance_calculator_entries;
  v_repaired   integer := 0;
BEGIN
  FOR r IN
    SELECT e.id AS entry_id, e.operation_id, o.delivery_mode AS op_mode, o.delivered_by AS op_actor
      FROM remittance_calculator_entries e
      JOIN remittance_operations o ON o.id = e.operation_id
     WHERE e.source = 'completed_operation'
       AND e.status = 'completed'
       AND ((e.delivery_mode IS NULL AND o.delivery_mode IS NOT NULL)
         OR (e.actor_user_id  IS NULL AND o.delivered_by  IS NOT NULL))
     ORDER BY e.id
  LOOP
    SELECT * INTO v_before FROM remittance_calculator_entries WHERE id = r.entry_id;

    -- Void it. The append-only guard allows this and nothing else, and it
    -- independently rejects the void if any figure moved.
    UPDATE remittance_calculator_entries
       SET status      = 'void',
           voided_at   = clock_timestamp(),
           void_reason = 'repair: re-feeding to recover delivery evidence lost to the pre-108 ordering'
     WHERE id = r.entry_id;

    -- Revive it. The feed's ON CONFLICT ... DO UPDATE fires only on a
    -- voided row, recomputing every column from the operation — which now
    -- carries the delivery evidence all along.
    PERFORM calculator_feed_operation(r.operation_id);

    SELECT * INTO v_after FROM remittance_calculator_entries WHERE id = r.entry_id;

    IF v_after.status <> 'completed' THEN
      RAISE EXCEPTION 'repair aborted: entry % did not come back as completed (got %) — nothing repaired',
        r.entry_id, v_after.status;
    END IF;

    IF v_after.amount          IS DISTINCT FROM v_before.amount
       OR v_after.amount_currency IS DISTINCT FROM v_before.amount_currency
       OR v_after.service       IS DISTINCT FROM v_before.service
       OR v_after.facturado_gyd IS DISTINCT FROM v_before.facturado_gyd
       OR v_after.invertido_gyd IS DISTINCT FROM v_before.invertido_gyd
       OR v_after.retorno_gyd   IS DISTINCT FROM v_before.retorno_gyd
       OR v_after.cup_global_rate IS DISTINCT FROM v_before.cup_global_rate
       OR v_after.cup_rate      IS DISTINCT FROM v_before.cup_rate
       OR v_after.usdt_buy_gyd  IS DISTINCT FROM v_before.usdt_buy_gyd
       OR v_after.usdt_sell_gyd IS DISTINCT FROM v_before.usdt_sell_gyd
       OR v_after.rate_version_id IS DISTINCT FROM v_before.rate_version_id
    THEN
      RAISE EXCEPTION
        'repair aborted: rates drifted, re-feeding entry % would rewrite its figures (amount % -> %, facturado % -> %, invertido % -> %, retorno % -> %, rate_version % -> %). NOTHING was repaired.',
        r.entry_id,
        v_before.amount, v_after.amount,
        v_before.facturado_gyd, v_after.facturado_gyd,
        v_before.invertido_gyd, v_after.invertido_gyd,
        v_before.retorno_gyd, v_after.retorno_gyd,
        v_before.rate_version_id, v_after.rate_version_id;
    END IF;

    IF v_after.delivery_mode IS DISTINCT FROM r.op_mode
       OR v_after.actor_user_id IS DISTINCT FROM r.op_actor
    THEN
      RAISE EXCEPTION 'repair aborted: entry % still lacks the delivery evidence after re-feeding (delivery_mode %, actor_user_id %) — nothing repaired',
        r.entry_id, v_after.delivery_mode, v_after.actor_user_id;
    END IF;

    v_repaired := v_repaired + 1;
    RAISE NOTICE 'repaired entry % (operation %): delivery_mode=%, actor_user_id=%; every figure unchanged',
      r.entry_id, r.operation_id, v_after.delivery_mode, v_after.actor_user_id;
  END LOOP;

  IF v_repaired = 0 THEN
    RAISE NOTICE 'repair-delivery-evidence: nothing to repair';
  ELSE
    RAISE NOTICE 'repair-delivery-evidence: % entry(ies) repaired, all figures preserved', v_repaired;
  END IF;
END $$;
