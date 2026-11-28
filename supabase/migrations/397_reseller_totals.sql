-- 397: reseller accumulated GYD total with a resettable counter.
--
-- The reseller total is DERIVED on read from a reseller's own GYD operations
-- plus an append-only adjustment ledger, bounded by append-only reset markers.
-- Nothing is stored as a running counter, so corrections and cancellations in
-- the money pipeline flow into the total with no new trigger on any money path.
--
--   1. reseller_counter_resets: one row per reset ("this counter is closed"),
--      with the snapshot the admin confirmed and an optional reason.
--   2. reseller_total_adjustments: signed, non-zero GYD corrections, optional
--      reason, append-only.
--   3. reseller_ledger_no_update(): a BEFORE UPDATE trigger on both tables, so
--      even the service role cannot edit a ledger row. DELETE has no grant and
--      only happens through the contact/account cascade.
--   4. _reseller_period_totals(): the one period definition (half-open
--      [from, to) on created_at) used by list, detail, reset snapshot and the
--      adjustment before/after figures. Counted statuses:
--      deposit_received, deposit_verification, ready_to_transfer, transferring,
--      completed, incident. Excluded by construction: cancelled,
--      collecting_information, awaiting_deposit, non-GYD (never converted).
--   5. Five RPCs:
--        crm_revendedores_resumen(account)              viewer+ read
--        crm_revendedor_detalle(contact)                viewer+ read
--        crm_revendedor_ajustar(contact, amount, reason) admin write
--        crm_revendedor_reiniciar(contact, reason, expected) admin write
--        crm_revendedores_reiniciar_todos(account, reason, expected) admin write
--      Every write takes one per-account advisory lock
--      (hashtextextended('reseller-totals:<account>', 0)) before reading totals,
--      stamps clock_timestamp(), writes one remittance_admin_audit row, and
--      "reset all" skips resellers whose current total is 0 (owner-accepted
--      default) while writing one marker per closed reseller and one batch id.
--      An optional expected amount that differs from the recomputed total raises
--      SQLSTATE 40001 (the panel maps it to 409) and writes nothing.
--
-- Error contract: P0002 contact not found -> 404; 42501 not a member / not
-- admin -> 403; 22023 not a reseller, zero/NULL/out-of-range amount, reason
-- > 500 -> 400; 40001 expected total differs -> 409.
--
-- INDEX / PRODUCTION LOCK RISK: this migration adds
-- remittance_operations_contact_created_idx (contact_id, created_at) WHERE
-- contact_id IS NOT NULL. No such index exists today. The migration runs inside
-- a transaction and a plain CREATE INDEX takes a SHARE lock that blocks writes
-- to remittance_operations for the duration of the build. At current volume the
-- build is expected to be sub-second; BEFORE the production apply, record
-- `SELECT count(*) FROM remittance_operations;` and confirm the build cost is
-- acceptable with the owner.
--
-- ROLLBACK-397-reseller-totals.sql drops the five RPCs, the helper, the
-- no-update function, both tables and the index. Export the tables first if the
-- history must be kept: dropping them loses every reset marker and adjustment.
-- Audit rows stay (the action list is restored by ROLLBACK-395).

-- ─── 1. append-only ledger tables ───────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reseller_counter_resets (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id              uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  contact_id              uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  reset_at                timestamptz NOT NULL,
  batch_id                uuid,
  reason                  text CHECK (reason IS NULL OR length(reason) BETWEEN 1 AND 500),
  closed_operations_gyd   numeric NOT NULL,
  closed_adjustments_gyd  numeric NOT NULL,
  closed_total_gyd        numeric NOT NULL,
  created_by              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  actor                   text NOT NULL,
  created_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT reseller_counter_resets_contact_at_uk UNIQUE (contact_id, reset_at)
);

CREATE INDEX IF NOT EXISTS reseller_counter_resets_account_idx
  ON public.reseller_counter_resets (account_id, contact_id, reset_at DESC);

CREATE TABLE IF NOT EXISTS public.reseller_total_adjustments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  contact_id  uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  amount_gyd  numeric NOT NULL CHECK (amount_gyd <> 0 AND abs(amount_gyd) < 1e12),
  reason      text CHECK (reason IS NULL OR length(reason) BETWEEN 1 AND 500),
  created_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  actor       text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS reseller_total_adjustments_contact_idx
  ON public.reseller_total_adjustments (contact_id, created_at);

