-- 395: reseller identity now comes from the "Revendedor" contact tag alone.
--
-- The hidden allow-list (cerebro_revendedores) and the tag used only as a prompt hint were two disconnected notions of
-- "reseller". This migration makes the tag the single definition shared by the panel and the bot:
--
--   1. reseller_tag_name_matches(text) and reseller_contact_is_tagged(uuid): the one rule, reused everywhere.
--   2. _reseller_backfill_allow_list(): tags every contact whose phone matches an ACTIVE allow-list row with the "Revendedor"
--      tag, reusing the account's existing matching tag and creating "Revendedor" only where none exists, audited row by row
--      (migration_reseller_tag_added). It is idempotent and is also what the staging assertion exercises.
--   3. cerebro_es_revendedor(conv) is rewritten to read the tag. Same signature and same 109 ACL, so no caller changes.
--   4. A DO block proves, before COMMIT, that no conversation that was a reseller under the allow-list stopped being one.
--   5. The allow-list table is kept unchanged and marked deprecated/read-only; it is the rollback source.
--
-- The audit action list is the live staging list after 383 (read from remittance_admin_audit_action_chk) plus the actions this
-- change needs: the backfill and the tag audit of 396 (human_reseller_tag_*) and the counter actions of 397.
--
-- ROLLBACK-395-reseller-identity.sql restores the exact 109 body (the staging script compares the md5), drops the helpers and
-- the deprecation comment and restores the 383 action list NOT VALID. Tags and contact_tags created by the backfill stay; the
-- removal query is documented in that file.

-- ─── 1. audit actions ────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE public.remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk CHECK (action = ANY (ARRAY[
  'automation_write_suppressed'::text,
  'automation_completion_suppressed'::text,
  'automation_revert_suppressed'::text,
  'human_correction'::text,
  'human_reassignment'::text,
  'human_deposit_verification'::text,
  'human_forced_verification'::text,
  'human_delivery'::text,
  'calculator_feed_failed'::text,
  'calculator_pending_resolved'::text,
  'human_beneficiary_added'::text,
  'automation_reparto_registered'::text,
  'human_calculator_correction'::text,
  'automation_cash_delivery_data_registered'::text,
  'automation_late_deposit_verification'::text,
  'human_manual_close'::text,
  'human_operation_deleted'::text,
  'automation_recharge_numbers_registered'::text,
  'automation_combo_recipient_registered'::text,
  'human_combo_cost_set'::text,
  'automation_visa_registered'::text,
  'human_calculator_entry_deleted'::text,
  'human_calculator_manual_added'::text,
  'automation_service_change'::text,
  'automation_mixed_split'::text,
  'agent_service_change'::text,
  'agent_mexico_recipient_registered'::text,
  'agent_amount_change'::text,
  'agent_operation_cancel'::text,
  'agent_operation_merge'::text,
  'agent_recharge_number_removed'::text,
  'agent_beneficiary_corrected'::text,
  'agent_deposit_move'::text,
  'human_beneficiary_removed'::text,
  'human_operation_created'::text,
  'human_status_change'::text,
  'human_deposit_move'::text,
  'human_deposit_release'::text,
  'human_receipt_attached'::text,
  'human_closed_operation_edit'::text,
  'migration_reseller_tag_added'::text,
  'human_reseller_counter_reset'::text,
  'human_reseller_adjustment'::text,
  'human_reseller_tag_added'::text,
  'human_reseller_tag_removed'::text
]));

