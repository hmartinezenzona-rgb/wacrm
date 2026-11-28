-- =====================================================================
-- 164_deals_free_views_and_inert_edits
--
-- WU6a of the eliminate-deals feature. The live staging catalog still held
-- 16 objects with a live reference to `deals` (3 views + 13 functions).
-- This migration retires the SEVEN whose removal changes nothing a caller
-- can observe today, taking the DDL blockers off `DROP TABLE deals`:
--
--   views      cerebro_historial_operaciones   (drop the LEFT JOIN deals)
--              cerebro_volumen_diario          (drop the LEFT JOIN deals)
--              cerebro_conciliacion_operaciones (DROP VIEW — product decision)
--   functions  merge_duplicate_contacts       (delete the UPDATE deals line)
--              crm_entregar_operacion          (delete the deal-lock block)
--              cerebro_avisar_remesas_abiertas_viejas (drop both LEFT JOINs)
--              cerebro_saldo_envio             (rewrite as a wrapper)
--
-- The other nine objects that reference `deals` (the WU6b/c/d units and the
-- two unallocated ones) are NOT touched here.
--
-- WHY EACH EDIT IS OBSERVABLY INERT (proved in
-- supabase/staging/assertions/deals-free-views-and-inert-edits.sql):
--
--   * The two surviving views only used `deals` to feed
--     `coalesce(o.quoted_source_amount, d.value, 0)`. On staging ZERO rows
--     have `quoted_source_amount IS NULL` with a non-zero `d.value`, so the
--     fallback is dead weight today; dropping it cannot change a row.
--   * `cerebro_conciliacion_operaciones` had `deals` as the driving `FROM` of
--     branch 1 and every branch read `d`. It is an internal drift-audit over
--     the deal<->operation bridge; that bridge is being retired, so the view
--     is dropped by explicit product decision. Nothing depends on it:
--     pg_depend reports no dependent object, and no function body names it.
--   * `merge_duplicate_contacts` re-pointed `deals.contact_id` to the
--     surviving contact. `deals.contact_id` is ON DELETE SET NULL, and
--     staging holds ZERO duplicate contact groups today, so the function is a
--     no-op; deleting the line changes nothing observable on existing data.
--     (Inherent consequence for a FUTURE merge: a deal attached to an
--     absorbed contact lands on NULL instead of the survivor. That is
--     unavoidable once `deals` goes away, and is reported, not hidden.)
--   * `crm_entregar_operacion` took a `FOR UPDATE` lock on the deal row only
--     to ORDER against retired n8n `deals.notes/value` writes. It is inside
--     `IF v_deal_id IS NOT NULL`, touches no result, and its removal cannot
--     change the returned jsonb or any row.
--   * `cerebro_avisar_remesas_abiertas_viejas` was already operation-driven;
--     the two LEFT JOINs only supplied `d.value` (a dead fallback, as above)
--     and `s.name` for the trailing " (etapa)" label in the message text.
--     Row set and `cerebro_alertas.clave` are unchanged; only the label is
--     gone from the body, which is shown, not hidden.
--   * `cerebro_saldo_envio` is `LANGUAGE sql`, so the `deals` reference is
--     baked into its compiled body — a hard DDL blocker that needs
--     `CREATE OR REPLACE`, not a control-flow edit. It becomes a thin wrapper
--     over the already-existing operation-keyed twin `cerebro_saldo_operacion`
--     (158), which provably has the identical return type
--     `TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)`.
--     Verified on the live catalog: for all 35 deals the wrapper returns the
--     exact same row as the body it replaces, and for a deal with no
--     operation (and for NULL) it returns the same `(NULL, 0, NULL, 'GYD')`.
--
-- Constraints honoured: no new `deals` / `pipelines` / `pipeline_stages`
-- reads; only the seven named objects are redefined; no existing assertion
-- is weakened. `cerebro_saldo_envio` keeps `LANGUAGE sql`, its exact
-- signature and its order of columns.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. cerebro_historial_operaciones — drop the deals join.
--    Column list, names and order are byte-preserved from 114.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.cerebro_historial_operaciones AS
SELECT
  ((coalesce(o.completed_at, o.updated_at)) AT TIME ZONE 'America/Guyana')::date AS dia,
  o.service_type,
  o.status,
  ct.name   AS cliente,
  ct.phone  AS telefono,
  coalesce(o.quoted_source_amount, 0) AS monto_gyd,
  o.destination_currency,
  b.beneficiary_type,
  b.name    AS beneficiario,
  CASE WHEN b.card_number IS NOT NULL
       THEN left(b.card_number,4) || '****' || right(b.card_number,4) END AS tarjeta,
  b.phone   AS celular_beneficiario,
  b.zelle_account,
  o.deal_id,
  o.id      AS operation_id,
  o.created_at,
  o.completed_at
