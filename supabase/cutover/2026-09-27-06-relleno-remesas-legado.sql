-- =====================================================================
-- Cutover 2026-09-27 — STEP (WRITE): legacy remesa parity backfill.
--
-- RUN AFTER ALL MIGRATIONS, INCLUDING 121 AND 123. Fills, ONLY where the
-- field is still NULL, the structured columns the operations panel reads
-- (crm_operaciones_de_conversacion, 097/100/102; rendered by
-- src/components/inbox/operations/remittance-operation-card.tsx's
-- `computeSummaryAmount`/`resolveBeneficiaryAmount`) on legacy
-- `remittance_operations` rows with `service_type = 'remesa'`, so they
-- render an amount like a panel-made operation instead of "amount
-- missing". NEVER overwrites or deletes an existing value.
--
-- SCOPE, exactly:
--   - `service_type = 'remesa'`, `status <> 'cancelled'` (a cancelled
--     remesa is never shown as needing completion or an amount in the
--     panel — see the header of `crm_operaciones_de_conversacion`, which
--     only lists non-terminal operations, and the history card, which
--     never treats a cancelled row as "amount missing"; backfilling dead
--     rows adds audit noise for zero render benefit).
--   - `quoted_destination_amount IS NULL` only.
--   - Exactly ONE `vigente` beneficiary, or ZERO beneficiaries with a
--     known `delivery_method`. TWO OR MORE beneficiaries (the
--     `multiple_distribution`/"reparto" case) are OUT OF SCOPE: the panel
--     never falls back to an operation-level amount for 2+ beneficiaries
--     (`resolveBeneficiaryAmount`/`computeSummaryAmount`, card.tsx:142-194
--     — each beneficiary shows its OWN `amount`, already set by
--     `cerebro_parsear_beneficiarios`' REPARTO parser, 042). Filling a
--     mixed-currency operation-level amount there would be misleading,
--     not helpful.
--
-- BENEFICIARY.AMOUNT IS DELIBERATELY NOT WRITTEN for the single-
-- beneficiary case: `resolveBeneficiaryAmount` (card.tsx:142-148) already
-- falls back to the operation's `quoted_destination_amount` when the
-- beneficiary's own `amount` is NULL and it is the operation's only
-- beneficiary. Filling the operation-level field is enough for the panel
-- to render correctly; writing the same number a second time onto
-- `remittance_beneficiaries.amount` would be a duplicate write with no
-- rendering benefit and one more place a future correction could drift
-- from. (For the zero-beneficiary case there is no beneficiary row to
-- write regardless.)
--
-- CURRENCY DECISION (never guessed beyond this rule):
--   zelle / clasica / tropical (beneficiary type, or delivery_method when
--     there is no beneficiary row at all) -> USD
--   cuban_card (beneficiary type, or delivery_method)                -> CUP
--   anything else (multiple_distribution, an unknown/absent type AND an
--     absent delivery_method, or an operation whose destination_currency
--     is already set to something that disagrees with this rule) is left
--     NULL and listed by the final SELECT below — never guessed.
--
-- AMOUNT = quoted_source_amount x the rate in force on the operation's
-- `created_at`, AS A GUYANA CALENDAR DAY (`created_at AT TIME ZONE
-- 'America/Guyana'`), read from `tasas_historico` (the exact rows 113
-- archived from the old `tasas` table): the newest row for the matching
-- `moneda` ('usd' for the USD rails, 'gyd' for the CUP rail — 113's own
-- mapping) with `fecha <= that Guyana day`. NEVER hardcoded — an
-- operation older than the earliest historical rate for its rail would
-- find no row and is left undecided (none exist in production today,
-- verified against this environment's `tasas_historico`, but the query
-- does not assume that).
--
-- ROUNDING (business rule, migrations 100/107/111 — verbatim from
-- `crm_calcular_monto_destino`): CUP rounds to the nearest integer
-- (`round`), USD rails round DOWN (`floor`) — the business never hands
-- over more dollars than a fractional deposit actually bought.
--
-- delivery_method: filled from the single beneficiary's type, ONLY when
-- currently NULL — the same value `cerebro_sync_benef_trigger` (042)
-- already writes for a freshly-synced beneficiary
-- (`delivery_method = coalesce(lower(entrega_usd_note), beneficiary_type,
-- delivery_method)`), so a legacy row ends up indistinguishable from one
-- the trigger wrote itself.
--
-- PROVENANCE COLUMNS (100): `quoted_destination_origin` has a CHECK
-- constraint allowing only 'calculated' or 'manual' — 'legacy_backfill'
-- is NOT a legal value (verified against 096/100's DDL), so this script
-- writes 'manual' (a human-run maintenance script is exactly that, not
-- the live `crm_calcular_monto_destino` automation). `quoted_destination_
-- rate` is preserved with the ACTUAL historical rate used (not NULL):
-- 100's own `trg_zz_destino_manual_origin` trigger would otherwise force
-- `quoted_destination_origin = 'manual'` AND null out
-- `quoted_destination_rate` on ANY write to `quoted_destination_amount`
-- outside of `wacrm.calc_destino = 'on'` (see that trigger's guard). This
-- script sets that same session GUC for the duration of its own UPDATE so
-- its OWN explicit 'manual'/rate values reach the row unmodified, instead
-- of losing the rate to that guard. This is a deliberate, narrowly-scoped
-- reuse of the existing recursion-guard GUC, not a bypass of any lock or
-- authorization check.
--
-- WHO THIS WRITE RUNS AS: `wacrm.origin = 'admin'` is set for the whole
-- transaction, exactly as 2026-09-27-02 does, so 096's guards see a human
-- actor. Side effect, by design of 096 (not something this script codes
-- itself): the fields this script changes on a previously-unlocked row
-- (`destination_currency`, `delivery_method`, `quoted_destination_amount`)
-- become entries in `admin_locked_fields`, exactly as if an operator had
-- corrected them by hand — future automation can no longer silently
-- overwrite a value this backfill just set. Consistent with "never
-- overwrite legacy data again" once it has been filled once.
--
-- TRIGGERS THAT MUST NOT FIRE — VERIFIED, NOT DISABLED: this script never
-- writes `status`, so `trg_notify_operation_status_change` (114),
-- `trg_notify_operation_incidencia` (114) and
-- `zzz_remittance_operations_calculator_feed` (104) — all three scoped to
-- `AFTER ... UPDATE OF status` — never fire; no customer notification is
-- queued and no ledger entry is created or voided. Asserted below rather
-- than assumed: the pg_net queue and `remittance_calculator_entries`
-- row counts are compared before/after and the transaction aborts if
-- either moved. No trigger is disabled — none needed to be.
--
-- BENEFICIARIES FROM NOTES (~1 case, task estimate; 0 on this dump — see
-- report): for a `remesa` op with zero `vigente` beneficiaries and a
-- linked deal, calls the EXISTING `cerebro_sync_beneficiarios(deal_id)`
-- (042) — the same function n8n's own trigger calls — so a deal whose
-- notes DO carry a beneficiary block that was never synced gets it now.
-- A no-op wherever the notes have nothing to parse (idempotent already,
-- 042's own `ON CONFLICT ... DO NOTHING`).
--
-- LOG / UNDO: every field this script actually changes is recorded in
-- `cutover_legacy_backfill_2026_09_27` (created below) with the old and
-- new value. The footer has the exact UNDO statement.
--
-- IDEMPOTENT: every write is gated on the target field still being NULL;
-- a second run changes zero rows (verified in the rehearsal, R3).
-- =====================================================================
BEGIN;

-- `wacrm.origin` is NOT set here on purpose: section 1 must keep the real
-- automation identity (see section 2's comment).

DO $$
BEGIN
  IF to_regclass('public.remittance_operations') IS NULL THEN
    RAISE EXCEPTION 'remittance_operations does not exist — apply the base migrations first';
  END IF;
  IF to_regclass('public.remittance_beneficiaries') IS NULL THEN
    RAISE EXCEPTION 'remittance_beneficiaries does not exist — apply migration 042 first';
  END IF;
  IF to_regclass('public.tasas_historico') IS NULL THEN
    RAISE EXCEPTION 'tasas_historico does not exist — apply migration 113 first (this file runs after ALL migrations)';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS cutover_legacy_backfill_2026_09_27 (
  id           bigserial PRIMARY KEY,
  operation_id uuid NOT NULL,
  table_name   text NOT NULL,
  field        text NOT NULL,
  old_value    text,
  new_value    text,
  at           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE cutover_legacy_backfill_2026_09_27 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON cutover_legacy_backfill_2026_09_27 FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 0. Guard rails the triggers this script must NOT fire are checked
--    against: snapshot the two counters before touching anything.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_net_before  bigint;
  v_led_before  bigint;
BEGIN
  v_net_before := CASE WHEN to_regclass('net.http_request_queue') IS NOT NULL
                       THEN (SELECT count(*) FROM net.http_request_queue) END;
  v_led_before := (SELECT count(*) FROM remittance_calculator_entries);
  PERFORM set_config('wacrm.backfill_net_before', coalesce(v_net_before::text, ''), true);
  PERFORM set_config('wacrm.backfill_led_before', v_led_before::text, true);
END $$;

-- ---------------------------------------------------------------------
-- 1. Beneficiaries from deal notes — zero-beneficiary remesas whose deal
--    notes actually carry a beneficiary block cerebro_sync_beneficiarios
--    hasn't synced yet.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_row     RECORD;
  v_before  int;
  v_after   int;
BEGIN
  FOR v_row IN
    SELECT o.id AS operation_id, o.deal_id
      FROM remittance_operations o
     WHERE o.service_type = 'remesa'
       AND o.status <> 'cancelled'
       AND o.quoted_destination_amount IS NULL
       AND o.deal_id IS NOT NULL
       AND NOT EXISTS (
             SELECT 1 FROM remittance_beneficiaries b
              WHERE b.operation_id = o.id AND b.status = 'vigente')
  LOOP
    SELECT count(*) INTO v_before FROM remittance_beneficiaries WHERE operation_id = v_row.operation_id;
    PERFORM cerebro_sync_beneficiarios(v_row.deal_id);
    SELECT count(*) INTO v_after FROM remittance_beneficiaries WHERE operation_id = v_row.operation_id;

    IF v_after > v_before THEN
      INSERT INTO cutover_legacy_backfill_2026_09_27 (operation_id, table_name, field, old_value, new_value)
      VALUES (v_row.operation_id, 'remittance_beneficiaries', 'cerebro_sync_beneficiarios (row count)',
              v_before::text, v_after::text);
      RAISE NOTICE '[legacy-backfill] operation % gained % beneficiary row(s) from deal % notes',
        v_row.operation_id, v_after - v_before, v_row.deal_id;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 2. Destination currency / amount / rate / origin, and delivery_method.
-- ---------------------------------------------------------------------
-- Admin identity scoped to THIS section only (review fix 2026-09-27). If it
-- were set for the whole transaction, a beneficiary added by section 1's
-- cerebro_sync_beneficiarios would make migration 100's recalc trigger write
-- an automatic amount that 096's guard then locks as if a human typed it,
-- excluding that op from automatic recalculation forever.
SELECT set_config('wacrm.origin', 'admin', true);
SELECT set_config('wacrm.calc_destino', 'on', true); -- see header: preserves quoted_destination_rate/origin as set below

WITH ben_counts AS (
  SELECT operation_id, count(*) AS n
    FROM remittance_beneficiaries
   WHERE status = 'vigente'
   GROUP BY operation_id
),
single_ben AS (
  SELECT b.operation_id, b.beneficiary_type
    FROM remittance_beneficiaries b
    JOIN ben_counts c ON c.operation_id = b.operation_id AND c.n = 1
   WHERE b.status = 'vigente'
),
candidates AS (
  SELECT
    o.id                    AS operation_id,
    o.created_at,
    o.quoted_source_amount,
    o.destination_currency  AS existing_currency,
    o.delivery_method       AS existing_delivery,
    COALESCE(
      sb.beneficiary_type,
      CASE WHEN NOT EXISTS (SELECT 1 FROM ben_counts bc WHERE bc.operation_id = o.id)
           THEN o.delivery_method END
    ) AS decisive_type
  FROM remittance_operations o
  LEFT JOIN single_ben sb ON sb.operation_id = o.id
 WHERE o.service_type = 'remesa'
   -- COMPLETED only (review fix 2026-09-27): an OPEN remesa must stay eligible
   -- for migration 100's automatic recalculation; writing it here as admin
   -- would lock its amount and leave it stale after a later deposit.
   AND o.status = 'completed'
   AND o.quoted_destination_amount IS NULL
),
decided AS (
  SELECT c.*,
         CASE WHEN c.decisive_type IN ('zelle', 'clasica', 'tropical') THEN 'USD'
              WHEN c.decisive_type = 'cuban_card'                      THEN 'CUP'
         END AS new_currency
    FROM candidates c
   WHERE c.decisive_type IN ('zelle', 'clasica', 'tropical', 'cuban_card')
     -- never override a pre-existing destination_currency that disagrees
     -- with what this rule would pick — that is a conflict to report,
     -- not to silently resolve.
     AND (c.existing_currency IS NULL OR c.existing_currency = (
           CASE WHEN c.decisive_type IN ('zelle', 'clasica', 'tropical') THEN 'USD'
                WHEN c.decisive_type = 'cuban_card'                      THEN 'CUP' END))
),
rated AS (
  SELECT d.*,
         (SELECT th.tasa_cup
            FROM tasas_historico th
           WHERE th.moneda = CASE WHEN d.new_currency = 'USD' THEN 'usd' ELSE 'gyd' END
             AND th.fecha <= (d.created_at AT TIME ZONE 'America/Guyana')::date
           ORDER BY th.fecha DESC
           LIMIT 1) AS rate
    FROM decided d
),
computed AS (
  SELECT operation_id,
         new_currency,
         decisive_type,
         existing_currency,
         existing_delivery,
         rate AS new_rate,
         CASE WHEN new_currency = 'USD' THEN floor(quoted_source_amount / rate)
              ELSE round(quoted_source_amount * rate)
         END AS new_amount
    FROM rated
   WHERE rate IS NOT NULL
     AND quoted_source_amount IS NOT NULL
     AND quoted_source_amount > 0
),
updated AS (
  UPDATE remittance_operations o
     SET destination_currency      = COALESCE(o.destination_currency, c.new_currency),
         delivery_method           = COALESCE(o.delivery_method, c.decisive_type),
         quoted_destination_amount = c.new_amount,
         quoted_destination_rate   = c.new_rate,
         quoted_destination_origin = 'manual'
    FROM computed c
   WHERE o.id = c.operation_id
     AND o.quoted_destination_amount IS NULL
  RETURNING o.id AS operation_id,
            c.new_currency, c.new_amount, c.new_rate, c.decisive_type,
            c.existing_currency, c.existing_delivery
)
INSERT INTO cutover_legacy_backfill_2026_09_27 (operation_id, table_name, field, old_value, new_value)
SELECT operation_id, 'remittance_operations', 'destination_currency', NULL, new_currency
  FROM updated WHERE existing_currency IS NULL
UNION ALL
SELECT operation_id, 'remittance_operations', 'quoted_destination_amount', NULL, new_amount::text FROM updated
UNION ALL
SELECT operation_id, 'remittance_operations', 'quoted_destination_rate', NULL, new_rate::text FROM updated
UNION ALL
SELECT operation_id, 'remittance_operations', 'quoted_destination_origin', NULL, 'manual' FROM updated
UNION ALL
SELECT operation_id, 'remittance_operations', 'delivery_method', NULL, decisive_type
  FROM updated WHERE existing_delivery IS NULL;

SELECT set_config('wacrm.calc_destino', 'off', true);

-- ---------------------------------------------------------------------
-- 3. Guard rails: the two counters this script must never move.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_net_before  text    := current_setting('wacrm.backfill_net_before', true);
  v_led_before  bigint  := current_setting('wacrm.backfill_led_before', true)::bigint;
  v_net_after   bigint;
  v_led_after   bigint;
BEGIN
  v_led_after := (SELECT count(*) FROM remittance_calculator_entries);
  IF v_led_after IS DISTINCT FROM v_led_before THEN
    RAISE EXCEPTION 'remittance_calculator_entries row count changed (% -> %) — this backfill must never feed the ledger. Aborting.',
      v_led_before, v_led_after;
  END IF;

  IF to_regclass('net.http_request_queue') IS NOT NULL THEN
    v_net_after := (SELECT count(*) FROM net.http_request_queue);
    IF nullif(v_net_before, '')::bigint IS DISTINCT FROM v_net_after THEN
      RAISE EXCEPTION 'net.http_request_queue row count changed (% -> %) — this backfill must never queue a customer notification. Aborting.',
        v_net_before, v_net_after;
    END IF;
  ELSE
    RAISE NOTICE '[legacy-backfill] net.http_request_queue not present in this environment — pg_net not installed; skipping that half of the assertion (remittance_calculator_entries was still checked).';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 4. Undecidable rows — never guessed, always listed.
-- ---------------------------------------------------------------------
SELECT o.id AS operation_id, o.status, o.service_type, o.delivery_method,
       o.destination_currency AS existing_destination_currency,
       o.quoted_source_amount,
       (SELECT count(*) FROM remittance_beneficiaries b
         WHERE b.operation_id = o.id AND b.status = 'vigente') AS vigente_beneficiaries,
       (SELECT string_agg(DISTINCT b.beneficiary_type, ',') FROM remittance_beneficiaries b
         WHERE b.operation_id = o.id AND b.status = 'vigente') AS beneficiary_types,
       CASE
         WHEN o.quoted_source_amount IS NULL OR o.quoted_source_amount <= 0
           THEN 'no positive source amount to convert'
         WHEN (SELECT count(*) FROM remittance_beneficiaries b
                WHERE b.operation_id = o.id AND b.status = 'vigente') >= 2
           THEN '2+ beneficiaries — each renders its own amount, out of scope'
         WHEN (SELECT count(*) FROM remittance_beneficiaries b
                WHERE b.operation_id = o.id AND b.status = 'vigente') = 1
           THEN 'single beneficiary of a type this rule does not map to USD/CUP ('
                || (SELECT b.beneficiary_type FROM remittance_beneficiaries b
                     WHERE b.operation_id = o.id AND b.status = 'vigente' LIMIT 1) || ')'
         WHEN o.delivery_method IS NULL
           THEN 'no beneficiary and no delivery_method to infer currency from'
         ELSE 'no beneficiary, and delivery_method does not map to USD/CUP (' || o.delivery_method || ')'
       END AS reason
  FROM remittance_operations o
 WHERE o.service_type = 'remesa'
   AND o.status <> 'cancelled'
   AND o.quoted_destination_amount IS NULL
 ORDER BY o.created_at;

COMMIT;

-- =====================================================================
-- VERIFY (after this file runs):
--   SELECT count(*) FROM remittance_operations
--    WHERE service_type='remesa' AND status<>'cancelled'
--      AND quoted_destination_amount IS NULL;
--   -- should equal exactly the row count of section 4's undecidable list
--
-- RE-RUN TO PROVE IDEMPOTENCE: every UPDATE above is gated on
-- `quoted_destination_amount IS NULL`; a second run finds nothing left to
-- fill for any operation this run touched and inserts zero new log rows.
--
-- UNDO (clears exactly what this script set, using its own log; leaves any
-- beneficiary rows cerebro_sync_beneficiarios added, since those are real
-- notes-derived data). TWO passes, tested in the rehearsal (2026-09-27): the
-- admin write that clears the values makes 096's guard re-lock them, so the
-- second pass drops exactly those lock keys. `array_agg(field)` per operation
-- matters: a plain `UPDATE … FROM log` would apply only ONE of an operation's
-- several log rows and leave fields uncleared. Run inside BEGIN … COMMIT:
--   SELECT set_config('wacrm.origin', 'admin', true);
--   SELECT set_config('wacrm.calc_destino', 'on', true);
--   WITH logged AS (
--     SELECT operation_id, array_agg(DISTINCT field) AS fields
--       FROM cutover_legacy_backfill_2026_09_27
--      WHERE table_name = 'remittance_operations'
--      GROUP BY operation_id
--   )
--   UPDATE remittance_operations o
--      SET quoted_destination_amount = CASE WHEN 'quoted_destination_amount' = ANY (l.fields) THEN NULL ELSE o.quoted_destination_amount END,
--          quoted_destination_rate   = CASE WHEN 'quoted_destination_rate'   = ANY (l.fields) THEN NULL ELSE o.quoted_destination_rate END,
--          quoted_destination_origin = CASE WHEN 'quoted_destination_origin' = ANY (l.fields) THEN NULL ELSE o.quoted_destination_origin END,
--          destination_currency      = CASE WHEN 'destination_currency'      = ANY (l.fields) THEN NULL ELSE o.destination_currency END,
--          delivery_method           = CASE WHEN 'delivery_method'           = ANY (l.fields) THEN NULL ELSE o.delivery_method END,
--          admin_locked_fields       = coalesce(o.admin_locked_fields, '{}'::jsonb) - l.fields
--     FROM logged l
--    WHERE l.operation_id = o.id;
--   -- Second pass: the admin write above made 096's guard re-lock the cleared
--   -- fields; drop exactly those lock keys (this UPDATE touches no locked field).
--   WITH logged AS (
--     SELECT operation_id, array_agg(DISTINCT field) AS fields
--       FROM cutover_legacy_backfill_2026_09_27
--      WHERE table_name = 'remittance_operations'
--      GROUP BY operation_id
--   )
--   UPDATE remittance_operations o
--      SET admin_locked_fields = o.admin_locked_fields - l.fields
--     FROM logged l
--    WHERE l.operation_id = o.id;
-- =====================================================================