-- Read for every member; no write policy and no write grant: only the
-- SECURITY DEFINER RPCs (owned by the migration role) write here.
ALTER TABLE public.reseller_counter_resets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reseller_counter_resets_select ON public.reseller_counter_resets;
CREATE POLICY reseller_counter_resets_select ON public.reseller_counter_resets
  FOR SELECT USING (is_account_member(account_id));
REVOKE ALL ON TABLE public.reseller_counter_resets FROM anon, authenticated;
GRANT SELECT ON TABLE public.reseller_counter_resets TO authenticated;

ALTER TABLE public.reseller_total_adjustments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reseller_total_adjustments_select ON public.reseller_total_adjustments;
CREATE POLICY reseller_total_adjustments_select ON public.reseller_total_adjustments
  FOR SELECT USING (is_account_member(account_id));
REVOKE ALL ON TABLE public.reseller_total_adjustments FROM anon, authenticated;
GRANT SELECT ON TABLE public.reseller_total_adjustments TO authenticated;

-- ─── 2. append-only enforcement ─────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reseller_ledger_no_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RAISE EXCEPTION '% rows are append-only; write a new adjustment instead', TG_TABLE_NAME
    USING ERRCODE = '42501';
END $function$;

REVOKE ALL ON FUNCTION public.reseller_ledger_no_update() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS reseller_counter_resets_no_update ON public.reseller_counter_resets;
CREATE TRIGGER reseller_counter_resets_no_update
  BEFORE UPDATE ON public.reseller_counter_resets
  FOR EACH ROW EXECUTE FUNCTION public.reseller_ledger_no_update();

DROP TRIGGER IF EXISTS reseller_total_adjustments_no_update ON public.reseller_total_adjustments;
CREATE TRIGGER reseller_total_adjustments_no_update
  BEFORE UPDATE ON public.reseller_total_adjustments
  FOR EACH ROW EXECUTE FUNCTION public.reseller_ledger_no_update();

-- ─── 3. index that the period helper uses ───────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS remittance_operations_contact_created_idx
  ON public.remittance_operations (contact_id, created_at)
  WHERE contact_id IS NOT NULL;

-- ─── 4. one period definition ───────────────────────────────────────────────────────────────────────────────────────
-- Half-open [p_from, p_to) on created_at. NULL p_from means "since the
-- beginning"; NULL p_to means "until now". Returns one row even when empty.
CREATE OR REPLACE FUNCTION public._reseller_period_totals(
  p_account_id uuid,
  p_contact_id uuid,
  p_from timestamptz,
  p_to timestamptz
) RETURNS TABLE(
  operations_gyd numeric,
  operations_count integer,
  operations_missing_amount integer,
  adjustments_gyd numeric,
  adjustments_count integer,
  total_gyd numeric
)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH ops AS (
    SELECT coalesce(sum(o.quoted_source_amount), 0) AS gyd,
           count(*)::int AS n,
           count(*) FILTER (WHERE o.quoted_source_amount IS NULL)::int AS missing
      FROM remittance_operations o
     WHERE o.contact_id = p_contact_id
       AND o.account_id = p_account_id
       AND o.source_currency = 'GYD'
       AND o.status IN ('deposit_received','deposit_verification','ready_to_transfer',
                        'transferring','completed','incident')
       AND o.created_at >= coalesce(p_from, '-infinity'::timestamptz)
       AND o.created_at <  coalesce(p_to,   'infinity'::timestamptz)
  ), adj AS (
    SELECT coalesce(sum(a.amount_gyd), 0) AS gyd, count(*)::int AS n
      FROM reseller_total_adjustments a
     WHERE a.contact_id = p_contact_id
       AND a.account_id = p_account_id
       AND a.created_at >= coalesce(p_from, '-infinity'::timestamptz)
       AND a.created_at <  coalesce(p_to,   'infinity'::timestamptz)
  )
  SELECT ops.gyd, ops.n, ops.missing, adj.gyd, adj.n, ops.gyd + adj.gyd FROM ops, adj;
$function$;