FROM remittance_operations o
LEFT JOIN conversations cv ON cv.id = o.conversation_id
LEFT JOIN contacts ct      ON ct.id = coalesce(o.contact_id, cv.contact_id)
LEFT JOIN remittance_beneficiaries b
       ON b.operation_id = o.id AND b.status = 'vigente';

COMMENT ON VIEW public.cerebro_historial_operaciones IS
  '053, repointed by 114, deal-free by 164: monto_gyd is now '
  'coalesce(remittance_operations.quoted_source_amount, 0). The legacy '
  'deals.value fallback is gone with the deals table; on staging no row '
  'ever needed it. Row shape unchanged.';

-- ---------------------------------------------------------------------
-- 2. cerebro_volumen_diario — same edit, same reasoning.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.cerebro_volumen_diario AS
SELECT
  ((coalesce(o.completed_at, o.updated_at)) AT TIME ZONE 'America/Guyana')::date AS dia,
  o.service_type,
  count(*)                                        AS operaciones,
  sum(coalesce(o.quoted_source_amount, 0))        AS volumen_gyd,
  round(avg(coalesce(o.quoted_source_amount, 0))) AS ticket_medio_gyd
FROM remittance_operations o
WHERE o.status = 'completed'
GROUP BY 1, 2;

COMMENT ON VIEW public.cerebro_volumen_diario IS
  '053, repointed by 114, deal-free by 164: same coalesce change as '
  'cerebro_historial_operaciones. Row shape unchanged.';

-- ---------------------------------------------------------------------
-- 3. cerebro_conciliacion_operaciones — DROP VIEW (product decision).
--    `deals` was the driving FROM of branch 1, and all three branches read
--    `d`. There is no deal-free equivalent worth keeping: it audits drift
--    across a bridge that ceases to exist. pg_depend shows no dependent
--    object and no function body names it.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS public.cerebro_conciliacion_operaciones;

-- ---------------------------------------------------------------------
-- 4. merge_duplicate_contacts — delete the `UPDATE deals` line.
--    Everything else is byte-for-byte the live body from 022.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.merge_duplicate_contacts()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group   RECORD;
  v_survivor UUID;
  v_losers   UUID[];
  v_merged   INTEGER := 0;
BEGIN
  FOR v_group IN
    SELECT account_id,
           phone_normalized,
           array_agg(id ORDER BY created_at ASC, id ASC) AS ids
    FROM contacts
    WHERE phone_normalized <> ''
    GROUP BY account_id, phone_normalized
    HAVING count(*) > 1
  LOOP
    v_survivor := v_group.ids[1];
    v_losers   := v_group.ids[2:array_length(v_group.ids, 1)];

    -- Plain re-point: these tables have no contact-scoped unique
    -- constraint. `conversations` is ON DELETE CASCADE, so this
    -- re-point is what saves its rows (and their messages) from
    -- being deleted with the loser contact.
    UPDATE conversations                 SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE contact_notes                 SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE broadcast_recipients          SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE automation_logs               SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE automation_pending_executions SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);

    -- Conflict-guarded re-point for UNIQUE(contact_id, tag_id):
    -- move only tags the survivor doesn't already have, drop the rest.
    UPDATE contact_tags ct SET contact_id = v_survivor
      WHERE ct.contact_id = ANY(v_losers)
        AND NOT EXISTS (
          SELECT 1 FROM contact_tags s
          WHERE s.contact_id = v_survivor AND s.tag_id = ct.tag_id
        );
    DELETE FROM contact_tags WHERE contact_id = ANY(v_losers);

    -- Same guard for UNIQUE(contact_id, custom_field_id). Survivor's
    -- own value wins on conflict.
    UPDATE contact_custom_values cv SET contact_id = v_survivor
      WHERE cv.contact_id = ANY(v_losers)
        AND NOT EXISTS (
          SELECT 1 FROM contact_custom_values s
          WHERE s.contact_id = v_survivor AND s.custom_field_id = cv.custom_field_id
        );
    DELETE FROM contact_custom_values WHERE contact_id = ANY(v_losers);

    -- flow_runs has a partial UNIQUE on active runs per contact.
    -- Re-point only NON-active runs (exempt from the partial index)
    -- to preserve history; any active loser run is left to be
    -- NULLed by its FK's ON DELETE SET NULL when the loser is
    -- removed below — avoids colliding with the survivor's active run.
    UPDATE flow_runs SET contact_id = v_survivor
      WHERE contact_id = ANY(v_losers) AND status <> 'active';

    DELETE FROM contacts WHERE id = ANY(v_losers);

    v_merged := v_merged + COALESCE(array_length(v_losers, 1), 0);
  END LOOP;

  RETURN v_merged;
