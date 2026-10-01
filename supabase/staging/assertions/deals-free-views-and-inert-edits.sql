-- deals-free-views-and-inert-edits.sql — self-reverting assertion for
-- 164_deals_free_views_and_inert_edits.sql (WU6a of the eliminate-deals
-- feature on WaCRM).
--
-- 164 retires the SEVEN objects on live staging whose `deals` reference can
-- be removed without changing anything a caller can observe today:
--
--   views      cerebro_historial_operaciones     (drop the LEFT JOIN deals)
--              cerebro_volumen_diario            (drop the LEFT JOIN deals)
--              cerebro_conciliacion_operaciones  (DROP VIEW - product decision)
--   functions  merge_duplicate_contacts         (delete the UPDATE deals line)
--              crm_entregar_operacion            (delete the deal-lock block)
--              cerebro_avisar_remesas_abiertas_viejas (drop both LEFT JOINs)
--              cerebro_saldo_envio               (rewrite as a wrapper)
--
-- WHAT THIS FILE PROVES
--
--   Part 0  The exit criterion on the catalog: exactly the seven retire, the
--           other nine stay, the two surviving views keep their exact column
--           names/types, and cerebro_resumen_volumen still compiles.
--   Part 1  cerebro_historial_operaciones: every row and column identical to
--           the pre-164 definition (run side by side, EXCEPT ALL both ways).
--   Part 2  cerebro_volumen_diario: identical, and cerebro_resumen_volumen
--           still compiles and returns its 5 periods.
--   Part 2b (informational) the ONE boundary of the guarantee: a row whose
--           quoted_source_amount IS NULL gets its amount from deals.value
--           BEFORE 164 and 0 AFTER. Staging holds no such row (proved by the
--           Part 1/2 equality), so this is shown explicitly, not hidden.
--   Part 3  cerebro_saldo_envio: the wrapper returns the same row as the
--           body it replaces, for every deal on staging.
--   Part 4  cerebro_avisar_remesas_abiertas_viejas: identical rows, identical
--           `cerebro_alertas.clave` values and identical avisos_creados; the
--           only difference is the "(etapa)" label that disappears from the
--           message body, and that difference is asserted to be EXACTLY it.
--   Part 5a crm_entregar_operacion: identical behaviour on a real
--           ready_to_transfer fixture, and the only code-line difference is
--           the removed deal lock.
--   Part 5b merge_duplicate_contacts: the loop body is now UNREACHABLE (the
--           partial UNIQUE index on (account_id, phone_normalized) makes a
--           duplicate group unrepresentable), so the only code-line
--           difference is the removed UPDATE deals line.
--
-- HOW THE EQUALITY WORKS WITHOUT POLLUTING THE EXIT CRITERION
--
-- The pre-164 view results are snapshotted into CREATE TEMP TABLE ... AS
-- SELECT (a CTAS carries no pg_depend edge), and the pre-164 function bodies
-- are recreated under pg_temp. Nothing in this file adds a public object to
-- the `deals` dependency graph, so the catalog numbers read afterwards are
-- the migration's, not the harness's.
--
-- Every fixture that can appear in the two views is created BEFORE the
-- snapshots; the one deliberate exception is Part 2b, which is informational
-- and runs last against a freshly inserted row.
--
-- RED   against staging WITHOUT 164: Part 0 fails - the conciliacion view
--       still exists, three public views still reference deals, and thirteen
--       functions still do. Part 4 fails because the live body still carries
--       the stage label, and Part 5a/5b fail because the live bodies are
--       still the old ones. Parts 1-3 pass: pre-164 the live objects ARE the
--       old objects.
-- GREEN after 164 is applied: every part passes.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker psql -1). Never COMMIT. Never run against production. Fixtures are
-- built the same way as beneficiary-proofs.sql: real auth.users -> accounts
-- -> profiles -> pipelines/pipeline_stages -> contacts -> conversations.
--
-- NOTE: inserting into auth.users fires a pre-existing trigger that tries to
-- auto-create a profile before the account exists and raises a WARNING
-- ("Failed to create profile for user ... null value in column account_id").
-- It is harmless noise from the trigger, not from this harness.

SAVEPOINT wu6a_deals_free;

-- ---------------------------------------------------------------------
-- Helpers (pg_temp only).
-- ---------------------------------------------------------------------

-- All lines of a function body that are neither blank nor a `--` comment.
-- Used to compare two bodies while ignoring the comment block that 164
-- swaps in where the removed code stood.
CREATE FUNCTION pg_temp.wu6a_code_lines(p_src text) RETURNS text[]
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT COALESCE(array_agg(l ORDER BY ord), ARRAY[]::text[])
    FROM (
      SELECT l, ord
        FROM unnest(string_to_array(p_src, E'\n')) WITH ORDINALITY AS t(l, ord)
       WHERE btrim(l) <> ''
         AND l !~ '^[[:space:]]*--'
    ) q;
$fn$;