REVOKE ALL ON FUNCTION public._reseller_period_totals(uuid, uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

-- ─── 5. read RPC: Finanzas list and grand total ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crm_revendedores_resumen(p_account_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_resellers jsonb;
  v_grand     jsonb;
BEGIN
  IF NOT is_account_member(p_account_id) THEN
    RAISE EXCEPTION 'not a member of this account' USING ERRCODE = '42501';
  END IF;

  WITH resellers AS (
    SELECT DISTINCT c.id AS contact_id, c.name, c.phone
      FROM contacts c
      JOIN contact_tags ct ON ct.contact_id = c.id
      JOIN tags t ON t.id = ct.tag_id AND t.account_id = c.account_id
     WHERE c.account_id = p_account_id
       AND reseller_tag_name_matches(t.name)
  ), latest AS (
    SELECT DISTINCT ON (r.contact_id) r.contact_id, r.reset_at
      FROM reseller_counter_resets r
     WHERE r.account_id = p_account_id
     ORDER BY r.contact_id, r.reset_at DESC
  ), rows AS (
    SELECT s.contact_id, s.name, s.phone, l.reset_at AS period_start, tp.*
      FROM resellers s
      LEFT JOIN latest l ON l.contact_id = s.contact_id
      CROSS JOIN LATERAL _reseller_period_totals(p_account_id, s.contact_id, l.reset_at, NULL::timestamptz) tp
  ), agg AS (
    SELECT coalesce(sum(operations_gyd), 0) AS operations_gyd,
           coalesce(sum(adjustments_gyd), 0) AS adjustments_gyd,
           coalesce(sum(total_gyd), 0) AS total_gyd,
           count(*)::int AS resellers
      FROM rows
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'contact_id', r.contact_id,
            'name', r.name,
            'phone', r.phone,
            'period_start', r.period_start,
            'operations_gyd', r.operations_gyd,
            'operations_count', r.operations_count,
            'operations_missing_amount', r.operations_missing_amount,
            'adjustments_gyd', r.adjustments_gyd,
            'adjustments_count', r.adjustments_count,
            'total_gyd', r.total_gyd) ORDER BY r.total_gyd DESC, r.name NULLS LAST, r.contact_id),
          '[]'::jsonb),
         jsonb_build_object('operations_gyd', a.operations_gyd, 'adjustments_gyd', a.adjustments_gyd,
                            'total_gyd', a.total_gyd, 'resellers', a.resellers)
    INTO v_resellers, v_grand
    FROM rows r CROSS JOIN agg a
   GROUP BY a.operations_gyd, a.adjustments_gyd, a.total_gyd, a.resellers;

  RETURN jsonb_build_object('grand', v_grand, 'resellers', v_resellers);
END $function$;

REVOKE ALL ON FUNCTION public.crm_revendedores_resumen(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_revendedores_resumen(uuid) TO authenticated;

-- ─── 6. read RPC: one reseller with current period and history ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crm_revendedor_detalle(p_contact_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contact     record;
  v_is_reseller boolean;
  v_latest      timestamptz;
  v_current     record;
  v_adjustments jsonb;
  v_periods     jsonb;
BEGIN
  SELECT c.id, c.name, c.phone, c.account_id INTO v_contact
    FROM contacts c WHERE c.id = p_contact_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_contact.account_id) THEN
    RAISE EXCEPTION 'not a member of this account' USING ERRCODE = '42501';
  END IF;

  v_is_reseller := reseller_contact_is_tagged(p_contact_id);

  SELECT max(r.reset_at) INTO v_latest
    FROM reseller_counter_resets r
   WHERE r.account_id = v_contact.account_id AND r.contact_id = p_contact_id;

  SELECT * INTO v_current
    FROM _reseller_period_totals(v_contact.account_id, p_contact_id, v_latest, NULL::timestamptz);

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'amount_gyd', a.amount_gyd, 'reason', a.reason,
           'actor_name', p.full_name, 'created_at', a.created_at) ORDER BY a.created_at DESC, a.id),
         '[]'::jsonb)
    INTO v_adjustments
    FROM reseller_total_adjustments a
    LEFT JOIN profiles p ON p.user_id = a.created_by AND p.account_id = a.account_id
   WHERE a.account_id = v_contact.account_id AND a.contact_id = p_contact_id
     AND a.created_at >= coalesce(v_latest, '-infinity'::timestamptz);

  WITH marks AS (
    SELECT r.id, r.reset_at, r.batch_id, r.reason, r.closed_total_gyd, r.created_by,
           lag(r.reset_at) OVER (ORDER BY r.reset_at, r.id) AS start
      FROM reseller_counter_resets r
     WHERE r.account_id = v_contact.account_id AND r.contact_id = p_contact_id
  ), limited AS (
    SELECT * FROM marks ORDER BY reset_at DESC, id DESC LIMIT 100
  ), periods AS (
    SELECT m.id, m.reset_at AS end_at, m.start, m.batch_id, m.reason, m.closed_total_gyd,
           p.full_name AS reset_by_name, tp.*
      FROM limited m
      LEFT JOIN profiles p ON p.user_id = m.created_by AND p.account_id = v_contact.account_id
      CROSS JOIN LATERAL _reseller_period_totals(v_contact.account_id, p_contact_id, m.start, m.reset_at) tp
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'reset_id', p.id,
           'start', p.start,
           'end', p.end_at,
           'operations_gyd', p.operations_gyd,
           'adjustments_gyd', p.adjustments_gyd,
           'total_gyd', p.total_gyd,
           'closed_total_gyd', p.closed_total_gyd,
           'batch_id', p.batch_id,
           'reset_by_name', p.reset_by_name,
           'reason', p.reason) ORDER BY p.end_at DESC, p.id DESC),
         '[]'::jsonb)
    INTO v_periods
    FROM periods p;

  RETURN jsonb_build_object(
    'contact_id', v_contact.id,
    'name', v_contact.name,
    'phone', v_contact.phone,
    'is_reseller', v_is_reseller,
    'current', jsonb_build_object(
       'period_start', v_latest,
       'operations_gyd', v_current.operations_gyd,
       'operations_count', v_current.operations_count,
       'operations_missing_amount', v_current.operations_missing_amount,
       'adjustments_gyd', v_current.adjustments_gyd,
       'adjustments_count', v_current.adjustments_count,
       'total_gyd', v_current.total_gyd,
       'adjustments', v_adjustments),
    'periods', v_periods);
