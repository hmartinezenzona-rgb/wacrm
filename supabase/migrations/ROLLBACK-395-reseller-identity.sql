-- Rollback of 395: the bot returns to the allow-list and the tag helpers disappear.
--
--  1. _reseller_backfill_allow_list() is dropped (it exists only to run and to be asserted).
--  2. cerebro_es_revendedor is restored to its exact 109 body; staging-migracion.sh compares the md5 of
--     pg_get_functiondef and the ACL with the pre-migration state. The 109 ACL is preserved by CREATE OR REPLACE.
--  3. Both helpers are dropped (the restored body does not reference them).
--  4. The deprecation comment is removed.
--  5. The audit action list returns to the live 383 list, re-added NOT VALID so audit rows already written with the new
--     actions are kept and not validated.
--
-- The allow-list data was never changed, so the bot returns exactly to its previous behaviour.
--
-- Tags and contact_tags created by the backfill STAY. They are harmless after rollback (the tag only feeds the prompt
-- hint) and are fully listed by the migration_reseller_tag_added audit rows. A human who wants them removed can run,
-- knowing it is not automatic:
--
--   DELETE FROM public.contact_tags ct
--     USING public.remittance_admin_audit a
--    WHERE a.action = 'migration_reseller_tag_added'
--      AND a.table_name = 'contact_tags'
--      AND ct.id = a.row_id;
--
--   DELETE FROM public.tags t
--     USING public.remittance_admin_audit a
--    WHERE a.action = 'migration_reseller_tag_added'
--      AND a.table_name = 'tags'
--      AND t.id = a.row_id
--      AND NOT EXISTS (SELECT 1 FROM public.contact_tags ct WHERE ct.tag_id = t.id);

DROP FUNCTION IF EXISTS public._reseller_backfill_allow_list();

CREATE OR REPLACE FUNCTION public.cerebro_es_revendedor(p_conv uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM conversations v
      JOIN contacts c ON c.id = v.contact_id
      JOIN cerebro_revendedores r ON r.phone = c.phone AND r.activo
     WHERE v.id = p_conv);
$function$;

DROP FUNCTION IF EXISTS public.reseller_contact_is_tagged(uuid);
DROP FUNCTION IF EXISTS public.reseller_tag_name_matches(text);

COMMENT ON TABLE public.cerebro_revendedores IS NULL;

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
  'human_closed_operation_edit'::text
])) NOT VALID;