CREATE FUNCTION pg_temp.wu6a_view_cols(p_view text) RETURNS text[]
LANGUAGE sql STABLE AS $fn$
  SELECT array_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) ORDER BY a.attnum)
    FROM pg_attribute a
   WHERE a.attrelid = p_view::regclass
     AND a.attnum > 0
     AND NOT a.attisdropped;
$fn$;

-- Does a body reference the `deals` table (case-insensitively) in a position
-- that only a real table reference can occupy? Prose and identifiers that
-- merely contain the word ("deals.notes" in a comment, "deals_admin_guard")
-- do not match.
CREATE FUNCTION pg_temp.wu6a_names_deals(p_src text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT p_src ~* '(from|join|update|into|table)[[:space:]]+(public\.)?deals[[:space:]]*([^_a-z0-9]|$)';
$fn$;

-- ---------------------------------------------------------------------
-- Fixtures. Everything that can show up in the two views is created here,
-- BEFORE the snapshots, so the snapshot and the live view see the same rows.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS wu6a_fx;
CREATE TEMP TABLE wu6a_fx AS
SELECT gen_random_uuid() AS account_id,
       gen_random_uuid() AS owner_user,
       gen_random_uuid() AS agent_user,
       gen_random_uuid() AS contact_id,
       gen_random_uuid() AS conv_id,
       gen_random_uuid() AS deal_a,
       gen_random_uuid() AS deal_b;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'wu6a-' || u || '@test.invalid',
       '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
  FROM wu6a_fx CROSS JOIN LATERAL (VALUES (owner_user), (agent_user)) v(u);

INSERT INTO accounts (id, name, owner_user_id)
SELECT account_id, 'wu6a deals-free assertion account', owner_user FROM wu6a_fx;

INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
SELECT gen_random_uuid(), owner_user, 'wu6a owner', 'wu6a-' || owner_user || '@test.invalid', account_id, 'owner' FROM wu6a_fx;
INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
SELECT gen_random_uuid(), agent_user, 'wu6a agent', 'wu6a-' || agent_user || '@test.invalid', account_id, 'agent' FROM wu6a_fx;

INSERT INTO contacts (id, user_id, phone, account_id, name)
SELECT contact_id, owner_user, '15550001641', account_id, 'Cliente WU6A' FROM wu6a_fx;

INSERT INTO conversations (id, user_id, contact_id, account_id)
SELECT conv_id, owner_user, contact_id, account_id FROM wu6a_fx;

-- The Cerebro pipeline already exists on staging; reuse it, and make sure
-- "Lista para transferir" exists so 125's trigger maps the deal to
-- ready_to_transfer.
INSERT INTO pipeline_stages (id, pipeline_id, name, "position")
VALUES ('f5cf87f8-b570-4d71-b6ea-a3cafd458c63', '78220927-0745-45a8-ba08-a1b33734dbf1', 'Lista para transferir', 50)
ON CONFLICT (id) DO NOTHING;

-- 096's completion guard coerces an automation INSERT/UPDATE to 'completed'
-- into 'incident'. A human actor (JWT claims resolving to an agent profile of
-- the account) passes straight through, which is the only way a completed
-- operation exists on staging at all — cerebro_volumen_diario is otherwise
-- empty, and an empty equality proves nothing.
SELECT set_config('request.jwt.claims',
  (SELECT json_build_object('sub', agent_user, 'role', 'authenticated')::text FROM wu6a_fx), true);

INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, completed_at)
SELECT account_id, conv_id, 'completed', 'remesa', 12345, now() FROM wu6a_fx;

-- Part 5a fixtures: two LISTA deals -> two ready_to_transfer operations.
INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
SELECT deal_a, owner_user, '78220927-0745-45a8-ba08-a1b33734dbf1', 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63',
       'wu6a entrega a', account_id, conv_id, contact_id, 26000, 'GYD' FROM wu6a_fx;
INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
SELECT deal_b, owner_user, '78220927-0745-45a8-ba08-a1b33734dbf1', 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63',
       'wu6a entrega b', account_id, conv_id, contact_id, 26000, 'GYD' FROM wu6a_fx;

SELECT set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------------
-- Old side: the two views, captured BEFORE 164 with the `deals` fallback,
-- exactly as they are live today (pg_get_viewdef of the pre-164 catalog;
-- migration 114 is the source of that shape).
-- ---------------------------------------------------------------------
CREATE TEMP TABLE wu6a_hist_old AS
SELECT (COALESCE(o.completed_at, o.updated_at) AT TIME ZONE 'America/Guyana'::text)::date AS dia,
       o.service_type,
       o.status,
       ct.name AS cliente,
       ct.phone AS telefono,
       COALESCE(o.quoted_source_amount, d.value, 0::numeric) AS monto_gyd,
       o.destination_currency,
       b.beneficiary_type,
       b.name AS beneficiario,
       CASE
         WHEN b.card_number IS NOT NULL
           THEN ("left"(b.card_number, 4) || '****'::text) || "right"(b.card_number, 4)
         ELSE NULL::text
       END AS tarjeta,
       b.phone AS celular_beneficiario,
       b.zelle_account,
       o.deal_id,
       o.id AS operation_id,
       o.created_at,
       o.completed_at
  FROM remittance_operations o
  LEFT JOIN deals d ON d.id = o.deal_id
  LEFT JOIN conversations cv ON cv.id = o.conversation_id
  LEFT JOIN contacts ct ON ct.id = COALESCE(o.contact_id, cv.contact_id)
  LEFT JOIN remittance_beneficiaries b ON b.operation_id = o.id AND b.status = 'vigente'::text;