END $function$;

REVOKE ALL ON FUNCTION public.crm_revendedor_detalle(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_revendedor_detalle(uuid) TO authenticated;

-- ─── 7. write RPC: manual adjustment ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crm_revendedor_ajustar(
  p_contact_id uuid,
  p_monto_gyd numeric,
  p_motivo text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contact record;
  v_reason  text := nullif(btrim(coalesce(p_motivo, '')), '');
  v_latest  timestamptz;
  v_before  numeric;
  v_after   numeric;
  v_id      uuid;
  v_created timestamptz;
  v_actor   text := wacrm_current_actor();
BEGIN
  SELECT c.id, c.account_id INTO v_contact FROM contacts c WHERE c.id = p_contact_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_contact.account_id, 'admin') THEN
    RAISE EXCEPTION 'only an owner or admin can change reseller totals' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('reseller-totals:' || v_contact.account_id::text, 0));

  IF p_monto_gyd IS NULL OR p_monto_gyd = 0 OR abs(p_monto_gyd) >= 1e12 THEN
    RAISE EXCEPTION 'the adjustment must be a non-zero GYD amount under 1e12' USING ERRCODE = '22023';
  END IF;
  IF v_reason IS NOT NULL AND length(v_reason) > 500 THEN
    RAISE EXCEPTION 'the reason cannot exceed 500 characters' USING ERRCODE = '22023';
  END IF;
  IF NOT reseller_contact_is_tagged(p_contact_id) THEN
    RAISE EXCEPTION 'the contact is not a reseller' USING ERRCODE = '22023';
  END IF;

  SELECT max(r.reset_at) INTO v_latest
    FROM reseller_counter_resets r
   WHERE r.account_id = v_contact.account_id AND r.contact_id = p_contact_id;
  SELECT tp.total_gyd INTO v_before
    FROM _reseller_period_totals(v_contact.account_id, p_contact_id, v_latest, NULL::timestamptz) tp;
  v_after := v_before + p_monto_gyd;

  INSERT INTO reseller_total_adjustments (account_id, contact_id, amount_gyd, reason, created_by, actor)
  VALUES (v_contact.account_id, p_contact_id, p_monto_gyd, v_reason, auth.uid(), v_actor)
  RETURNING id, created_at INTO v_id, v_created;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_contact.account_id, 'reseller_total_adjustments', v_id, 'amount_gyd', 'human_reseller_adjustment', v_actor, v_reason,
          jsonb_build_object('contact_id', p_contact_id, 'total_gyd', v_before),
          jsonb_build_object('amount_gyd', p_monto_gyd, 'total_gyd', v_after));

  RETURN jsonb_build_object('adjustment_id', v_id, 'contact_id', p_contact_id, 'amount_gyd', p_monto_gyd,
                            'created_at', v_created, 'total_before_gyd', v_before, 'total_after_gyd', v_after);
