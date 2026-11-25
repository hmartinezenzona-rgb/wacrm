-- ROLLBACK for 396: remove the reseller tag guard only.
--
-- After this file, agents are back to the 017 contact_tags permissions (they may add/remove any tag of their account,
-- including "Revendedor"), and no human_reseller_tag_* audit rows are written by the database any more. Audit rows already
-- recorded stay; the remittance_admin_audit action list is not touched (395 owns it and ROLLBACK-395 restores it).

DROP TRIGGER IF EXISTS contact_tags_reseller_guard ON public.contact_tags;
DROP FUNCTION IF EXISTS public.contact_tags_reseller_guard();