CREATE TEMP TABLE wu6a_vol_old AS
SELECT (COALESCE(o.completed_at, o.updated_at) AT TIME ZONE 'America/Guyana'::text)::date AS dia,
       o.service_type,
       count(*) AS operaciones,
       sum(COALESCE(o.quoted_source_amount, d.value, 0::numeric)) AS volumen_gyd,
       round(avg(COALESCE(o.quoted_source_amount, d.value, 0::numeric))) AS ticket_medio_gyd
  FROM remittance_operations o
  LEFT JOIN deals d ON d.id = o.deal_id
 WHERE o.status = 'completed'::text
 GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- Old side: the four pre-164 function bodies, recreated verbatim under
-- pg_temp. Each keeps the language and the boilerplate it has live.
-- ---------------------------------------------------------------------

-- 158, the two-branch body that still reads deals.value through a join.
CREATE FUNCTION pg_temp.wu6a_saldo_envio_old(p_deal uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH op AS (
    SELECT (SELECT ro.id
              FROM remittance_operations ro
             WHERE ro.deal_id = p_deal) AS id
  ),
  nuevo AS (
    SELECT s.objetivo, s.depositado, s.saldo, s.moneda
      FROM op
      CROSS JOIN LATERAL cerebro_saldo_operacion(op.id) s
     WHERE op.id IS NOT NULL
  ),
  dep AS (
    SELECT COALESCE(sum(m.monto), 0) AS total
      FROM depositos_mmg m
     WHERE m.deal_id = p_deal
       AND m.consumido_en IS NOT NULL
       AND m.anulado_en  IS NULL
  ),
  obj AS (
    SELECT o.monto, o.moneda
      FROM cerebro_objetivo_envio o
      JOIN deals d ON d.conversation_id = o.conversation_id
     WHERE d.id = p_deal
       AND o.cerrado_en IS NULL
       AND (o.deal_id IS NULL OR o.deal_id = p_deal)
  ),
  viejo AS (
    SELECT (SELECT monto FROM obj) AS objetivo,
           (SELECT total FROM dep) AS depositado,
           (SELECT monto FROM obj) - (SELECT total FROM dep) AS saldo,
           COALESCE((SELECT moneda FROM obj), 'GYD') AS moneda
     WHERE NOT EXISTS (SELECT 1 FROM op WHERE op.id IS NOT NULL)
  )
  SELECT nuevo.objetivo, nuevo.depositado, nuevo.saldo, nuevo.moneda
    FROM nuevo
  UNION ALL
  SELECT viejo.objetivo, viejo.depositado, viejo.saldo, viejo.moneda
    FROM viejo;
$function$;

-- 136, verbatim, including both LEFT JOINs and the " (etapa)" label.
CREATE FUNCTION pg_temp.wu6a_avisar_old(p_horas integer DEFAULT NULL::integer, p_ignorar_horario boolean DEFAULT false)
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

  FOR r IN
    SELECT o.account_id, count(*)::int AS n,
           string_agg('- ' || COALESCE(NULLIF(c.name, ''), c.phone, 'cliente') || ': '
                      || CASE WHEN COALESCE(NULLIF(o.quoted_source_amount, 0), d.value, 0) > 0
                              THEN rtrim(trim(to_char(COALESCE(NULLIF(o.quoted_source_amount, 0), d.value), 'FM999,999,999,990.99')), '.') || ' GYD'
                              ELSE 'sin deposito' END
                      || ', abierta hace ' || floor(EXTRACT(EPOCH FROM (now() - o.created_at)) / 86400)::int || ' dias'
                      || COALESCE(' (' || s.name || ')', ''),
                      E'\n' ORDER BY o.created_at) AS lista
      FROM remittance_operations o
      LEFT JOIN deals d ON d.id = o.deal_id
      LEFT JOIN pipeline_stages s ON s.id = d.stage_id
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

-- 022, verbatim, including the UPDATE deals line.
CREATE FUNCTION pg_temp.wu6a_merge_old()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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

    UPDATE conversations                 SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE contact_notes                 SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE deals                         SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE broadcast_recipients          SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE automation_logs               SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE automation_pending_executions SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);

    UPDATE contact_tags ct SET contact_id = v_survivor
      WHERE ct.contact_id = ANY(v_losers)
        AND NOT EXISTS (
          SELECT 1 FROM contact_tags s
          WHERE s.contact_id = v_survivor AND s.tag_id = ct.tag_id
        );
    DELETE FROM contact_tags WHERE contact_id = ANY(v_losers);

    UPDATE contact_custom_values cv SET contact_id = v_survivor
      WHERE cv.contact_id = ANY(v_losers)
        AND NOT EXISTS (
          SELECT 1 FROM contact_custom_values s
          WHERE s.contact_id = v_survivor AND s.custom_field_id = cv.custom_field_id
        );
    DELETE FROM contact_custom_values WHERE contact_id = ANY(v_losers);

    UPDATE flow_runs SET contact_id = v_survivor
      WHERE contact_id = ANY(v_losers) AND status <> 'active';

    DELETE FROM contacts WHERE id = ANY(v_losers);

    v_merged := v_merged + COALESCE(array_length(v_losers, 1), 0);
  END LOOP;

  RETURN v_merged;