END $function$;

REVOKE ALL ON FUNCTION public.crm_revendedor_ajustar(uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_revendedor_ajustar(uuid, numeric, text) TO authenticated;

-- ─── 8. write RPC: reset one reseller ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crm_revendedor_reiniciar(
  p_contact_id uuid,
  p_motivo text DEFAULT NULL,
  p_total_esperado_gyd numeric DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contact      record;
  v_reason       text := nullif(btrim(coalesce(p_motivo, '')), '');
  v_period_start timestamptz;
  v_ops          numeric;
  v_adj          numeric;
  v_total        numeric;
  v_reset_at     timestamptz;
  v_id           uuid;
  v_actor        text := wacrm_current_actor();
BEGIN
  SELECT c.id, c.account_id INTO v_contact FROM contacts c WHERE c.id = p_contact_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_contact.account_id, 'admin') THEN
    RAISE EXCEPTION 'only an owner or admin can change reseller totals' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('reseller-totals:' || v_contact.account_id::text, 0));

  IF v_reason IS NOT NULL AND length(v_reason) > 500 THEN
    RAISE EXCEPTION 'the reason cannot exceed 500 characters' USING ERRCODE = '22023';
  END IF;
  IF NOT reseller_contact_is_tagged(p_contact_id) THEN
    RAISE EXCEPTION 'the contact is not a reseller' USING ERRCODE = '22023';
  END IF;

  SELECT max(r.reset_at) INTO v_period_start
    FROM reseller_counter_resets r
   WHERE r.account_id = v_contact.account_id AND r.contact_id = p_contact_id;
  SELECT tp.operations_gyd, tp.adjustments_gyd, tp.total_gyd INTO v_ops, v_adj, v_total
    FROM _reseller_period_totals(v_contact.account_id, p_contact_id, v_period_start, NULL::timestamptz) tp;

  IF p_total_esperado_gyd IS NOT NULL AND p_total_esperado_gyd <> v_total THEN
    RAISE EXCEPTION 'the expected total (%) differs from the current total (%)', p_total_esperado_gyd, v_total
      USING ERRCODE = '40001', HINT = v_total::text;
  END IF;

  v_reset_at := clock_timestamp();
  INSERT INTO reseller_counter_resets (account_id, contact_id, reset_at, batch_id, reason,
         closed_operations_gyd, closed_adjustments_gyd, closed_total_gyd, created_by, actor)
  VALUES (v_contact.account_id, p_contact_id, v_reset_at, NULL, v_reason,
          v_ops, v_adj, v_total, auth.uid(), v_actor)
  RETURNING id INTO v_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_contact.account_id, 'reseller_counter_resets', v_id, 'counter', 'human_reseller_counter_reset', v_actor, v_reason,
          jsonb_build_object('contact_id', p_contact_id, 'period_start', v_period_start,
                             'operations_gyd', v_ops, 'adjustments_gyd', v_adj, 'total_gyd', v_total),
          jsonb_build_object('reset_at', v_reset_at, 'batch_id', NULL, 'total_gyd', 0));

  RETURN jsonb_build_object(
    'reset_id', v_id, 'contact_id', p_contact_id, 'reset_at', v_reset_at,
    'closed', jsonb_build_object('operations_gyd', v_ops, 'adjustments_gyd', v_adj, 'total_gyd', v_total));
END $function$;

