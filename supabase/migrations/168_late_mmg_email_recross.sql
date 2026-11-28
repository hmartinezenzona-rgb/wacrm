-- =====================================================================
-- 168 — re-cross a deposit whose MMG email arrives after the receipt
--
-- Production cases (2026-09-28 .. 2026-10-01): the Cerebro crosses a
-- receipt against depositos_mmg ONCE, in the turn the receipt arrives.
-- When Gmail ingests the MMG email a few seconds or minutes later, nothing
-- crosses it again and the operation sits in deposit_verification for good:
--   * f9289dc7 (26,000 GYD): email ingested 17:06:19, never consumed;
--   * 6163e278 (13,000 GYD): operation 15:48:12, email 15:48:19;
--   * 99a4065d (10,000 GYD): operation 19:56:51, email 19:59:19.
-- The ingest workflow only writes; "el cruce lo hace el Cerebro".
--
-- This migration adds cerebro_recruzar_depositos_tardios(), run every
-- minute by pg_cron. For each operation that:
--   * is a remesa in deposit_verification, created in the last 24 hours,
--     untouched for 90 seconds (the Cerebro's own turn has finished);
--   * whose deal notes carry exactly ONE receipt reference ("Ref: <digits>")
--     and one "DEPOSITO: <amount>" line;
--   * and whose reference now has an unconsumed, non-annulled MMG email,
-- it runs the SAME cross the Cerebro runs (cerebro_cruzar_depositos), first
-- as a dry run and then for real. A failure never moves the operation to
-- incident: the incident stage passed is the waiting one.
--
-- On success it writes remittance_admin_audit action
-- 'automation_late_deposit_verification'. The notify workflow
-- (wGud0KGR6eMqqfMQ, "Leer secreto") treats that action like a manual
-- verification and tells the customer, because no agent turn did.
-- =====================================================================

ALTER TABLE remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk CHECK (action = ANY (ARRAY[
  'automation_write_suppressed', 'automation_completion_suppressed', 'automation_revert_suppressed',
  'human_correction', 'human_reassignment', 'human_deposit_verification', 'human_forced_verification',
  'human_delivery', 'calculator_feed_failed', 'calculator_pending_resolved', 'human_beneficiary_added',
  'automation_reparto_registered', 'human_calculator_correction', 'automation_cash_delivery_data_registered',
  'automation_late_deposit_verification']));

CREATE OR REPLACE FUNCTION public.cerebro_recruzar_depositos_tardios()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c_ok       CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';  -- ready_to_transfer
  c_esperado CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';  -- deposit_verification
  v_op   record;
  v_sim  record;
  v_real record;
  v_n    integer := 0;
BEGIN
  FOR v_op IN
    SELECT o.id, o.account_id, o.deal_id, x.ref, x.monto
      FROM remittance_operations o
      JOIN deals d ON d.id = o.deal_id
      CROSS JOIN LATERAL (
        SELECT (regexp_match(d.notes, 'Ref: ([0-9]{8,})'))[1] AS ref,
               replace((regexp_match(d.notes, 'DEPOSITO: ([0-9][0-9,]*)'))[1], ',', '')::numeric AS monto,
               (SELECT count(*) FROM regexp_matches(d.notes, 'Ref: [0-9]{8,}', 'g')) AS n_refs,
               (SELECT count(*) FROM regexp_matches(d.notes, 'DEPOSITO: [0-9]', 'g')) AS n_dep
      ) x
     WHERE o.status = 'deposit_verification'
       AND o.service_type = 'remesa'
       AND o.created_at > now() - interval '24 hours'
       AND o.updated_at < now() - interval '90 seconds'
       AND x.n_refs = 1 AND x.n_dep = 1
       AND EXISTS (SELECT 1 FROM depositos_mmg m
                    WHERE m.trans_id = x.ref AND m.consumido_en IS NULL AND m.anulado_en IS NULL)
     FOR UPDATE OF o SKIP LOCKED
  LOOP
    SELECT * INTO v_sim FROM cerebro_cruzar_depositos(v_op.deal_id, ARRAY[v_op.ref], ARRAY[v_op.monto],
                                                       c_ok, c_esperado, c_esperado, true);
    CONTINUE WHEN v_sim.resultado NOT IN ('verificado', 'verificado_incompleto');

    SELECT * INTO v_real FROM cerebro_cruzar_depositos(v_op.deal_id, ARRAY[v_op.ref], ARRAY[v_op.monto],
                                                        c_ok, c_esperado, c_esperado, false);
    CONTINUE WHEN v_real.resultado NOT IN ('verificado', 'verificado_incompleto');

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'status', 'automation_late_deposit_verification', NULL,
            'MMG email ingested after the receipt was processed; re-crossed by cerebro_recruzar_depositos_tardios.',
            jsonb_build_object('status', 'deposit_verification'),
            jsonb_build_object('resultado', v_real.resultado, 'trans_id', v_real.trans_id,
                               'status', (SELECT status FROM remittance_operations WHERE id = v_op.id)));
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION public.cerebro_recruzar_depositos_tardios() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'recruzar-depositos-tardios';
SELECT cron.schedule('recruzar-depositos-tardios', '* * * * *', 'SELECT public.cerebro_recruzar_depositos_tardios()');