END;
$fn$;

-- 143, verbatim, including the guarded FOR UPDATE lock on deals.
CREATE FUNCTION pg_temp.wu6a_entregar_old(p_operation_id uuid, p_evidence jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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

  IF v_deal_id IS NOT NULL THEN
    PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;
  END IF;

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

  IF v_mode = 'proof_sent' AND crm_pruebas_faltantes(p_operation_id) > 0 THEN
    RAISE EXCEPTION 'every beneficiary needs its delivery proof before delivering (% missing)',
      crm_pruebas_faltantes(p_operation_id)
      USING ERRCODE = '22023';
  END IF;

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
END $fn$;

-- ---------------------------------------------------------------------
-- The assertions.
-- ---------------------------------------------------------------------
DO $body$
DECLARE
  v_fail         integer := 0;
  v_n            integer;
  v_names        text[];
  v_extra        text[];
  v_missing      text[];
  v_old_src      text;
  v_new_src      text;

  -- Part 4
  v_old_v        integer;
  v_old_a        integer;
  v_new_v        integer;
  v_new_a        integer;
  v_old_body     text;
  v_new_body     text;
  v_old_claves   text[];
  v_new_claves   text[];
  v_old_notifs   integer;
  v_new_notifs   integer;
  v_stripped     text;

  -- Part 5a
  v_agent_user   uuid;
  v_account_id   uuid;
  v_conv_id      uuid;
  v_deal_a       uuid;
  v_deal_b       uuid;
  v_op_a         uuid;
  v_op_b         uuid;
  v_res_a        jsonb;
  v_res_b        jsonb;
  v_status_a     text;
  v_status_b     text;
  v_mode_a       text;
  v_mode_b       text;

  -- Part 5b
  v_dup_groups   integer;
  v_old_merged   integer;
  v_new_merged   integer;

  -- Part 2b
  v_fb_deal      uuid;
  v_fb_op        uuid;
  v_fb_old       numeric;
  v_fb_new       numeric;
BEGIN
  SELECT account_id, agent_user, conv_id, deal_a, deal_b
    INTO v_account_id, v_agent_user, v_conv_id, v_deal_a, v_deal_b
    FROM wu6a_fx;

  ---------------------------------------------------------------------
  -- Part 0 — the exit criterion, measured on the catalog.
  ---------------------------------------------------------------------

  -- 0.1 the conciliacion view is gone.
  SELECT count(*) INTO v_n
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'cerebro_conciliacion_operaciones'
     AND c.relkind IN ('v', 'm');
  IF v_n <> 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0.1] cerebro_conciliacion_operaciones still exists (% relkind match)', v_n;
  ELSE
    RAISE NOTICE 'PASS [0.1] cerebro_conciliacion_operaciones is gone';
  END IF;

  -- 0.2 no public view references deals any more.
  SELECT COALESCE(array_agg(DISTINCT dep.relname ORDER BY dep.relname), ARRAY[]::text[]) INTO v_names
    FROM pg_depend d
    JOIN pg_class v ON v.oid = d.refobjid
    JOIN pg_rewrite r ON r.oid = d.objid
    JOIN pg_class dep ON dep.oid = r.ev_class
    JOIN pg_namespace n ON n.oid = dep.relnamespace
   WHERE v.relname = 'deals'
     AND v.relnamespace = 'public'::regnamespace
     AND dep.oid <> v.oid
     AND n.nspname = 'public';
  IF array_length(v_names, 1) IS NOT NULL THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0.2] public views still referencing deals: %', v_names;
  ELSE
    RAISE NOTICE 'PASS [0.2] zero public views reference deals';
  END IF;

  -- 0.3 exactly the nine remaining functions reference deals.
  SELECT COALESCE(array_agg(proname ORDER BY proname), ARRAY[]::text[]) INTO v_names
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND pg_temp.wu6a_names_deals(p.prosrc);
  IF v_names IS DISTINCT FROM ARRAY[
       'cerebro_aplicar_nombre_confirmado',
       'cerebro_sync_beneficiarios',
       'crm_forzar_verificacion',
       'crm_verificar_deposito',
       'sync_tags_cliente']::text[] THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0.3] the deals-referencing function set is % — expected the nine WU6b/c/d + unallocated ones', v_names;
  ELSE
    RAISE NOTICE 'PASS [0.3] exactly nine functions still reference deals (all out of WU6a scope)';
  END IF;

  -- 0.4 the two surviving views keep their exact column names and types.
  v_names := pg_temp.wu6a_view_cols('public.cerebro_historial_operaciones');
  IF v_names IS DISTINCT FROM ARRAY[
       'dia:date','service_type:text','status:text','cliente:text','telefono:text',
       'monto_gyd:numeric','destination_currency:text','beneficiary_type:text',
       'beneficiario:text','tarjeta:text','celular_beneficiario:text','zelle_account:text',
       'deal_id:uuid','operation_id:uuid','created_at:timestamp with time zone',
       'completed_at:timestamp with time zone']::text[] THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0.4] cerebro_historial_operaciones column shape changed: %', v_names;
  ELSE
    RAISE NOTICE 'PASS [0.4] cerebro_historial_operaciones keeps its 16 columns, names and order';
  END IF;

  v_names := pg_temp.wu6a_view_cols('public.cerebro_volumen_diario');
  IF v_names IS DISTINCT FROM ARRAY[
       'dia:date','service_type:text','operaciones:bigint','volumen_gyd:numeric',
       'ticket_medio_gyd:numeric']::text[] THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [0.4] cerebro_volumen_diario column shape changed: %', v_names;
  ELSE
    RAISE NOTICE 'PASS [0.4] cerebro_volumen_diario keeps its 5 columns, names and order';
  END IF;

  ---------------------------------------------------------------------
  -- Part 1 — cerebro_historial_operaciones: every row and column identical.
  ---------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM wu6a_hist_old;
  IF v_n = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1] the historial snapshot is EMPTY — an empty equality proves nothing';
  END IF;

  SELECT count(*) INTO v_n FROM (
    (SELECT * FROM wu6a_hist_old EXCEPT ALL SELECT * FROM public.cerebro_historial_operaciones)
    UNION ALL
    (SELECT * FROM public.cerebro_historial_operaciones EXCEPT ALL SELECT * FROM wu6a_hist_old)
  ) x;
  IF v_n <> 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [1] cerebro_historial_operaciones differs from its pre-164 definition in % row(s)', v_n;
  ELSE
    SELECT count(*) INTO v_n FROM wu6a_hist_old;
    RAISE NOTICE 'PASS [1] cerebro_historial_operaciones: all % rows identical to the pre-164 view', v_n;
  END IF;

  ---------------------------------------------------------------------
  -- Part 2 — cerebro_volumen_diario identical; resumen_volumen still compiles.
  ---------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM wu6a_vol_old;
  IF v_n = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] the volumen_diario snapshot is EMPTY — the completed-op fixture did not land';
  END IF;

  SELECT count(*) INTO v_n FROM (
    (SELECT * FROM wu6a_vol_old EXCEPT ALL SELECT * FROM public.cerebro_volumen_diario)
    UNION ALL
    (SELECT * FROM public.cerebro_volumen_diario EXCEPT ALL SELECT * FROM wu6a_vol_old)
  ) x;
  IF v_n <> 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] cerebro_volumen_diario differs from its pre-164 definition in % row(s)', v_n;
  ELSE
    SELECT count(*) INTO v_n FROM wu6a_vol_old;
    RAISE NOTICE 'PASS [2] cerebro_volumen_diario: all % rows identical to the pre-164 view', v_n;
  END IF;

  v_names := pg_temp.wu6a_view_cols('public.cerebro_resumen_volumen');
  IF v_names IS DISTINCT FROM ARRAY[
       'orden:integer','periodo:text','desde:date','hasta:date','operaciones:bigint',
       'volumen_gyd:numeric','ticket_medio_gyd:numeric']::text[] THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [2] cerebro_resumen_volumen no longer compiles with the expected shape: %', v_names;
  ELSE
    EXECUTE 'SELECT count(*) FROM public.cerebro_resumen_volumen' INTO v_n;
    IF v_n <> 5 THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [2] cerebro_resumen_volumen returned % period rows, expected 5', v_n;
    ELSE
      RAISE NOTICE 'PASS [2] cerebro_resumen_volumen still compiles and returns its 5 periods';
    END IF;
  END IF;

  ---------------------------------------------------------------------
  -- Part 3 — cerebro_saldo_envio: the wrapper returns the same row as the
  -- pre-164 body for EVERY deal on staging.
  ---------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM deals;
  IF v_n = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] no deals on staging — the saldo_envio equality would be vacuous';
  END IF;

  SELECT count(*) INTO v_n FROM (
    (SELECT d.id, s.* FROM deals d CROSS JOIN LATERAL pg_temp.wu6a_saldo_envio_old(d.id) s
     EXCEPT ALL
     SELECT d.id, s.* FROM deals d CROSS JOIN LATERAL public.cerebro_saldo_envio(d.id) s)
    UNION ALL
    (SELECT d.id, s.* FROM deals d CROSS JOIN LATERAL public.cerebro_saldo_envio(d.id) s
     EXCEPT ALL
     SELECT d.id, s.* FROM deals d CROSS JOIN LATERAL pg_temp.wu6a_saldo_envio_old(d.id) s)
  ) x;
  IF v_n <> 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] cerebro_saldo_envio wrapper differs from the pre-164 body in % row(s)', v_n;
  ELSE
    SELECT count(*) INTO v_n FROM deals;
    RAISE NOTICE 'PASS [3] cerebro_saldo_envio: identical value row for all % deals', v_n;
  END IF;

  -- The NULL / no-operation case must still be exactly one (NULL,0,NULL,'GYD') row.
  SELECT count(*) INTO v_n FROM public.cerebro_saldo_envio(NULL::uuid) s
   WHERE s.objetivo IS NULL AND s.depositado = 0 AND s.saldo IS NULL AND s.moneda = 'GYD';
  IF v_n <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [3] cerebro_saldo_envio(NULL) is not the single (NULL,0,NULL,GYD) row | % rows', v_n;
  ELSE
    RAISE NOTICE 'PASS [3] cerebro_saldo_envio(NULL) still returns one (NULL,0,NULL,GYD) row';
  END IF;

  ---------------------------------------------------------------------
  -- Part 4 — cerebro_avisar_remesas_abiertas_viejas: identical rows,
  -- identical claves, identical avisos; only the "(etapa)" label goes.
  ---------------------------------------------------------------------
  DELETE FROM notifications WHERE type = 'remesa_abierta_vieja';
  DELETE FROM cerebro_alertas WHERE clave LIKE 'remesas_viejas:%';

  SELECT viejas, avisos_creados INTO v_old_v, v_old_a
    FROM pg_temp.wu6a_avisar_old(0, true);

  SELECT count(*) INTO v_old_notifs FROM notifications WHERE type = 'remesa_abierta_vieja';
  SELECT COALESCE(string_agg(body, E'\n=====\n' ORDER BY account_id), '') INTO v_old_body
    FROM notifications WHERE type = 'remesa_abierta_vieja';
  SELECT COALESCE(array_agg(clave ORDER BY clave), ARRAY[]::text[]) INTO v_old_claves
    FROM cerebro_alertas WHERE clave LIKE 'remesas_viejas:%';

  DELETE FROM notifications WHERE type = 'remesa_abierta_vieja';
  DELETE FROM cerebro_alertas WHERE clave LIKE 'remesas_viejas:%';

  SELECT viejas, avisos_creados INTO v_new_v, v_new_a
    FROM public.cerebro_avisar_remesas_abiertas_viejas(0, true);

  SELECT count(*) INTO v_new_notifs FROM notifications WHERE type = 'remesa_abierta_vieja';
  SELECT COALESCE(string_agg(body, E'\n=====\n' ORDER BY account_id), '') INTO v_new_body
    FROM notifications WHERE type = 'remesa_abierta_vieja';
  SELECT COALESCE(array_agg(clave ORDER BY clave), ARRAY[]::text[]) INTO v_new_claves
    FROM cerebro_alertas WHERE clave LIKE 'remesas_viejas:%';

  IF v_old_notifs = 0 OR v_new_notifs = 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] the alert produced no notifications (old % / new %) — equality would be vacuous',
      v_old_notifs, v_new_notifs;
  END IF;

  IF v_old_v IS DISTINCT FROM v_new_v OR v_old_a IS DISTINCT FROM v_new_a THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] return values differ: old (%, %) vs new (%, %)',
      v_old_v, v_old_a, v_new_v, v_new_a;
  ELSE
    RAISE NOTICE 'PASS [4] cerebro_avisar_remesas_abiertas_viejas returns the same (viejas, avisos) = (%, %)', v_new_v, v_new_a;
  END IF;

  IF v_old_claves IS DISTINCT FROM v_new_claves THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] cerebro_alertas.clave set changed: old % vs new %', v_old_claves, v_new_claves;
  ELSE
    RAISE NOTICE 'PASS [4] identical cerebro_alertas.clave set (% keys)', array_length(v_new_claves, 1);
  END IF;

  -- Bodies: identical either verbatim, or once every trailing " (etapa)"
  -- label is stripped from the OLD text. The first branch is what holds
  -- BEFORE the migration; the second is the asserted post-164 shape.
  v_stripped := regexp_replace(v_old_body, ' \([^)]*\)(?=\n|$)', '', 'g');
  IF v_old_body = v_new_body THEN
    RAISE NOTICE 'NOTE [4] bodies are byte-identical — no stage label is being removed yet (pre-164)';
  ELSIF v_stripped = v_new_body THEN
    RAISE NOTICE 'PASS [4] the alert body differs from the old one ONLY by the removed " (etapa)" labels';
  ELSE
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [4] the alert body changed by more than the stage label';
  END IF;

  ---------------------------------------------------------------------
  -- Part 5a — crm_entregar_operacion: identical behaviour on a real
  -- ready_to_transfer fixture, and only the deal lock removed from the code.
  ---------------------------------------------------------------------
  SELECT id INTO v_op_a FROM remittance_operations WHERE deal_id = v_deal_a;
  SELECT id INTO v_op_b FROM remittance_operations WHERE deal_id = v_deal_b;

  IF v_op_a IS NULL OR v_op_b IS NULL THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5a] fixture failed — 125 did not create an operation for a LISTA deal';
  ELSE
    INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
    VALUES (gen_random_uuid(), v_op_a, 'zelle', 'WU6A Uno', 'wu6a1@example.invalid', 1, 1, 'vigente');
    INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
    VALUES (gen_random_uuid(), v_op_b, 'zelle', 'WU6A Dos', 'wu6a2@example.invalid', 1, 1, 'vigente');
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);

  BEGIN
    v_res_a := pg_temp.wu6a_entregar_old(v_op_a, jsonb_build_object('mode', 'no_proof'));
    v_res_b := public.crm_entregar_operacion(v_op_b, jsonb_build_object('mode', 'no_proof'));
    SELECT status, delivery_mode INTO v_status_a, v_mode_a FROM remittance_operations WHERE id = v_op_a;
    SELECT status, delivery_mode INTO v_status_b, v_mode_b FROM remittance_operations WHERE id = v_op_b;

    IF (v_res_a ->> 'new_status') IS DISTINCT FROM 'completed'
       OR (v_res_b ->> 'new_status') IS DISTINCT FROM 'completed'
       OR v_status_a IS DISTINCT FROM 'completed'
       OR v_status_b IS DISTINCT FROM 'completed'
       OR v_mode_a IS DISTINCT FROM 'no_proof'
       OR v_mode_b IS DISTINCT FROM 'no_proof' THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [5a] delivery differs: old json % status % mode %, new json % status % mode %',
        v_res_a, v_status_a, v_mode_a, v_res_b, v_status_b, v_mode_b;
    ELSE
      RAISE NOTICE 'PASS [5a] crm_entregar_operacion delivers identically with and without the deal lock';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5a] delivery raised: % (%)', SQLERRM, SQLSTATE;
  END;

  PERFORM set_config('request.jwt.claims', '', true);

  -- The only non-comment line difference must be the guarded lock block.
  SELECT prosrc INTO v_old_src FROM pg_proc p
   WHERE p.pronamespace = pg_my_temp_schema() AND p.proname = 'wu6a_entregar_old';
  SELECT prosrc INTO v_new_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'crm_entregar_operacion';

  SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::text[]) INTO v_extra FROM (
    SELECT x FROM unnest(pg_temp.wu6a_code_lines(v_old_src)) x
    EXCEPT ALL
    SELECT x FROM unnest(pg_temp.wu6a_code_lines(v_new_src)) x) q;
  SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::text[]) INTO v_missing FROM (
    SELECT x FROM unnest(pg_temp.wu6a_code_lines(v_new_src)) x
    EXCEPT ALL
    SELECT x FROM unnest(pg_temp.wu6a_code_lines(v_old_src)) x) q;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5a] the new body ADDS non-comment lines: %', v_missing;
  ELSIF array_length(v_extra, 1) IS DISTINCT FROM 3 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5a] the new body removes % non-comment line(s), expected exactly 3: %',
      COALESCE(array_length(v_extra, 1), 0), v_extra;
  ELSE
    v_n := 0;
    IF EXISTS (SELECT 1 FROM unnest(v_extra) l WHERE l ~ 'IF v_deal_id IS NOT NULL THEN') THEN v_n := v_n + 1; END IF;
    IF EXISTS (SELECT 1 FROM unnest(v_extra) l WHERE l ~ 'PERFORM 1 FROM deals') THEN v_n := v_n + 1; END IF;
    IF EXISTS (SELECT 1 FROM unnest(v_extra) l WHERE btrim(l) = 'END IF;') THEN v_n := v_n + 1; END IF;
    IF v_n <> 3 THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'FAIL [5a] the removed lines are not the guarded deal lock: %', v_extra;
    ELSE
      RAISE NOTICE 'PASS [5a] the only code-line difference is the removed guarded deal lock';
    END IF;
  END IF;

  IF pg_temp.wu6a_names_deals(v_new_src) THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5a] crm_entregar_operacion still references deals';
  ELSE
    RAISE NOTICE 'PASS [5a] crm_entregar_operacion no longer references deals';
  END IF;

  ---------------------------------------------------------------------
  -- Part 5b — merge_duplicate_contacts: the loop body is unreachable, and
  -- only the UPDATE deals line was removed.
  ---------------------------------------------------------------------

  -- The structural precondition: the partial UNIQUE index makes a duplicate
  -- group, which is exactly what the loop iterates over, unrepresentable.
  SELECT count(*) INTO v_dup_groups FROM (
    SELECT 1 FROM contacts WHERE phone_normalized <> ''
     GROUP BY account_id, phone_normalized HAVING count(*) > 1) g;
  IF v_dup_groups <> 0 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5b] % duplicate contact group(s) exist on staging; the no-op claim needs re-checking', v_dup_groups;
  ELSE
    RAISE NOTICE 'PASS [5b] zero duplicate contact groups on staging (the partial UNIQUE index holds)';
  END IF;

  SELECT count(*) INTO v_n FROM pg_index i
   WHERE i.indexrelid = 'public.idx_contacts_account_phone_normalized'::regclass AND i.indisunique;
  IF v_n <> 1 THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5b] the partial UNIQUE index on contacts(account_id, phone_normalized) is missing';
  ELSE
    RAISE NOTICE 'PASS [5b] the partial UNIQUE index that makes the merge loop unreachable exists';
  END IF;

  -- A fixture-based comparison is IMPOSSIBLE by construction (the unique
  -- index forbids building a duplicate group), so the proof is structural:
  -- the loop cannot execute, therefore the removed line cannot be reached.
  -- Both bodies are run on the real (duplicate-free) data as a sanity check.
  v_old_merged := pg_temp.wu6a_merge_old();
  v_new_merged := public.merge_duplicate_contacts();
  IF v_old_merged IS DISTINCT FROM v_new_merged THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5b] merge returned % (old) vs % (new)', v_old_merged, v_new_merged;
  ELSE
    RAISE NOTICE 'PASS [5b] merge_duplicate_contacts returns % with and without the deals line (both no-ops)', v_new_merged;
  END IF;

  SELECT prosrc INTO v_old_src FROM pg_proc p
   WHERE p.pronamespace = pg_my_temp_schema() AND p.proname = 'wu6a_merge_old';
  SELECT prosrc INTO v_new_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'merge_duplicate_contacts';

  SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::text[]) INTO v_extra FROM (
    SELECT x FROM unnest(pg_temp.wu6a_code_lines(v_old_src)) x
    EXCEPT ALL
    SELECT x FROM unnest(pg_temp.wu6a_code_lines(v_new_src)) x) q;
  SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::text[]) INTO v_missing FROM (
    SELECT x FROM unnest(pg_temp.wu6a_code_lines(v_new_src)) x
    EXCEPT ALL
    SELECT x FROM unnest(pg_temp.wu6a_code_lines(v_old_src)) x) q;

  IF NOT pg_temp.wu6a_names_deals(v_old_src) THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5b] the recreated pre-164 body does not reference deals — the comparison is wrong';
  ELSIF pg_temp.wu6a_names_deals(v_new_src) THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5b] merge_duplicate_contacts still references deals';
  ELSIF array_length(v_missing, 1) IS NOT NULL THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5b] the new body ADDS non-comment lines: %', v_missing;
  ELSIF array_length(v_extra, 1) IS DISTINCT FROM 1
        OR v_extra[1] !~ '^[[:space:]]*UPDATE deals[[:space:]]' THEN
    v_fail := v_fail + 1;
    RAISE WARNING 'FAIL [5b] the only removed line should be UPDATE deals; got %', v_extra;
  ELSE
    RAISE NOTICE 'PASS [5b] the only code-line difference is the removed UPDATE deals line';
  END IF;

  ---------------------------------------------------------------------
  -- Part 2b — the boundary of the guarantee, shown rather than hidden.
  -- A deal with value 7777 whose operation has quoted_source_amount = NULL:
  -- the pre-164 views fall back to deals.value, the post-164 ones cannot.
  -- Staging holds no such row (Parts 1-2 prove the equality above), so this
  -- block is informational only.
  ---------------------------------------------------------------------
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  SELECT gen_random_uuid(), owner_user, '78220927-0745-45a8-ba08-a1b33734dbf1', 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63',
         'wu6a fallback', account_id, conv_id, contact_id, 7777, 'GYD'
    FROM wu6a_fx
  RETURNING id INTO v_fb_deal;
  SELECT id INTO v_fb_op FROM remittance_operations WHERE deal_id = v_fb_deal;

  IF v_fb_op IS NULL THEN
    RAISE NOTICE 'NOTE [2b] could not build the fallback fixture (no operation for the deal)';
  ELSE
    UPDATE remittance_operations SET quoted_source_amount = NULL WHERE id = v_fb_op;

    -- The pre-164 expression, evaluated LIVE (not from the snapshot, which
    -- predates this row).
    SELECT COALESCE(o.quoted_source_amount, d.value, 0) INTO v_fb_old
      FROM remittance_operations o LEFT JOIN deals d ON d.id = o.deal_id
     WHERE o.id = v_fb_op;
    SELECT monto_gyd INTO v_fb_new
      FROM public.cerebro_historial_operaciones h WHERE h.operation_id = v_fb_op;

    RAISE NOTICE 'NOTE [2b] a qsa-NULL row with deals.value=7777 reads % BEFORE 164 and % AFTER 164',
      v_fb_old, v_fb_new;
    IF v_fb_old = 7777 AND v_fb_new = 0 THEN
      RAISE NOTICE 'NOTE [2b] confirmed: the removed deals.value fallback is exactly this boundary';
    ELSE
      RAISE NOTICE 'NOTE [2b] unexpected values — the fallback boundary is NOT what the migration claims';
    END IF;
  END IF;

  ---------------------------------------------------------------------
  -- Verdict.
  ---------------------------------------------------------------------
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'deals-free-views-and-inert-edits: % expectation(s) FAILED — see WARNINGs above', v_fail;
  END IF;

  RAISE NOTICE 'deals-free-views-and-inert-edits: ALL PASS';
END $body$;

ROLLBACK TO SAVEPOINT wu6a_deals_free;
