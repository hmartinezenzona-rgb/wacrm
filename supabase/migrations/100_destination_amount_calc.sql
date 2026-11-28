-- =====================================================================
-- 100 — Auto-calculate destination amount for single-beneficiary remesas
--
-- PURPOSE: production never stores a destination amount today — n8n's bot
-- computes it on the fly (GYD -> USD for Zelle, GYD -> CUP for cuban card)
-- and only ever quotes it in chat, never writes it back to
-- remittance_operations/remittance_beneficiaries. This migration adds that
-- write path inside the CRM itself, for the one case the bot's own rule is
-- unambiguous: exactly one current (`vigente`) beneficiary on a `remesa`
-- operation, source currency GYD, using the SAME two formulas the bot
-- already applies (docstring on crm_calcular_monto_destino has both). Any
-- other shape (0 or 2+ beneficiaries, non-GYD source, no rate on file,
-- combo/other service types) is left alone — never guessed at.
--
-- RATE-AT-CALCULATION-TIME CAVEAT: `crm_tasa_vigente` always reads the
-- newest row in `tasas` for a currency, same as the bot. The rate and
-- amount stored on an operation are a snapshot from whenever the trigger
-- last ran (recorded in `quoted_destination_rate`) — they do NOT
-- automatically follow later rate changes. Only a change to this specific
-- operation's own quoted_source_amount, source_currency, status, or
-- beneficiary set re-triggers a recalculation.
--
-- LOCKS RESPECTED: a human correction is authoritative and this migration
-- never overwrites one.
--   - `admin_locked_fields ? 'quoted_destination_amount'` (096's lock,
--     placed by crm_corregir_operacion under a human JWT) stops all
--     calculation for that operation's destination amount permanently,
--     exactly like 096 already stops automation from overwriting a locked
--     operation column.
--   - `admin_locked_fields ? 'beneficiaries'` (098's lock, placed by
--     crm_corregir_beneficiario / crm_reasignar_beneficiario) stops this
--     migration from writing a beneficiary's `amount`/`currency`, exactly
--     like 098 already stops cerebro_sync_beneficiarios from touching a
--     corrected beneficiary set. The operation-level destination amount can
--     still be calculated even when the beneficiary is locked — only the
--     beneficiary row itself is left untouched.
--   - A beneficiary that already carries a non-calculated amount (set by a
--     human correction, or by some future automation path that isn't this
--     one) is never overwritten: only a NULL amount, or one this migration
--     itself calculated last time (`amount_origin = 'calculated'`), is
--     eligible to be (re)written.
--
-- WHY TRIGGERS INSTEAD OF DOING THIS IN THE READ RPC: the calculated amount
-- needs to be a real, audited value on the row (n8n and any other automation
-- reading remittance_operations/remittance_beneficiaries directly should see
-- it too), not just something the panel's read path derives on the fly.
-- AFTER triggers (not BEFORE) because the calculation depends on the FINAL
-- state of a row after every other BEFORE trigger (096's lock guard, guard
-- 12a's completion guard) has already run, and because a beneficiary-side
-- INSERT/UPDATE/DELETE must be able to update the operation row.
--
-- WHY A RECURSION GUARD: `crm_calcular_monto_destino` itself writes to
-- remittance_operations and remittance_beneficiaries, which re-fires this
-- migration's own AFTER triggers. `wacrm.calc_destino` (a transaction-local
-- GUC, same set_config(..., true) pattern 096 uses for wacrm.actor/origin)
-- makes every nested call inside one top-level invocation a no-op.
--
-- WHY A SEPARATE BEFORE TRIGGER FOR "MANUAL" ORIGIN: 096's existing lock
-- guard is what actually locks `quoted_destination_amount` in
-- admin_locked_fields the moment a human JWT changes it — this migration
-- does not touch that trigger. It only needs to know, on THIS table, when a
-- change to quoted_destination_amount came from a human write (not from
-- crm_calcular_monto_destino itself, which always runs with
-- wacrm.calc_destino = 'on') so it can stamp `quoted_destination_origin =
-- 'manual'` and drop the stale `quoted_destination_rate`.
--
-- ROLLBACK: ROLLBACK-100-destination-amount-calc.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. New columns.
-- ---------------------------------------------------------------------

ALTER TABLE remittance_operations
  ADD COLUMN IF NOT EXISTS quoted_destination_rate numeric,
  ADD COLUMN IF NOT EXISTS quoted_destination_origin text
    CHECK (quoted_destination_origin IN ('calculated', 'manual'));

ALTER TABLE remittance_beneficiaries
  ADD COLUMN IF NOT EXISTS amount_origin text
    CHECK (amount_origin IN ('calculated', 'manual'));


-- ---------------------------------------------------------------------
-- 2. crm_tasa_vigente — latest exchange rate for a currency.
-- ---------------------------------------------------------------------
-- Same query n8n's own bot uses to price a remesa: the newest `tasas` row
-- for the currency, by fecha then actualizada_at. Internal helper only —
-- not granted to `authenticated` (see grants section).

