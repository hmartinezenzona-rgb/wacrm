-- 398: reseller deposits without operations.
--
-- Owner amendment 2026-11-24: a reseller receipt creates NO operation. The bot
-- verifies it against the MMG book, confirms it in the chat and records it for
-- the reseller CONTACT. The reseller total is derived on read from:
--   (a) verified reseller deposits (reseller_deposits) whose MMG deposit is
--       still consumed, not annulled and not linked to an operation;
--   (b) historical reseller operations created BEFORE the cutover marker;
--   (c) the append-only adjustments ledger.
--
--   1. reseller_deposits: one row per receipt block read by the bot, pending
--      until the MMG cross consumes the matching deposit. reseller_deposits_guard()
--      allows only the pending -> verified transition; verified rows are immutable.
--   2. reseller_deposit_cutover: one typed row written in the same transaction
--      as the wrapper switch, so no reseller operation can be created after it.
--   3. cerebro_registrar_deposito_si_cliente: admin precedence unchanged (310);
--      a reseller now records pending claims under the per-conversation advisory
--      lock and returns (NULL, 'deposito_revendedor', true, false); customers
--      keep delegating to cerebro_registrar_deposito unchanged.
--   4. reseller_deposits_attribute(): AFTER UPDATE OF consumido_en trigger on
--      depositos_mmg. When a deposit is consumed with operation_id NULL it
--      attributes the oldest pending claim by exact TransID, else a single
--      approximate candidate. Fail-open: any error is a WARNING and the
--      consumption still succeeds.
--   5. _reseller_period_counts(): the 398 period helper (verified deposits +
--      pre-cutover operations + adjustments, half-open [from, to)).
--   6. The five 397 RPCs are re-pointed to it with additive keys:
--      deposits_gyd, deposits_count, counted_gyd; the detail adds pending_claims
--      and the history periods expose closed_deposits_gyd. Reset snapshots now
--      store closed_deposits_gyd (additive column on reseller_counter_resets).
--
-- Not changed here: cerebro_registrar_deposito, cerebro_cruzar_deposito(s),
-- cerebro_verificar_transid, the 397 tables' existing columns, the n8n workflow
-- and the Decisor (Decision 20 ships in slice 7b).
--
-- ROLLBACK-398-reseller-deposits.sql restores the 310 wrapper and the five 397
-- RPC bodies verbatim (md5 must match), drops the trigger, functions, the new
-- column and both tables. Export reseller_deposits before rolling back: deposits
-- already consumed for resellers stay consumed with operation_id NULL.
--
-- Assertion: supabase/staging/assertions/reseller-deposits.sql.

-- ─── 1. reseller deposit claims ─────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.reseller_deposits (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id           uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  contact_id           uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  conversation_id      uuid REFERENCES conversations(id) ON DELETE SET NULL,
  comp_id              text,
  reference_read       text,
  reference_digits     text GENERATED ALWAYS AS (
                         NULLIF(regexp_replace(COALESCE(reference_read, ''), '[^0-9]', '', 'g'), '')
                       ) STORED,
  amount_read          numeric,
  currency_read        text,
  trans_id             text,
  amount_gyd           numeric CHECK (amount_gyd IS NULL OR amount_gyd > 0),
  verification_method  text CHECK (verification_method IS NULL OR verification_method IN ('exacto', 'aproximado')),
  verified_at          timestamptz,
  actor                text NOT NULL DEFAULT 'automation:registrar_deposito_revendedor',
  created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT reseller_deposits_verified_shape CHECK (
    (verified_at IS NULL AND trans_id IS NULL AND amount_gyd IS NULL AND verification_method IS NULL)
    OR (verified_at IS NOT NULL AND trans_id IS NOT NULL AND amount_gyd IS NOT NULL AND verification_method IS NOT NULL))
);

CREATE UNIQUE INDEX reseller_deposits_account_trans_uk
  ON public.reseller_deposits (account_id, trans_id) WHERE trans_id IS NOT NULL;
