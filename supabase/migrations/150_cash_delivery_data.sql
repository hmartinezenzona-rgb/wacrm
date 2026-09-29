-- =====================================================================
-- 150 — Cash USD delivery: where the recipient's data actually lives (B1.4)
--
-- PROBLEM
--   137/139/140 taught the Cerebro the FACTS of the efectivo_usd service
--   (rate, minimum, MMG deposit, and that phone/address/ID-card photo are
--   needed) but never gave it anywhere to WRITE those three values once
--   the customer provides them — 139/140 only touched cerebro_servicios.
--   `service_type`'s CHECK (046) intentionally stays untouched: cash
--   delivery is confirmed to be `service_type = 'remesa'` with
--   `delivery_method = 'efectivo_usd'`, the same shape zelle/cuban_card/
--   clasica/tropical/multiple_distribution already use.
--
-- PRODUCT DECISION (user, 2026-09-29): this data is remembered only
-- WITHIN the operation/conversation it was given in — never asked again
-- LATER IN THE SAME operation — and is explicitly NOT a cross-operation
-- recipient profile. A brand-new remesa to the same person asks again.
-- So this is per-operation storage on `remittance_beneficiaries`, not a
-- contact- or account-wide table.
--
-- WHAT
--   1. `remittance_beneficiaries` gains 'efectivo_usd' as a valid
--      `beneficiary_type` (rb_type_chk) plus two nullable columns:
--        - `address` text — the recipient's delivery address.
--        - `id_photo_wamid` text — the WhatsApp message id of the ID-card
--          photo, the SAME graceful-reference-by-message-id pattern this
--          codebase already uses for `comprobantes_hashes.whatsapp_
--          message_id` (037): the image itself is never duplicated, it
--          stays in `messages.media_url` keyed by this wamid.
--      `phone` is the existing column, reused as-is.
--
--   2. `crm_registrar_datos_entrega_efectivo(p_conv, p_phone, p_address,
--      p_id_photo_wamid)` — every parameter but the conversation is
--      OPTIONAL (NULL = "no new value this call"). It finds the
--      conversation's one open (`status NOT IN ('completed','cancelled')`)
--      `service_type = 'remesa'` operation with `delivery_method =
--      'efectivo_usd'` — this RPC never creates an operation, only
--      records data against one that already exists — reads that
--      operation's current `vigente` `efectivo_usd` beneficiary row (if
--      any), and MERGES: `COALESCE(p_x, existing.x)` per field. That
--      COALESCE is the entire mechanism behind "don't ask again": calling
--      this once per turn with only the field the customer just gave
--      never blanks out a field a previous turn already recorded.
--
--      Writes with the SAME append-only correction pattern every other
--      beneficiary type on this table already uses: the old `vigente`
--      row (if any) becomes `reemplazado` with `replaced_at = now()`, and
--      a fresh `vigente` row is inserted with the merged values,
--      `position = 1` (there is only ever one recipient for a cash
--      delivery, never a reparto). No new row is inserted, and nothing
--      is marked `reemplazado`, when the merged values are byte-for-byte
--      identical to what was already stored (including "still nothing at
--      all", i.e. every parameter NULL and no prior row) — a harmless
--      no-op instead of a spurious audit row.
--
-- AUTHORIZATION SHAPE — this is a bot/automation tool, not a panel
-- action: it has no session-based caller to check `is_account_member`
-- against (the n8n "Cerebro" agent calls Postgres with the `service_role`
-- key, the same trust boundary `cerebro_aplicar_reparto` (127),
-- `cerebro_aplicar_nombre_confirmado` (135) and `cerebro_guardar_lecturas_
-- vision` (128) already rely on — SECURITY DEFINER, `GRANT ... TO
-- service_role` only, no `authenticated`/`anon`/`PUBLIC` grant at all
-- (064's `ALTER DEFAULT PRIVILEGES` already revokes those by default for
-- every new function, so no explicit REVOKE is needed here either,
-- mirrored anyway for readability). The only real gate is the business
-- rule itself: no matching open `efectivo_usd` operation for the
-- conversation is a hard refusal (SQLSTATE 22023, the same code this
-- repo already uses for "wrong state to call this", e.g. 123's closed/
-- non-remesa refusals and 149's wrong-status refusal), never a silent
-- no-op.
--
-- SOURCE VALUE — reused, not invented, per instructions: every
-- `remittance_beneficiaries` row already carries a `source` (free text,
-- no CHECK). The three existing families are `'notes_parse'` (the
-- default; the bot's `deals.notes` text-parsing pipeline, 042),
-- `'admin_*'` (a human panel action, 098/123), and `'reparto_auto'` (127/
-- 129/130 — the one precedent for "a bot RPC inserts directly into this
-- table, bypassing notes text entirely, under the same SECURITY DEFINER
-- + service_role shape used here"). This migration reuses `'reparto_auto'`
-- for that reason — it is the established tag for exactly this code
-- shape, even though the literal Spanish word describes a different
-- scenario (splitting one deposit across several beneficiaries). No new
-- source value is introduced.
--
-- AUDIT — one `remittance_admin_audit` row per actual write (never on a
-- no-op), action `'automation_cash_delivery_data_registered'` (added to
-- `remittance_admin_audit_action_chk` below, full list restated per 149's
-- own note: the CHECK is replaced wholesale, not additively, so every
-- value already in production/staging use must be carried forward or
-- existing rows would violate it), before/after snapshots of just the
-- three fields, actor from `wacrm_current_actor()` (127's own pattern —
-- the audit's `actor` legitimately lands NULL for a service_role call
-- with no `wacrm.actor` GUC set, same as every other automation-audited
-- row on this table).
--
-- No `admin_locked_fields` lock is placed on 'beneficiaries' the way
-- 098/123/127 do for the other types: that lock exists purely to stop
-- `cerebro_sync_beneficiarios`'s `deals.notes` parser (042) from
-- overwriting a beneficiary a human or another automation just set, and
-- `cerebro_parsear_beneficiarios` (042) only ever emits `beneficiary_type`
-- IN ('cuban_card','zelle','multiple_distribution') — never
-- 'efectivo_usd' — so that trigger can never touch or replace this row
-- in the first place; a lock here would protect against a collision that
-- structurally cannot happen.
--
-- ROLLBACK: ROLLBACK-150-cash-delivery-data.sql
-- Guarded by supabase/staging/assertions/cash-delivery-data.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. remittance_beneficiaries: the new type and the two new columns.
-- ---------------------------------------------------------------------

ALTER TABLE remittance_beneficiaries DROP CONSTRAINT IF EXISTS rb_type_chk;
ALTER TABLE remittance_beneficiaries
  ADD CONSTRAINT rb_type_chk CHECK (beneficiary_type IN
    ('cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution', 'efectivo_usd'));

ALTER TABLE remittance_beneficiaries ADD COLUMN IF NOT EXISTS address text;
ALTER TABLE remittance_beneficiaries ADD COLUMN IF NOT EXISTS id_photo_wamid text;

COMMENT ON COLUMN remittance_beneficiaries.address IS
  '150. Cash-delivery (efectivo_usd) recipient address. Per-operation only, never a cross-operation profile.';
COMMENT ON COLUMN remittance_beneficiaries.id_photo_wamid IS
  '150. WhatsApp message id of the recipient''s ID-card photo (efectivo_usd). '
  'The image stays in messages.media_url keyed by this id — never duplicated here, '
  'same graceful-reference pattern as comprobantes_hashes.whatsapp_message_id (037).';

-- ---------------------------------------------------------------------
-- 2. Audit action vocabulary: add the one new automation-initiated action.
-- ---------------------------------------------------------------------
-- Full list carried forward byte-for-byte from 149 (the latest migration
-- to touch this constraint) plus 'automation_cash_delivery_data_registered'.

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
    'calculator_pending_resolved',
    'human_beneficiary_added',
    'automation_reparto_registered',
    'human_calculator_correction',
    'automation_cash_delivery_data_registered'
  ));

-- ---------------------------------------------------------------------
-- 3. crm_registrar_datos_entrega_efectivo — the merging bot-tool RPC.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_registrar_datos_entrega_efectivo(
  p_conv           uuid,
  p_phone          text DEFAULT NULL,
  p_address        text DEFAULT NULL,
  p_id_photo_wamid text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op_id       uuid;
  v_account_id  uuid;
  v_existing    remittance_beneficiaries%ROWTYPE;
  v_row         remittance_beneficiaries%ROWTYPE;
  v_new_phone   text;
  v_new_address text;
  v_new_photo   text;
  v_changed     boolean;
  v_next_block  integer;
BEGIN
  IF p_conv IS NULL THEN
    RAISE EXCEPTION 'conversation id is required' USING ERRCODE = '22023';
  END IF;

  -- The one open efectivo_usd remesa for this conversation. This RPC
  -- never creates an operation: if none matches, it is wrong to call it
  -- at all (there is nothing to record the data against).
  SELECT o.id, o.account_id INTO v_op_id, v_account_id
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv
     AND o.service_type = 'remesa'
     AND o.delivery_method = 'efectivo_usd'
     AND o.status NOT IN ('completed', 'cancelled')
   ORDER BY o.created_at DESC
   LIMIT 1
   FOR UPDATE;

  IF v_op_id IS NULL THEN
    RAISE EXCEPTION 'no open cash-delivery (efectivo_usd) operation for this conversation'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing
    FROM remittance_beneficiaries
   WHERE operation_id = v_op_id AND beneficiary_type = 'efectivo_usd' AND status = 'vigente'
   LIMIT 1;

  -- MERGE: NULL means "no new value this call" — this is the whole
  -- mechanism that lets the bot call this once per turn without ever
  -- losing a field a previous turn already recorded.
  v_new_phone   := coalesce(p_phone, v_existing.phone);
  v_new_address := coalesce(p_address, v_existing.address);
  v_new_photo   := coalesce(p_id_photo_wamid, v_existing.id_photo_wamid);

  -- No-op guard: only write when the merged values actually differ from
  -- what is already stored. With no prior row, "differ" means at least
  -- one parameter carries a real value — calling this with everything
  -- NULL and nothing on file yet must not create an empty row either.
  IF v_existing.id IS NOT NULL THEN
    v_changed := v_new_phone   IS DISTINCT FROM v_existing.phone
              OR v_new_address IS DISTINCT FROM v_existing.address
              OR v_new_photo   IS DISTINCT FROM v_existing.id_photo_wamid;
  ELSE
    v_changed := p_phone IS NOT NULL OR p_address IS NOT NULL OR p_id_photo_wamid IS NOT NULL;
  END IF;

  IF NOT v_changed THEN
    v_row := v_existing;
  ELSE
    IF v_existing.id IS NOT NULL THEN
      UPDATE remittance_beneficiaries
         SET status = 'reemplazado', replaced_at = now()
       WHERE id = v_existing.id;
    END IF;

    SELECT coalesce(max(block_index), 0) + 1 INTO v_next_block
      FROM remittance_beneficiaries WHERE operation_id = v_op_id;

    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, phone, address, id_photo_wamid,
      position, status, source, block_index
    ) VALUES (
      v_op_id, 'efectivo_usd', v_new_phone, v_new_address, v_new_photo,
      1, 'vigente', 'reparto_auto', v_next_block
    ) RETURNING * INTO v_row;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'remittance_beneficiaries', v_row.id, 'phone,address,id_photo_wamid',
            'automation_cash_delivery_data_registered', wacrm_current_actor(),
            CASE WHEN v_existing.id IS NULL THEN NULL ELSE
              jsonb_build_object('phone', v_existing.phone, 'address', v_existing.address, 'id_photo_wamid', v_existing.id_photo_wamid)
            END,
            jsonb_build_object('phone', v_row.phone, 'address', v_row.address, 'id_photo_wamid', v_row.id_photo_wamid));
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'phone', v_row.phone,
    'address', v_row.address,
    'id_photo_wamid', v_row.id_photo_wamid,
    'complete', (v_row.phone IS NOT NULL AND v_row.address IS NOT NULL AND v_row.id_photo_wamid IS NOT NULL),
    'changed', v_changed
  );
END $$;

COMMENT ON FUNCTION crm_registrar_datos_entrega_efectivo(uuid, text, text, text) IS
  '150. Bot tool (service_role only): merges phone/address/id_photo_wamid onto the '
  'conversation''s open efectivo_usd operation''s vigente beneficiary row, '
  'COALESCE-style so a later call never blanks an earlier field. Append-only '
  '(old vigente -> reemplazado, fresh vigente inserted), a no-op when nothing '
  'actually changes. 22023 when there is no open efectivo_usd operation to record against.';

REVOKE EXECUTE ON FUNCTION crm_registrar_datos_entrega_efectivo(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION crm_registrar_datos_entrega_efectivo(uuid, text, text, text) TO service_role;

NOTIFY pgrst, 'reload schema';