CREATE OR REPLACE FUNCTION crm_tasa_vigente(p_moneda text)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT tasa_cup
    FROM tasas
   WHERE moneda = p_moneda
   ORDER BY fecha DESC, actualizada_at DESC
   LIMIT 1;
$$;


-- ---------------------------------------------------------------------
-- 3. crm_calcular_monto_destino — the calculation itself.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_calcular_monto_destino(p_operation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op            remittance_operations%ROWTYPE;
  v_found         boolean := true;
  v_vigente_count integer;
  v_ben           remittance_beneficiaries%ROWTYPE;
  v_rate          numeric;
  v_amount        numeric;
  v_currency      text;
  v_computable    boolean := false;
BEGIN
  -- Recursion guard: the UPDATEs below re-fire this migration's own AFTER
  -- triggers. If a calculation is already running higher up the call stack,
  -- do nothing here — the flag belongs to that outer invocation, so this
  -- nested call must not touch (and must not reset) it.
  IF current_setting('wacrm.calc_destino', true) = 'on' THEN
    RETURN;
  END IF;

  PERFORM set_config('wacrm.calc_destino', 'on', true);

  BEGIN
    SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
    IF NOT FOUND THEN
      v_found := false;
    END IF;

    -- Eligible at all: exists, is a remesa, is still open, its destination
    -- amount isn't human-locked, and it either has no destination amount
    -- yet or the one it has is this function's own prior calculation (never
    -- a pre-existing/manual value).
    IF v_found
       AND v_op.service_type = 'remesa'
       AND v_op.status NOT IN ('completed', 'cancelled')
       AND NOT (v_op.admin_locked_fields ? 'quoted_destination_amount')
       AND (v_op.quoted_destination_amount IS NULL
            OR coalesce(v_op.quoted_destination_origin, '') = 'calculated')
    THEN
      SELECT count(*) INTO v_vigente_count
        FROM remittance_beneficiaries
       WHERE operation_id = p_operation_id AND status = 'vigente';

      IF v_vigente_count = 1
         AND coalesce(v_op.quoted_source_amount, 0) > 0
         AND upper(coalesce(v_op.source_currency, 'GYD')) = 'GYD'
      THEN
        SELECT * INTO v_ben
          FROM remittance_beneficiaries
         WHERE operation_id = p_operation_id AND status = 'vigente';

        IF v_ben.beneficiary_type = 'zelle' THEN
          v_rate := crm_tasa_vigente('usd');
          IF v_rate > 0 THEN
            -- Whole dollars, never round up — same rule n8n's bot applies.
            v_amount := floor(v_op.quoted_source_amount / v_rate);
            v_currency := 'USD';
            v_computable := true;
          END IF;
        ELSIF v_ben.beneficiary_type = 'cuban_card' THEN
          v_rate := crm_tasa_vigente('gyd');
          IF v_rate > 0 THEN
            v_amount := round(v_op.quoted_source_amount * v_rate);
            v_currency := 'CUP';
            v_computable := true;
          END IF;
        END IF;
      END IF;

      IF v_computable THEN
        UPDATE remittance_operations
           SET quoted_destination_amount = v_amount,
               destination_currency = v_currency,
               quoted_destination_rate = v_rate,
               quoted_destination_origin = 'calculated'
         WHERE id = p_operation_id
           AND (quoted_destination_amount IS DISTINCT FROM v_amount
                OR destination_currency IS DISTINCT FROM v_currency
                OR quoted_destination_rate IS DISTINCT FROM v_rate
                OR quoted_destination_origin IS DISTINCT FROM 'calculated');

        IF NOT (v_op.admin_locked_fields ? 'beneficiaries')
           AND (v_ben.amount IS NULL OR v_ben.amount_origin = 'calculated')
        THEN
          UPDATE remittance_beneficiaries
             SET amount = v_amount,
                 currency = v_currency,
                 amount_origin = 'calculated'
           WHERE id = v_ben.id
             AND (amount IS DISTINCT FROM v_amount
                  OR currency IS DISTINCT FROM v_currency
                  OR amount_origin IS DISTINCT FROM 'calculated');
        END IF;
      ELSIF v_op.quoted_destination_origin = 'calculated' THEN
        -- No longer computable (e.g. a second beneficiary showed up, or the
        -- rate disappeared) but the current value was this function's own
        -- stale calculation — clear it rather than leave a number nothing
        -- can now reproduce. destination_currency is left untouched: it is
        -- not exclusively this migration's field to clear.
        UPDATE remittance_operations
           SET quoted_destination_amount = NULL,
               quoted_destination_rate = NULL,
               quoted_destination_origin = NULL
         WHERE id = p_operation_id;

        IF NOT (v_op.admin_locked_fields ? 'beneficiaries') THEN
          UPDATE remittance_beneficiaries
             SET amount = NULL,
                 currency = NULL,
                 amount_origin = NULL
           WHERE operation_id = p_operation_id
             AND status = 'vigente'
             AND amount_origin = 'calculated';
        END IF;
      END IF;
    END IF;

    PERFORM set_config('wacrm.calc_destino', 'off', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('wacrm.calc_destino', 'off', true);
    RAISE;
  END;
END $$;


-- ---------------------------------------------------------------------
-- 4. Triggers — recalculate whenever the inputs change.
-- ---------------------------------------------------------------------
-- Names prefixed trg_zz_ so they sort, and therefore fire, after every
-- pre-existing trigger on these two tables (096's lock guard, guard 12a's
-- completion guard, the updated_at touch trigger). Both trigger functions
-- swallow their own errors: a calculation failure must never abort an
-- n8n/deal write or an operator correction.

CREATE OR REPLACE FUNCTION remittance_operations_recalc_destino_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM crm_calcular_monto_destino(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] crm_calcular_monto_destino failed for remittance_operations % (%): %', NEW.id, SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_zz_recalc_destino_operations ON remittance_operations;
CREATE TRIGGER trg_zz_recalc_destino_operations
  AFTER INSERT OR UPDATE OF quoted_source_amount, source_currency, status
  ON remittance_operations
  FOR EACH ROW EXECUTE FUNCTION remittance_operations_recalc_destino_trigger();


CREATE OR REPLACE FUNCTION remittance_beneficiaries_recalc_destino_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    IF TG_OP = 'DELETE' THEN
      PERFORM crm_calcular_monto_destino(OLD.operation_id);
      RETURN NULL;
    END IF;

    PERFORM crm_calcular_monto_destino(NEW.operation_id);

    IF TG_OP = 'UPDATE' AND OLD.operation_id IS DISTINCT FROM NEW.operation_id THEN
      PERFORM crm_calcular_monto_destino(OLD.operation_id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] crm_calcular_monto_destino failed for remittance_beneficiaries trigger (%, operation %): %',
      TG_OP, coalesce(NEW.operation_id, OLD.operation_id), SQLERRM;
  END;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_zz_recalc_destino_beneficiaries ON remittance_beneficiaries;
CREATE TRIGGER trg_zz_recalc_destino_beneficiaries
  AFTER INSERT OR UPDATE OF status, beneficiary_type, amount, operation_id OR DELETE
  ON remittance_beneficiaries
  FOR EACH ROW EXECUTE FUNCTION remittance_beneficiaries_recalc_destino_trigger();


-- ---------------------------------------------------------------------
-- 5. Manual-origin stamping — a human write owns the value it sets.
-- ---------------------------------------------------------------------
-- 096's existing lock guard is the trigger that actually adds
-- 'quoted_destination_amount' to admin_locked_fields on a human write; this
-- trigger only stamps origin/rate and runs BEFORE so it can still edit NEW.
-- Guarded by wacrm.calc_destino so crm_calcular_monto_destino's own writes
-- (which explicitly set origin = 'calculated' themselves) are never
-- reclassified as manual.

CREATE OR REPLACE FUNCTION remittance_operations_destino_manual_origin_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF current_setting('wacrm.calc_destino', true) IS DISTINCT FROM 'on'
     AND NEW.quoted_destination_amount IS DISTINCT FROM OLD.quoted_destination_amount
     AND NEW.quoted_destination_amount IS NOT NULL
  THEN
    NEW.quoted_destination_origin := 'manual';
    NEW.quoted_destination_rate := NULL;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_zz_destino_manual_origin ON remittance_operations;
CREATE TRIGGER trg_zz_destino_manual_origin
  BEFORE UPDATE OF quoted_destination_amount ON remittance_operations
  FOR EACH ROW EXECUTE FUNCTION remittance_operations_destino_manual_origin_guard();


-- ---------------------------------------------------------------------
-- 6. Backfill — compute (or leave alone) every currently-open remesa.
-- ---------------------------------------------------------------------

SELECT crm_calcular_monto_destino(id)
  FROM remittance_operations
 WHERE service_type = 'remesa'
   AND status NOT IN ('completed', 'cancelled');


-- ---------------------------------------------------------------------
-- 7. crm_operaciones_de_conversacion — surface the new columns.
-- ---------------------------------------------------------------------
-- Same body and grants as 097 (see that file for the full design
-- rationale on the resolver, authorization and masking decisions this
-- RPC makes) — the RETURNS TABLE column list changes shape, so
-- CREATE OR REPLACE is not enough; drop and recreate.

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
  beneficiary_amount_origin           text
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
    b.position,
    o.quoted_destination_rate,
    o.quoted_destination_origin,
    b.amount_origin
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


-- ---------------------------------------------------------------------
-- 8. Grants — internal calculation functions are not caller-facing.
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION crm_calcular_monto_destino(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_tasa_vigente(text) FROM PUBLIC, anon, authenticated;

-- =====================================================================
-- VALIDATED ON STAGING (crm.onlinefreedom.site's isolated DB), inside a
-- transaction that always ends in ROLLBACK — see
-- supabase/staging/assertions/destination-amount.sql for the exact
-- fixtures and expectations.
--
-- ROLLBACK
--   supabase/migrations/ROLLBACK-100-destination-amount-calc.sql
-- =====================================================================