CREATE UNIQUE INDEX reseller_deposits_conv_comp_uk
  ON public.reseller_deposits (conversation_id, comp_id) WHERE comp_id IS NOT NULL;
CREATE INDEX reseller_deposits_contact_verified_idx
  ON public.reseller_deposits (contact_id, verified_at) WHERE verified_at IS NOT NULL;
CREATE INDEX reseller_deposits_pending_idx
  ON public.reseller_deposits (reference_digits, created_at) WHERE verified_at IS NULL;

ALTER TABLE public.reseller_deposits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reseller_deposits_select ON public.reseller_deposits;
CREATE POLICY reseller_deposits_select ON public.reseller_deposits
  FOR SELECT USING (is_account_member(account_id));
REVOKE ALL ON TABLE public.reseller_deposits FROM anon, authenticated;
GRANT SELECT ON TABLE public.reseller_deposits TO authenticated;

-- Only pending -> verified may change, and only through the attribution
-- function. DELETE has no grant and only happens through contact/account cascade.
CREATE OR REPLACE FUNCTION public.reseller_deposits_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.verified_at IS NOT NULL THEN
    RAISE EXCEPTION 'reseller_deposits rows are immutable once verified' USING ERRCODE = '42501';
  END IF;
  IF NEW.verified_at IS NULL OR NEW.trans_id IS NULL OR NEW.amount_gyd IS NULL OR NEW.verification_method IS NULL THEN
    RAISE EXCEPTION 'reseller_deposits only accepts the pending -> verified transition' USING ERRCODE = '42501';
  END IF;
  IF NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.contact_id IS DISTINCT FROM OLD.contact_id
     OR NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
     OR NEW.comp_id IS DISTINCT FROM OLD.comp_id
     OR NEW.reference_read IS DISTINCT FROM OLD.reference_read
     OR NEW.amount_read IS DISTINCT FROM OLD.amount_read
     OR NEW.currency_read IS DISTINCT FROM OLD.currency_read
     OR NEW.actor IS DISTINCT FROM OLD.actor
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'only trans_id, amount_gyd, verified_at and verification_method may change' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $function$;

REVOKE ALL ON FUNCTION public.reseller_deposits_guard() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS reseller_deposits_guard ON public.reseller_deposits;
CREATE TRIGGER reseller_deposits_guard
  BEFORE UPDATE ON public.reseller_deposits
  FOR EACH ROW EXECUTE FUNCTION public.reseller_deposits_guard();

-- ─── 2. cutover marker ──────────────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.reseller_deposit_cutover (
  singleton   boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  cutover_at  timestamptz NOT NULL,
  migration   text NOT NULL
);

ALTER TABLE public.reseller_deposit_cutover ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reseller_deposit_cutover_select ON public.reseller_deposit_cutover;
CREATE POLICY reseller_deposit_cutover_select ON public.reseller_deposit_cutover
  FOR SELECT USING (true);
REVOKE ALL ON TABLE public.reseller_deposit_cutover FROM anon, authenticated;
GRANT SELECT ON TABLE public.reseller_deposit_cutover TO authenticated;

INSERT INTO public.reseller_deposit_cutover (singleton, cutover_at, migration)
VALUES (true, now(), '398_reseller_deposits')
ON CONFLICT (singleton) DO NOTHING;

-- ─── 3. additive reset snapshot column ──────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.reseller_counter_resets
  ADD COLUMN IF NOT EXISTS closed_deposits_gyd numeric NOT NULL DEFAULT 0;

-- Late-attribution window for exact TransID matches (default 72 h when absent).
INSERT INTO cerebro_config (clave, valor, descripcion)
VALUES ('revendedor_reclamo_horas', '72',
        'Horas hacia atras en que un reclamo de deposito de revendedor sigue siendo atribuible por TransID exacto.')
ON CONFLICT (clave) DO NOTHING;