END;
$$;

ALTER FUNCTION public.merge_duplicate_contacts() OWNER TO postgres;
REVOKE EXECUTE ON FUNCTION public.merge_duplicate_contacts() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merge_duplicate_contacts() TO service_role;

-- ---------------------------------------------------------------------
-- 5. crm_entregar_operacion — delete the deal-lock block.
--    Byte-for-byte the live body from 143 minus the `PERFORM 1 FROM deals`
--    ordering lock. `v_deal_id` is still selected; only the lock is gone.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id    uuid;
  v_deal_id       uuid;

  v_status_before text;
  v_status_after  text;
  v_completed_at  timestamptz;

  v_mode          text;
  v_wamid         text;
  v_path          text;
BEGIN
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to deliver this operation' USING ERRCODE = '42501';
  END IF;

  IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'evidence must be a JSON object' USING ERRCODE = '22023';
  END IF;

  v_mode := p_evidence ->> 'mode';
  IF v_mode IS NULL OR v_mode NOT IN ('proof_sent', 'no_proof', 'skip_proof') THEN
    RAISE EXCEPTION 'evidence mode must be proof_sent, no_proof or skip_proof' USING ERRCODE = '22023';
  END IF;

  IF p_evidence ? 'wamid' AND (p_evidence -> 'wamid') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'wamid') <> 'string' THEN
      RAISE EXCEPTION 'evidence wamid must be a string' USING ERRCODE = '22023';
    END IF;
    v_wamid := p_evidence ->> 'wamid';
    IF v_wamid = '' OR length(v_wamid) > 500 THEN
      RAISE EXCEPTION 'evidence wamid must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_evidence ? 'path' AND (p_evidence -> 'path') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'path') <> 'string' THEN
      RAISE EXCEPTION 'evidence path must be a string' USING ERRCODE = '22023';
    END IF;
    v_path := p_evidence ->> 'path';
    IF v_path = '' OR length(v_path) > 500 THEN
      RAISE EXCEPTION 'evidence path must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- (164) The ordering lock that stood here — a `FOR UPDATE` on the legacy
  -- deal row — was removed with the legacy table. It only serialized
  -- against retired n8n notes/value writes and touched no result.

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  IF NOT crm_beneficiarios_completos(p_operation_id) THEN
    RAISE EXCEPTION 'beneficiary data is incomplete' USING ERRCODE = '22023';
  END IF;

  -- (143) With proof and 2+ current beneficiaries, every beneficiary needs
  -- its own proof (crm_registrar_prueba_beneficiario) before delivering.
  IF v_mode = 'proof_sent' AND crm_pruebas_faltantes(p_operation_id) > 0 THEN
    RAISE EXCEPTION 'every beneficiary needs its delivery proof before delivering (% missing)',
      crm_pruebas_faltantes(p_operation_id)
      USING ERRCODE = '22023';
  END IF;

  -- (114) One statement: status, evidence, completed_at (the latter set
  -- automatically by trg_remittance_operations_touch, 040) all land in
  -- the same NEW row image the calculator feed trigger reads.
  UPDATE remittance_operations
     SET status = 'completed',
         delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid()
   WHERE id = p_operation_id
     AND status = 'ready_to_transfer'
  RETURNING status, completed_at INTO v_status_after, v_completed_at;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer'),
          jsonb_build_object('status', 'completed', 'evidence', p_evidence));

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $$;