-- ─── 2. the single tag rule ───────────────────────────────────────────────────────────────────────────────────────────
-- Case-insensitive, surrounding spaces ignored, exact word otherwise: no plural, no accent variants.
CREATE OR REPLACE FUNCTION public.reseller_tag_name_matches(p_name text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT lower(btrim(p_name)) = 'revendedor';
$function$;

-- A contact is a reseller when it carries at least one matching tag of ITS OWN account (t.account_id = c.account_id).
CREATE OR REPLACE FUNCTION public.reseller_contact_is_tagged(p_contact_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM contacts c
      JOIN contact_tags ct ON ct.contact_id = c.id
      JOIN tags t ON t.id = ct.tag_id
     WHERE c.id = p_contact_id
       AND t.account_id = c.account_id
       AND reseller_tag_name_matches(t.name));
$function$;

-- Called only from SECURITY DEFINER functions/triggers and the migration itself.
REVOKE EXECUTE ON FUNCTION public.reseller_tag_name_matches(text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reseller_contact_is_tagged(uuid) FROM PUBLIC, anon, authenticated;

-- ─── 3. allow-list -> tag backfill, audited row by row ───────────────────────────────────────────────────────────────
-- Kept as a function (private, revoked everywhere) so the same code the migration runs is the code the staging assertion
-- exercises: the migration cannot create fixtures before itself, the assertion can create them and call this again.
CREATE OR REPLACE FUNCTION public._reseller_backfill_allow_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tags  integer := 0;
  v_links integer := 0;
BEGIN
  -- Create "Revendedor" once per account that has an active allow-list phone with a contact but no matching tag yet.
  WITH needed AS (
    SELECT DISTINCT c.account_id, a.owner_user_id
      FROM contacts c
      JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
      JOIN accounts a ON a.id = c.account_id
     WHERE NOT EXISTS (
             SELECT 1 FROM tags t
              WHERE t.account_id = c.account_id
                AND reseller_tag_name_matches(t.name))
  ), created AS (
    INSERT INTO tags (user_id, account_id, name)
    SELECT owner_user_id, account_id, 'Revendedor' FROM needed
    RETURNING id, account_id, name
  ), audited AS (
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    SELECT account_id, 'tags', id, 'name', 'migration_reseller_tag_added',
           'migration:395_reseller_identity', NULL,
           jsonb_build_object('tag_id', id, 'name', name, 'created', true)
      FROM created
    RETURNING 1
  )
  SELECT count(*) INTO v_tags FROM created;

  -- Link every matching contact that carries no matching tag yet, using the account's canonical (oldest) matching tag.
  WITH canonical AS (
    SELECT DISTINCT ON (t.account_id) t.account_id, t.id
      FROM tags t
     WHERE reseller_tag_name_matches(t.name)
     ORDER BY t.account_id, t.created_at, t.id
  ), targets AS (
    SELECT DISTINCT c.id AS contact_id, c.account_id
      FROM contacts c
      JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
     WHERE NOT EXISTS (
             SELECT 1
               FROM contact_tags ct
               JOIN tags t ON t.id = ct.tag_id
              WHERE ct.contact_id = c.id
                AND t.account_id = c.account_id
                AND reseller_tag_name_matches(t.name))
  ), linked AS (
    INSERT INTO contact_tags (contact_id, tag_id)
    SELECT g.contact_id, k.id
      FROM targets g
      JOIN canonical k ON k.account_id = g.account_id
    ON CONFLICT (contact_id, tag_id) DO NOTHING
    RETURNING id, contact_id, tag_id
  ), audited AS (
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    SELECT c.account_id, 'contact_tags', l.id, 'tag_id', 'migration_reseller_tag_added',
           'migration:395_reseller_identity', NULL,
           jsonb_build_object('contact_id', l.contact_id, 'tag_id', l.tag_id, 'phone', c.phone)
      FROM linked l
      JOIN contacts c ON c.id = l.contact_id
    RETURNING 1
  )
  SELECT count(*) INTO v_links FROM linked;

  RETURN jsonb_build_object('tags_created', v_tags, 'links_created', v_links);
END $function$;

REVOKE ALL ON FUNCTION public._reseller_backfill_allow_list() FROM PUBLIC, anon, authenticated, service_role;

SELECT public._reseller_backfill_allow_list();

-- ─── 4. the bot reads the tag ───────────────────────────────────────────────────────────────────────────────────────
-- Same signature as 109, so cerebro_registrar_deposito (391) and n8n keep calling it unchanged. CREATE OR REPLACE keeps
-- the 109 ACL; the REVOKE/GRANT pair is restated for from-scratch builds.
CREATE OR REPLACE FUNCTION public.cerebro_es_revendedor(p_conv uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM conversations v
     WHERE v.id = p_conv
       AND reseller_contact_is_tagged(v.contact_id));
$function$;

REVOKE EXECUTE ON FUNCTION public.cerebro_es_revendedor(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_es_revendedor(uuid) TO service_role;

-- ─── 5. prove that no current reseller is lost ─────────────────────────────────────────────────────────────────────
-- Production data differs from staging. If a conversation whose contact was an active allow-list reseller is not a
-- reseller under the tag rule, the transaction fails and nothing is applied. Contacts that GAIN reseller status are not
-- blocked here; they are reported before the production apply and the owner decides.
DO $check$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM conversations v
      JOIN contacts c ON c.id = v.contact_id
      JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
     WHERE NOT cerebro_es_revendedor(v.id)
  ) THEN
    RAISE EXCEPTION '395: a conversation that was a reseller under the allow-list is not one under the tag rule';
  END IF;
END $check$;

-- ─── 6. keep the allow-list as the rollback source, read-only and deprecated ────────────────────────────────────────
COMMENT ON TABLE public.cerebro_revendedores IS
  'DEPRECATED since 395: reseller identity is the "Revendedor" contact tag (reseller_tag_name_matches). Kept unchanged and read-only as the rollback source.';

NOTIFY pgrst, 'reload schema';