-- ─── 4. wrapper: resellers record claims and create no operation ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cerebro_registrar_deposito_si_cliente(
  p_conv uuid,
  p_monto numeric,
  p_moneda text,
  p_stage uuid,
  p_nota text,
  p_comp_id text
)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_account uuid;
  v_contact uuid;
  v_claims  integer;
BEGIN
  -- (310) Admin precedence is unchanged: verification only, no deal, no claim.
  IF EXISTS (
    SELECT 1
      FROM public.conversations v
      JOIN public.contacts c ON c.id = v.contact_id
      JOIN public.contact_tags ct ON ct.contact_id = c.id
      JOIN public.tags t ON t.id = ct.tag_id
     WHERE v.id = p_conv
       AND lower(t.name) = 'admin'
  ) THEN
    RETURN QUERY SELECT NULL::uuid, 'verificacion_admin'::text, false, false;
    RETURN;
  END IF;

  -- (398) A reseller receipt creates no operation. Under the same per-conversation
  -- lock cerebro_registrar_deposito takes, record one pending claim per receipt
  -- block so the MMG cross can attribute the consumed deposit later.
  IF public.cerebro_es_revendedor(p_conv) THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_servicio:' || p_conv::text, 0));

    SELECT v.account_id, v.contact_id INTO v_account, v_contact
      FROM public.conversations v
     WHERE v.id = p_conv;

    INSERT INTO public.reseller_deposits
      (account_id, contact_id, conversation_id, comp_id, reference_read, amount_read, currency_read)
    SELECT v_account, v_contact, p_conv, p.comp_id, p.reference, p.amount, p.currency
      FROM public.cerebro_parsear_comprobantes(p_nota) p
    ON CONFLICT (conversation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    GET DIAGNOSTICS v_claims = ROW_COUNT;

    -- A note with no parsable block still records one claim from the call;
    -- with no reference it can never be matched and stays pending for an admin.
    IF v_claims = 0 AND NOT EXISTS (SELECT 1 FROM public.cerebro_parsear_comprobantes(p_nota)) THEN
      INSERT INTO public.reseller_deposits
        (account_id, contact_id, conversation_id, comp_id, reference_read, amount_read, currency_read)
      VALUES (v_account, v_contact, p_conv, NULLIF(p_comp_id, ''), NULL, p_monto, p_moneda)
      ON CONFLICT (conversation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    END IF;

    RETURN QUERY SELECT NULL::uuid, 'deposito_revendedor'::text, true, false;
    RETURN;
  END IF;

  RETURN QUERY
    SELECT * FROM public.cerebro_registrar_deposito(p_conv, p_monto, p_moneda, p_stage, p_nota, p_comp_id);
END;
$function$;

COMMENT ON FUNCTION public.cerebro_registrar_deposito_si_cliente(uuid, numeric, text, uuid, text, text) IS
  'Admin receipts are verification-only (310). Reseller receipts create no operation: they record pending '
  'reseller_deposits claims and return (NULL, deposito_revendedor, true, false). Customers delegate to '
  'cerebro_registrar_deposito unchanged (398).';

REVOKE ALL ON FUNCTION public.cerebro_registrar_deposito_si_cliente(uuid, numeric, text, uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_registrar_deposito_si_cliente(uuid, numeric, text, uuid, text, text)
  TO service_role;

-- ─── 5. attribution on depositos_mmg ────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reseller_deposits_attribute()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reclamo_horas integer := COALESCE(NULLIF(cerebro_config_get('revendedor_reclamo_horas'), '')::int, 72);
  v_ventana_horas integer := COALESCE(NULLIF(cerebro_config_get('cruce_ventana_horas'), '')::int, 6);
  v_digits        text;
  v_claim         uuid;
  v_metodo        text;
  v_candidatos    integer;
BEGIN
  -- Fail-open: attribution never aborts the money path. A rollback of this
  -- block (unique_violation included) leaves the claim pending.
  BEGIN
    v_digits := NULLIF(regexp_replace(COALESCE(NEW.trans_id, ''), '[^0-9]', '', 'g'), '');

    -- 1. Exact TransID match: the oldest pending claim within the claim window.
    SELECT r.id INTO v_claim
      FROM public.reseller_deposits r
     WHERE r.verified_at IS NULL
       AND r.reference_digits = v_digits
       AND r.created_at >= NEW.consumido_en - make_interval(hours => v_reclamo_horas)
     ORDER BY r.created_at, r.id
     LIMIT 1;

    IF v_claim IS NOT NULL THEN
      v_metodo := 'exacto';
    ELSE
      -- 2. Approximate match: exactly one pending claim in the cross window
      --    with the same read amount and a similar reference.
      SELECT count(*) INTO v_candidatos
        FROM public.reseller_deposits r
       WHERE r.verified_at IS NULL
         AND r.amount_read = NEW.monto
         AND r.created_at >= NEW.consumido_en - make_interval(hours => v_ventana_horas)
         AND cerebro_ref_parecida(r.reference_digits, v_digits);

      IF v_candidatos = 1 THEN
        SELECT r.id INTO v_claim
          FROM public.reseller_deposits r
         WHERE r.verified_at IS NULL
           AND r.amount_read = NEW.monto
           AND r.created_at >= NEW.consumido_en - make_interval(hours => v_ventana_horas)
           AND cerebro_ref_parecida(r.reference_digits, v_digits)
         LIMIT 1;
        v_metodo := 'aproximado';
      END IF;
    END IF;

    IF v_claim IS NOT NULL THEN
      UPDATE public.reseller_deposits
         SET trans_id = NEW.trans_id,
             amount_gyd = NEW.monto,
             verified_at = NEW.consumido_en,
             verification_method = v_metodo
       WHERE id = v_claim;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'reseller_deposits attribution failed for deposit %: %', NEW.trans_id, SQLERRM;
  END;

  RETURN NEW;
END $function$;

REVOKE ALL ON FUNCTION public.reseller_deposits_attribute() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS depositos_mmg_reseller_attribution ON public.depositos_mmg;
CREATE TRIGGER depositos_mmg_reseller_attribution
  AFTER UPDATE OF consumido_en ON public.depositos_mmg
  FOR EACH ROW
  WHEN (OLD.consumido_en IS NULL AND NEW.consumido_en IS NOT NULL AND NEW.operation_id IS NULL)
  EXECUTE FUNCTION public.reseller_deposits_attribute();

-- ─── 6. period helper: verified deposits + pre-cutover operations + adjustments ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public._reseller_period_counts(p_account_id uuid, p_contact_id uuid,
                                                          p_from timestamptz, p_to timestamptz)
 RETURNS TABLE(deposits_gyd numeric, deposits_count integer,
               operations_gyd numeric, operations_count integer, operations_missing_amount integer,
               adjustments_gyd numeric, adjustments_count integer,
               counted_gyd numeric, total_gyd numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH cut AS (
    SELECT cutover_at FROM public.reseller_deposit_cutover
  ), dep AS (
    SELECT coalesce(sum(r.amount_gyd), 0) AS gyd, count(*)::int AS n
      FROM public.reseller_deposits r
     WHERE r.contact_id = p_contact_id
       AND r.account_id = p_account_id
       AND r.verified_at IS NOT NULL
       AND r.verified_at >= coalesce(p_from, '-infinity'::timestamptz)
       AND r.verified_at <  coalesce(p_to,   'infinity'::timestamptz)
       -- A deposit linked to an operation is counted through the operation line
       -- only; a freed or annulled deposit drops out on the next read.
       AND EXISTS (
         SELECT 1
           FROM public.depositos_mmg d
          WHERE d.trans_id = r.trans_id
            AND d.consumido_en IS NOT NULL
            AND d.anulado_en IS NULL
            AND d.operation_id IS NULL)
  ), ops AS (
    SELECT coalesce(sum(o.quoted_source_amount), 0) AS gyd,
           count(*)::int AS n,
           count(*) FILTER (WHERE o.quoted_source_amount IS NULL)::int AS missing
      FROM public.remittance_operations o, cut
     WHERE o.contact_id = p_contact_id
       AND o.account_id = p_account_id
       AND o.source_currency = 'GYD'
       AND o.status IN ('deposit_received','deposit_verification','ready_to_transfer',
                        'transferring','completed','incident')
       AND o.created_at >= coalesce(p_from, '-infinity'::timestamptz)
       AND o.created_at <  coalesce(p_to,   'infinity'::timestamptz)
       AND o.created_at <  cut.cutover_at
  ), adj AS (
    SELECT coalesce(sum(a.amount_gyd), 0) AS gyd, count(*)::int AS n
      FROM public.reseller_total_adjustments a
     WHERE a.contact_id = p_contact_id
       AND a.account_id = p_account_id
       AND a.created_at >= coalesce(p_from, '-infinity'::timestamptz)
       AND a.created_at <  coalesce(p_to,   'infinity'::timestamptz)
  )
  SELECT dep.gyd, dep.n, ops.gyd, ops.n, ops.missing, adj.gyd, adj.n,
         dep.gyd + ops.gyd, dep.gyd + ops.gyd + adj.gyd
    FROM dep, ops, adj;
$function$;

REVOKE ALL ON FUNCTION public._reseller_period_counts(uuid, uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

-- ─── 7. read model: the five 397 RPCs re-pointed with additive keys ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crm_revendedores_resumen(p_account_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
      CROSS JOIN LATERAL _reseller_period_counts(p_account_id, s.contact_id, l.reset_at, NULL::timestamptz) tp
  ), agg AS (
    SELECT coalesce(sum(deposits_gyd), 0) AS deposits_gyd,
           coalesce(sum(deposits_count), 0)::int AS deposits_count,
           coalesce(sum(operations_gyd), 0) AS operations_gyd,
           coalesce(sum(adjustments_gyd), 0) AS adjustments_gyd,
           coalesce(sum(counted_gyd), 0) AS counted_gyd,
           coalesce(sum(total_gyd), 0) AS total_gyd,
           count(*)::int AS resellers
      FROM rows
  )
  SELECT
    (SELECT coalesce(jsonb_agg(jsonb_build_object(
              'contact_id', r.contact_id,
              'name', r.name,
              'phone', r.phone,
              'period_start', r.period_start,
              'deposits_gyd', r.deposits_gyd,
              'deposits_count', r.deposits_count,
              'operations_gyd', r.operations_gyd,
              'operations_count', r.operations_count,
              'operations_missing_amount', r.operations_missing_amount,
              'adjustments_gyd', r.adjustments_gyd,
              'adjustments_count', r.adjustments_count,
              'counted_gyd', r.counted_gyd,
              'total_gyd', r.total_gyd)
              ORDER BY r.total_gyd DESC, r.name NULLS LAST, r.contact_id),
            '[]'::jsonb)
       FROM rows r),
    (SELECT jsonb_build_object('deposits_gyd', a.deposits_gyd, 'deposits_count', a.deposits_count,
                               'operations_gyd', a.operations_gyd, 'adjustments_gyd', a.adjustments_gyd,
                               'counted_gyd', a.counted_gyd, 'total_gyd', a.total_gyd, 'resellers', a.resellers)
       FROM agg a)
    INTO v_resellers, v_grand;

  RETURN jsonb_build_object('grand', v_grand, 'resellers', v_resellers);
END $function$;

REVOKE ALL ON FUNCTION public.crm_revendedores_resumen(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_revendedores_resumen(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.crm_revendedor_detalle(p_contact_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contact     record;
  v_is_reseller boolean;
  v_latest      timestamptz;
  v_current     record;
  v_adjustments jsonb;
  v_periods     jsonb;
  v_pending     integer;
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
    FROM _reseller_period_counts(v_contact.account_id, p_contact_id, v_latest, NULL::timestamptz);

  SELECT count(*)::int INTO v_pending
    FROM reseller_deposits r
   WHERE r.account_id = v_contact.account_id AND r.contact_id = p_contact_id
     AND r.verified_at IS NULL;

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
    SELECT r.id, r.reset_at, r.batch_id, r.reason, r.closed_total_gyd, r.closed_deposits_gyd, r.created_by,
           lag(r.reset_at) OVER (ORDER BY r.reset_at, r.id) AS start
      FROM reseller_counter_resets r
     WHERE r.account_id = v_contact.account_id AND r.contact_id = p_contact_id
  ), limited AS (
    SELECT * FROM marks ORDER BY reset_at DESC, id DESC LIMIT 100
  ), periods AS (
    SELECT m.id, m.reset_at AS end_at, m.start, m.batch_id, m.reason, m.closed_total_gyd, m.closed_deposits_gyd,
           p.full_name AS reset_by_name, tp.*
      FROM limited m
      LEFT JOIN profiles p ON p.user_id = m.created_by AND p.account_id = v_contact.account_id
      CROSS JOIN LATERAL _reseller_period_counts(v_contact.account_id, p_contact_id, m.start, m.reset_at) tp
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'reset_id', p.id,
           'start', p.start,
           'end', p.end_at,
           'deposits_gyd', p.deposits_gyd,
           'deposits_count', p.deposits_count,
           'operations_gyd', p.operations_gyd,
           'operations_count', p.operations_count,
           'operations_missing_amount', p.operations_missing_amount,
           'adjustments_gyd', p.adjustments_gyd,
           'adjustments_count', p.adjustments_count,
           'counted_gyd', p.counted_gyd,
           'total_gyd', p.total_gyd,
           'closed_total_gyd', p.closed_total_gyd,
           'closed_deposits_gyd', p.closed_deposits_gyd,
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
    'pending_claims', v_pending,
    'current', jsonb_build_object(
       'period_start', v_latest,
       'deposits_gyd', v_current.deposits_gyd,
       'deposits_count', v_current.deposits_count,
       'operations_gyd', v_current.operations_gyd,
       'operations_count', v_current.operations_count,
       'operations_missing_amount', v_current.operations_missing_amount,
       'adjustments_gyd', v_current.adjustments_gyd,
       'adjustments_count', v_current.adjustments_count,
       'counted_gyd', v_current.counted_gyd,
       'total_gyd', v_current.total_gyd,
       'adjustments', v_adjustments),
    'periods', v_periods);
END $function$;

REVOKE ALL ON FUNCTION public.crm_revendedor_detalle(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_revendedor_detalle(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.crm_revendedor_ajustar(p_contact_id uuid, p_monto_gyd numeric, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contact record;
  v_reason  text := nullif(btrim(coalesce(p_motivo, '')), '');
  v_latest  timestamptz;
  v_dep     numeric;
  v_ops     numeric;
  v_adj     numeric;
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
  SELECT tp.deposits_gyd, tp.operations_gyd, tp.adjustments_gyd, tp.total_gyd
    INTO v_dep, v_ops, v_adj, v_before
    FROM _reseller_period_counts(v_contact.account_id, p_contact_id, v_latest, NULL::timestamptz) tp;
  v_after := v_before + p_monto_gyd;

  INSERT INTO reseller_total_adjustments (account_id, contact_id, amount_gyd, reason, created_by, actor)
  VALUES (v_contact.account_id, p_contact_id, p_monto_gyd, v_reason, auth.uid(), v_actor)
  RETURNING id, created_at INTO v_id, v_created;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_contact.account_id, 'reseller_total_adjustments', v_id, 'amount_gyd', 'human_reseller_adjustment', v_actor, v_reason,
          jsonb_build_object('contact_id', p_contact_id, 'deposits_gyd', v_dep, 'operations_gyd', v_ops,
                             'adjustments_gyd', v_adj, 'total_gyd', v_before),
          jsonb_build_object('amount_gyd', p_monto_gyd, 'total_gyd', v_after));

  RETURN jsonb_build_object('adjustment_id', v_id, 'contact_id', p_contact_id, 'amount_gyd', p_monto_gyd,
                            'created_at', v_created, 'total_before_gyd', v_before, 'total_after_gyd', v_after);
END $function$;

REVOKE ALL ON FUNCTION public.crm_revendedor_ajustar(uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_revendedor_ajustar(uuid, numeric, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.crm_revendedor_reiniciar(p_contact_id uuid, p_motivo text DEFAULT NULL::text, p_total_esperado_gyd numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contact      record;
  v_reason       text := nullif(btrim(coalesce(p_motivo, '')), '');
  v_period_start timestamptz;
  v_dep          numeric;
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
  SELECT tp.deposits_gyd, tp.operations_gyd, tp.adjustments_gyd, tp.total_gyd
    INTO v_dep, v_ops, v_adj, v_total
    FROM _reseller_period_counts(v_contact.account_id, p_contact_id, v_period_start, NULL::timestamptz) tp;

  IF p_total_esperado_gyd IS NOT NULL AND p_total_esperado_gyd <> v_total THEN
    RAISE EXCEPTION 'the expected total (%) differs from the current total (%)', p_total_esperado_gyd, v_total
      USING ERRCODE = '40001', HINT = v_total::text;
  END IF;

  v_reset_at := clock_timestamp();
  INSERT INTO reseller_counter_resets (account_id, contact_id, reset_at, batch_id, reason,
         closed_deposits_gyd, closed_operations_gyd, closed_adjustments_gyd, closed_total_gyd, created_by, actor)
  VALUES (v_contact.account_id, p_contact_id, v_reset_at, NULL, v_reason,
          v_dep, v_ops, v_adj, v_total, auth.uid(), v_actor)
  RETURNING id INTO v_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_contact.account_id, 'reseller_counter_resets', v_id, 'counter', 'human_reseller_counter_reset', v_actor, v_reason,
          jsonb_build_object('contact_id', p_contact_id, 'period_start', v_period_start,
                             'deposits_gyd', v_dep, 'operations_gyd', v_ops,
                             'adjustments_gyd', v_adj, 'total_gyd', v_total),
          jsonb_build_object('reset_at', v_reset_at, 'batch_id', NULL, 'total_gyd', 0));

  RETURN jsonb_build_object(
    'reset_id', v_id, 'contact_id', p_contact_id, 'reset_at', v_reset_at,
    'closed', jsonb_build_object('deposits_gyd', v_dep, 'operations_gyd', v_ops,
                                 'adjustments_gyd', v_adj, 'counted_gyd', v_dep + v_ops, 'total_gyd', v_total));
END $function$;

REVOKE ALL ON FUNCTION public.crm_revendedor_reiniciar(uuid, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_revendedor_reiniciar(uuid, text, numeric) TO authenticated;

CREATE OR REPLACE FUNCTION public.crm_revendedores_reiniciar_todos(p_account_id uuid, p_motivo text DEFAULT NULL::text, p_total_esperado_gyd numeric DEFAULT NULL::numeric)
 RETURNS jsonb
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
    SELECT s.contact_id, tp.*
      FROM resellers s
      LEFT JOIN latest l ON l.contact_id = s.contact_id
      CROSS JOIN LATERAL _reseller_period_counts(p_account_id, s.contact_id, l.reset_at, NULL::timestamptz) tp
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
      CROSS JOIN LATERAL _reseller_period_counts(p_account_id, s.contact_id, l.reset_at, NULL::timestamptz) tp
  ), target AS (
    SELECT * FROM rows WHERE total_gyd <> 0
  ), ins AS (
    INSERT INTO reseller_counter_resets (account_id, contact_id, reset_at, batch_id, reason,
           closed_deposits_gyd, closed_operations_gyd, closed_adjustments_gyd, closed_total_gyd, created_by, actor)
    SELECT p_account_id, t.contact_id, v_reset_at, v_batch, v_reason,
           t.deposits_gyd, t.operations_gyd, t.adjustments_gyd, t.total_gyd, auth.uid(), v_actor
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