-- 143's grant posture is preserved exactly: the panel calls this as an
-- authenticated user, so `authenticated` MUST keep EXECUTE.
REVOKE ALL ON FUNCTION public.crm_entregar_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_entregar_operacion(uuid, jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6. cerebro_avisar_remesas_abiertas_viejas — drop both LEFT JOINs.
--    `deals` only fed the dead `d.value` fallback; `pipeline_stages` only
--    fed the " (etapa)" label appended to every line of the message body.
--    Row set, `cerebro_alertas.clave` and the notification title are
--    unchanged; only that label disappears from the body text.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_avisar_remesas_abiertas_viejas(p_horas integer DEFAULT NULL::integer, p_ignorar_horario boolean DEFAULT false)
 RETURNS TABLE(viejas integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_horas    int;
  v_repetir  int;
  v_desde    time;
  v_ahora_gy timestamp;
  v_n        int := 0;
  v_avisos   int := 0;
  v_creados  int;
  r          record;
BEGIN
  v_horas   := COALESCE(p_horas, NULLIF(cerebro_config_get('remesas_viejas_horas'), '')::int, 48);
  v_repetir := COALESCE(NULLIF(cerebro_config_get('remesas_viejas_repetir_min'), '')::int, 1200);
  v_desde   := COALESCE(NULLIF(cerebro_config_get('remesas_viejas_desde'), '')::time, (SELECT abre FROM cerebro_horario()));

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF NOT p_ignorar_horario AND (EXTRACT(DOW FROM v_ahora_gy) = 0 OR v_ahora_gy::time < v_desde) THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  -- One summary per account.
  FOR r IN
    SELECT o.account_id, count(*)::int AS n,
           string_agg('- ' || COALESCE(NULLIF(c.name, ''), c.phone, 'cliente') || ': '
                      || CASE WHEN COALESCE(NULLIF(o.quoted_source_amount, 0), 0) > 0
                              THEN rtrim(trim(to_char(COALESCE(NULLIF(o.quoted_source_amount, 0), 0), 'FM999,999,999,990.99')), '.') || ' GYD'
                              ELSE 'sin deposito' END
                      || ', abierta hace ' || floor(EXTRACT(EPOCH FROM (now() - o.created_at)) / 86400)::int || ' dias',
                      E'\n' ORDER BY o.created_at) AS lista
      FROM remittance_operations o
      LEFT JOIN conversations v ON v.id = o.conversation_id
      LEFT JOIN contacts c ON c.id = v.contact_id
     WHERE o.status NOT IN ('completed', 'cancelled')
       AND COALESCE(o.service_type, 'remesa') <> 'recarga'
       AND o.created_at < now() - make_interval(hours => v_horas)
     GROUP BY o.account_id
  LOOP
    v_n := v_n + r.n;
    CONTINUE WHEN EXISTS (SELECT 1 FROM cerebro_alertas a
                           WHERE a.clave = 'remesas_viejas:' || r.account_id::text
                             AND a.ultimo > now() - make_interval(mins => v_repetir));

    INSERT INTO notifications (account_id, user_id, type, title, body)
    SELECT r.account_id, p.user_id, 'remesa_abierta_vieja',
           r.n || CASE WHEN r.n = 1 THEN ' remesa abierta' ELSE ' remesas abiertas' END
             || ' hace mas de ' || v_horas || ' h',
           'Si ya se pagaron, marquelas como Entregadas en el panel; si no van, cancelelas. '
             || 'Una remesa vieja abierta puede hacer que los datos de una remesa nueva del mismo '
             || 'cliente se asignen a la vieja.' || E'\n\n' || r.lista
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);
    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('remesas_viejas:' || r.account_id::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END $function$;

REVOKE EXECUTE ON FUNCTION public.cerebro_avisar_remesas_abiertas_viejas(integer, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_avisar_remesas_abiertas_viejas(integer, boolean) TO service_role;

-- ---------------------------------------------------------------------
-- 7. cerebro_saldo_envio — becomes a wrapper over cerebro_saldo_operacion.
--    `LANGUAGE sql` is kept, the signature is kept, and the body no longer
--    names `deals`. It resolves the deal's operation and delegates; with no
--    operation (or NULL) cerebro_saldo_operacion returns exactly one row,
--    (NULL, 0, NULL, 'GYD'), which is what the old fallback produced too.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerebro_saldo_envio(p_deal uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT s.objetivo, s.depositado, s.saldo, s.moneda
    FROM (SELECT (SELECT ro.id
                    FROM remittance_operations ro
                   WHERE ro.deal_id = p_deal) AS id) op
    CROSS JOIN LATERAL cerebro_saldo_operacion(op.id) s;
$function$;

COMMENT ON FUNCTION public.cerebro_saldo_envio(uuid) IS
  '109/158, deal-free by 164: a thin wrapper over cerebro_saldo_operacion, '
  'resolved through remittance_operations.deal_id. Always exactly one row, '
  'same shape and values as the body it replaces (proven on staging).';

REVOKE EXECUTE ON FUNCTION public.cerebro_saldo_envio(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_saldo_envio(uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
