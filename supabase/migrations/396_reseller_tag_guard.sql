-- 396: only an owner or admin may add or remove the "Revendedor" contact tag when a user session exists.
--
-- 395 made the tag the single reseller identity, so an agent who could add or remove it would change the bot's deposit
-- behaviour by clicking a chip. This migration puts one BEFORE INSERT OR UPDATE OR DELETE row trigger on contact_tags that:
--
--   1. Trusts callers with no panel user session (auth.uid() IS NULL): the migration itself (395 backfill), the service role
--      (n8n / automations / flows) and API-key clients keep working unchanged.
--   2. Leaves every non-reseller tag exactly as it is today (the 017 RLS policy still governs it, agents included).
--   3. Treats scenarios that are not a real tag edit as allowed: re-inserting a (contact_id, tag_id) pair the contact already
--      has (the upsert ignoreDuplicates path and re-saves must not fail), a no-op UPDATE, and the cascade produced by deleting
--      the whole contact (contacts_delete, 017, still governs who may delete a contact) or by deleting a tag definition (013
--      tags_delete is admin-only, and the tag row is already gone).
--   4. Otherwise requires is_account_member(tag.account_id, 'admin'); an agent gets SQLSTATE 42501 with a readable message
--      and HINT reseller_tag_admin_only. The panel maps that to a Spanish message; the database stays the authority.
--   5. Writes the owner-accepted audit rows (human_reseller_tag_added / human_reseller_tag_removed) for real human edits
--      only; no-session callers never write those rows (395's migration_reseller_tag_added covers the backfill).
--
-- ROLLBACK-396-reseller-tag-guard.sql drops the trigger and the function only; agents return to the 017 permissions.

-- ─── 1. the guard ────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.contact_tags_reseller_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id   uuid;
  v_tag_name     text;
  v_new_reseller boolean := false;
  v_old_reseller boolean := false;
BEGIN
  -- No panel user session: migrations, service role (n8n / automations / flows), API-key clients.
  IF auth.uid() IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  -- Does the NEW side name a reseller tag? (INSERT / UPDATE)
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    SELECT t.account_id, t.name
      INTO v_account_id, v_tag_name
      FROM tags t
     WHERE t.id = NEW.tag_id
       AND reseller_tag_name_matches(t.name);
    v_new_reseller := FOUND;
  END IF;

  -- Does the OLD side name one? (UPDATE / DELETE) Only needed when NEW did not.
  IF (TG_OP = 'UPDATE' OR TG_OP = 'DELETE') AND NOT v_new_reseller THEN
    SELECT t.account_id, t.name
      INTO v_account_id, v_tag_name
      FROM tags t
     WHERE t.id = OLD.tag_id
       AND reseller_tag_name_matches(t.name);
    v_old_reseller := FOUND;
  END IF;

  -- Any other tag keeps today's behaviour (017 contact_tags_modify): no guard, no audit.
  IF NOT v_new_reseller AND NOT v_old_reseller THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  -- No state change. BEFORE triggers fire before unique-conflict resolution, so the upsert ignoreDuplicates path
  -- (import) and any re-save must pass instead of failing with 42501.
  IF TG_OP = 'UPDATE'
     AND NEW.contact_id = OLD.contact_id
     AND NEW.tag_id = OLD.tag_id THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT'
     AND EXISTS (
       SELECT 1 FROM contact_tags ct
        WHERE ct.contact_id = NEW.contact_id
          AND ct.tag_id = NEW.tag_id) THEN
    RETURN NEW;
  END IF;

  -- Cascade from deleting the whole contact: the contact row is already gone, so this is not a tag edit.
  IF TG_OP = 'DELETE'
     AND NOT EXISTS (SELECT 1 FROM contacts c WHERE c.id = OLD.contact_id) THEN
    RETURN OLD;
  END IF;

  IF NOT is_account_member(v_account_id, 'admin') THEN
    RAISE EXCEPTION 'only an owner or admin can add or remove the Revendedor tag'
      USING ERRCODE = '42501', HINT = 'reseller_tag_admin_only';
  END IF;

  -- A real human edit of the reseller tag: audit it.
  IF TG_OP = 'INSERT' THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'contact_tags', NEW.id, 'tag_id', 'human_reseller_tag_added', wacrm_current_actor(), NULL,
            jsonb_build_object('contact_id', NEW.contact_id, 'tag_id', NEW.tag_id, 'tag_name', v_tag_name));
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_account_id, 'contact_tags', OLD.id, 'tag_id', 'human_reseller_tag_removed', wacrm_current_actor(),
            jsonb_build_object('contact_id', OLD.contact_id, 'tag_id', OLD.tag_id, 'tag_name', v_tag_name), NULL);
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $function$;

-- A trigger function cannot be usefully called by an API role; close it like the 395 helpers.
REVOKE EXECUTE ON FUNCTION public.contact_tags_reseller_guard() FROM PUBLIC, anon, authenticated;

-- ─── 2. the trigger ──────────────────────────────────────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS contact_tags_reseller_guard ON public.contact_tags;
CREATE TRIGGER contact_tags_reseller_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.contact_tags
  FOR EACH ROW EXECUTE FUNCTION public.contact_tags_reseller_guard();