REVOKE ALL ON FUNCTION public.crm_revendedor_reiniciar(uuid, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_revendedor_reiniciar(uuid, text, numeric) TO authenticated;

-- ─── 9. write RPC: reset all resellers (skips zero totals, one batch) ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crm_revendedores_reiniciar_todos(
  p_account_id uuid,
  p_motivo text DEFAULT NULL,
  p_total_esperado_gyd numeric DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason    text := nullif(btrim(coalesce(p_motivo, '')), '');
  v_reset_at  timestamptz;
  v_batch     uuid;
  v_grand     numeric;
  v_count     integer;
  v_resets    jsonb;
  v_actor     text := wacrm_current_actor();
BEGIN
  IF NOT is_account_member(p_account_id, 'admin') THEN
    RAISE EXCEPTION 'only an owner or admin can change reseller totals' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('reseller-totals:' || p_account_id::text, 0));

  IF v_reason IS NOT NULL AND length(v_reason) > 500 THEN
    RAISE EXCEPTION 'the reason cannot exceed 500 characters' USING ERRCODE = '22023';
  END IF;

  -- Grand total under the lock, then the expected-amount check before any write.
  WITH resellers AS (
    SELECT DISTINCT c.id AS contact_id
      FROM contacts c
      JOIN contact_tags ct ON ct.contact_id = c.id
      JOIN tags t ON t.id = ct.tag_id AND t.account_id = c.account_id
     WHERE c.account_id = p_account_id
       AND reseller_tag_name_matches(t.name)
  ), latest AS (
    SELECT DISTINCT ON (r.contact_id) r.contact_id, r.reset_at
      FROM reseller_counter_resets r
     WHERE r.account_id = p_account_id
     ORDER BY r.contact_id, r.reset_at DESC
  ), rows AS (
    SELECT s.contact_id, tp.total_gyd
      FROM resellers s
      LEFT JOIN latest l ON l.contact_id = s.contact_id
      CROSS JOIN LATERAL _reseller_period_totals(p_account_id, s.contact_id, l.reset_at, NULL::timestamptz) tp
  )
  SELECT coalesce(sum(total_gyd), 0) INTO v_grand FROM rows;

  IF p_total_esperado_gyd IS NOT NULL AND p_total_esperado_gyd <> v_grand THEN
    RAISE EXCEPTION 'the expected grand total (%) differs from the current grand total (%)', p_total_esperado_gyd, v_grand
      USING ERRCODE = '40001', HINT = v_grand::text;
  END IF;

  v_reset_at := clock_timestamp();
  v_batch := gen_random_uuid();

  -- One marker per reseller whose current total is non-zero; zeros are skipped
  -- (owner-accepted default). Each marker is audited with the shared batch id.
  WITH resellers AS (
    SELECT DISTINCT c.id AS contact_id
      FROM contacts c
      JOIN contact_tags ct ON ct.contact_id = c.id
      JOIN tags t ON t.id = ct.tag_id AND t.account_id = c.account_id
     WHERE c.account_id = p_account_id
       AND reseller_tag_name_matches(t.name)
  ), latest AS (
    SELECT DISTINCT ON (r.contact_id) r.contact_id, r.reset_at
      FROM reseller_counter_resets r
     WHERE r.account_id = p_account_id
     ORDER BY r.contact_id, r.reset_at DESC
  ), rows AS (
    SELECT s.contact_id, tp.*
      FROM resellers s
      LEFT JOIN latest l ON l.contact_id = s.contact_id
      CROSS JOIN LATERAL _reseller_period_totals(p_account_id, s.contact_id, l.reset_at, NULL::timestamptz) tp
  ), target AS (
    SELECT * FROM rows WHERE total_gyd <> 0
  ), ins AS (
    INSERT INTO reseller_counter_resets (account_id, contact_id, reset_at, batch_id, reason,
           closed_operations_gyd, closed_adjustments_gyd, closed_total_gyd, created_by, actor)
    SELECT p_account_id, t.contact_id, v_reset_at, v_batch, v_reason,
           t.operations_gyd, t.adjustments_gyd, t.total_gyd, auth.uid(), v_actor
      FROM target t
    RETURNING id, contact_id, closed_total_gyd
  ), aud AS (
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    SELECT p_account_id, 'reseller_counter_resets', i.id, 'counter', 'human_reseller_counter_reset', v_actor, v_reason,
           jsonb_build_object('contact_id', i.contact_id, 'total_gyd', i.closed_total_gyd),
           jsonb_build_object('reset_at', v_reset_at, 'batch_id', v_batch, 'total_gyd', 0)
      FROM ins i
    RETURNING 1
  )
  SELECT count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object('reset_id', i.id, 'contact_id', i.contact_id, 'total_gyd', i.closed_total_gyd)
                            ORDER BY i.contact_id), '[]'::jsonb)
    INTO v_count, v_resets
    FROM ins i;

  RETURN jsonb_build_object('batch_id', v_batch, 'reset_at', v_reset_at, 'count', v_count,
                            'grand_total_gyd', v_grand, 'resets', v_resets);
END $function$;

REVOKE ALL ON FUNCTION public.crm_revendedores_reiniciar_todos(uuid, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_revendedores_reiniciar_todos(uuid, text, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
