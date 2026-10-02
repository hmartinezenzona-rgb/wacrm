\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- =====================================================================
-- deal-free-beneficiary-writers.sql — side-by-side parity harness for 162
--
-- MUST run inside an already-open transaction that ends in ROLLBACK (the
-- runner opens BEGIN; … this file; ROLLBACK;). Never COMMIT. Staging only,
-- never production.
--
-- RED before the migration: the four new functions do not exist and the
-- first case fails with 42883 `function public.cerebro_registrar_
-- beneficiario_auto(uuid, text, text, text) does not exist`.
--
-- WHAT IT PROVES
--   For each of the four nodes and each branch, the OLD node SQL (copied
--   verbatim from agent-shared/reports/wu4-n8n-writers.md, run with the
--   node's own argument binding order) against a DEAL-BASED operation, and
--   the NEW function against an EQUIVALENT DEAL-FREE operation, must
--   produce:
--     (1) the same returned rows — same accion strings, byte for byte, in
--         the same multiset, and the same id-NULL pattern;
--     (2) the same number of remittance_operations for the conversation
--         (a path that writes an orphan, or forgets to create the
--         operation, fails here);
--     (3) the same remittance_beneficiaries rows, column by column
--         (block_index, position, beneficiary_type, name, card_number,
--         phone, zelle_account, amount, currency, status, source,
--         amount_origin, delivery_method, and whether replaced_at is set).
--   For every id the new function returns, it must be an operation of the
--   conversation it was given — the explicit orphan check the brief asks for.
--
-- BRANCHES COVERED (per node)
--   card auto  (n1): nueva operacion / op sin beneficiario / op con otro
--                    beneficiario / mismos datos / ambigua            = 5
--   card tool  (n3): the same five + ins with an empty name           = 6
--   zelle auto (n2): falta nombre / falta cuenta / the same five,
--                    plus the normalization case (registered as
--                    "+1 (469) 512-1137", re-run as "4695121137")    = 8
--   zelle tool (n4): the same eight                                  = 8
--
-- KNOWN, MEASURED DIVERGENCE (asserted as such, not hidden)
--   "op exists, has no beneficiary yet, and its old notes carried other
--    blocks first": the old path's beneficiary lands at block_index =
--    number of blocks in deals.notes (2 when the notes had a preamble),
--    the new path has no notes to count and lands at max(block_index)+1 = 1.
--    The harness runs that case with p_allow_block_diff and requires that
--    block_index is the ONLY difference. block_index is a generation
--    counter used by rb_unico_por_bloque and by the notes parser's
--    max(block_index) vigente/reemplazado rule; no reader groups by it
--    (grep of supabase/migrations: 042, 098, 123, 129, 130, 150, 151 —
--    all writers, none a reader), so the divergence is recorded, not
--    claimed to be harmless.
--
-- MEASURED, NOT ASSERTED (reported, not hidden)
--   The old path's trg_sync_z_benef_desde_deal (042/151) also does
--   `UPDATE remittance_operations SET delivery_method = …` on the
--   operation. It is deal-keyed and disappears with deals; 162 does not
--   reproduce it (161 documented the same gap). Every case prints
--   `GAP (measured)` when the two operations' delivery_method differ.
--   That is a real behavioural difference for WU5 to close or accept.
--
-- Assertion convention (same as operation-creator-without-deals.sql): a
-- SAVEPOINT at the top and ROLLBACK TO SAVEPOINT at the end; the helper
-- functions live in pg_temp and vanish with the session.
-- =====================================================================

SAVEPOINT wu4b_parity;


-- ---------------------------------------------------------------------
-- Canonical projection of a whole CONVERSATION's beneficiary rows.
--
-- Scoped to the conversation, not to one operation, on purpose: the
-- falta_* branches create no operation at all on either side, and a
-- per-operation comparison would silently skip them. The caller also
-- asserts the operation counts are equal, so the two projections are
-- taken over the same number of operations.
--
-- Ordered by the row's own content (x::text), not by operation_id or by
-- (block_index, position): operation ids differ between the two sides by
-- construction, and two operations can tie on (block_index, position).
-- A content-ordered multiset cannot produce a false mismatch on ties.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.wu4b_ben(p_conv uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $f$
  SELECT coalesce(jsonb_agg(x ORDER BY x::text), '[]'::jsonb)
    FROM (
      SELECT jsonb_build_object(
               'block',      b.block_index,
               'pos',        b.position,
               'tipo',       b.beneficiary_type,
               'name',       b.name,
               'card',       b.card_number,
               'phone',      b.phone,
               'zelle',      b.zelle_account,
               'amount',     b.amount,
               'currency',   b.currency,
               'status',     b.status,
               'source',     b.source,
               'origin',     b.amount_origin,
               'delivery',   b.delivery_method,
               'reemplazado', b.replaced_at IS NOT NULL
             ) AS x
        FROM remittance_beneficiaries b
        JOIN remittance_operations o ON o.id = b.operation_id
       WHERE o.conversation_id = p_conv
    ) s;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.wu4b_ben_noblock(p_conv uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $f$
  SELECT coalesce(jsonb_agg(x ORDER BY x::text), '[]'::jsonb)
    FROM (
      SELECT jsonb_build_object(
               'pos',        b.position,
               'tipo',       b.beneficiary_type,
               'name',       b.name,
               'card',       b.card_number,
               'phone',      b.phone,
               'zelle',      b.zelle_account,
               'amount',     b.amount,
               'currency',   b.currency,
               'status',     b.status,
               'source',     b.source,
               'origin',     b.amount_origin,
               'delivery',   b.delivery_method,
               'reemplazado', b.replaced_at IS NOT NULL
             ) AS x
        FROM remittance_beneficiaries b
        JOIN remittance_operations o ON o.id = b.operation_id
       WHERE o.conversation_id = p_conv
    ) s;
$f$;

-- The distinct block_index values actually present, per conversation.
CREATE OR REPLACE FUNCTION pg_temp.wu4b_blocks(p_conv uuid) RETURNS integer[]
LANGUAGE sql STABLE AS $f$
  SELECT coalesce(array_agg(DISTINCT b.block_index ORDER BY b.block_index), '{}')
    FROM remittance_beneficiaries b
    JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.conversation_id = p_conv;
$f$;

-- The distinct remittance_operations.delivery_method values, per
-- conversation. Used only for the measured GAP notice below.
CREATE OR REPLACE FUNCTION pg_temp.wu4b_dm(p_conv uuid) RETURNS text[]
LANGUAGE sql STABLE AS $f$
  SELECT coalesce(array_agg(DISTINCT coalesce(o.delivery_method, '<NULL>') ORDER BY coalesce(o.delivery_method, '<NULL>')), '{}')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$f$;


-- ---------------------------------------------------------------------
-- One parity case: fixtures -> OLD run -> NEW run -> diff
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.wu4b_case(
  p_node        text,      -- card_auto | card_tool | zelle_auto | zelle_tool
  p_caso        text,
  p_old_setup   text,      -- SQL, $1=conv $2=account $3=owner ('' = nothing)
  p_new_setup   text,
  p_old_sql     text,      -- the node SQL verbatim, $1..$5
  p_account     uuid,
  p_owner       uuid,
  p_seed        bigint,
  p_a2          text,
  p_a3          text,
  p_a4          text,
  p_a5          text,
  p_allow_block_diff boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql
AS $f$
DECLARE
  v_c1       uuid;
  v_c2       uuid;
  v_conv_old uuid;
  v_conv_new uuid;
  v_acc_old  text[]    := '{}';
  v_acc_new  text[]    := '{}';
  v_null_old boolean[] := '{}';
  v_null_new boolean[] := '{}';
  v_opc_old  bigint;
  v_opc_new  bigint;
  v_bo       jsonb;
  v_bn       jsonb;
  v_sql      text;
  v_exec     text;
  r          record;
BEGIN
  -- ---------------------------------------------------------- fixtures
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), p_owner, '1555' || lpad((p_seed * 10 + 1)::text, 7, '0'),
          'WU4B ' || p_caso || ' old', p_account)
  RETURNING id INTO v_c1;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), p_owner, v_c1, p_account)
  RETURNING id INTO v_conv_old;

  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), p_owner, '1555' || lpad((p_seed * 10 + 2)::text, 7, '0'),
          'WU4B ' || p_caso || ' new', p_account)
  RETURNING id INTO v_c2;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), p_owner, v_c2, p_account)
  RETURNING id INTO v_conv_new;

  IF p_old_setup <> '' THEN EXECUTE p_old_setup USING v_conv_old, p_account, p_owner; END IF;
  IF p_new_setup <> '' THEN EXECUTE p_new_setup USING v_conv_new, p_account, p_owner; END IF;

  -- ------------------------------------------------------------ OLD run
  -- The node's own SQL, verbatim, with its own binding order. $5 is bound
  -- even for the 4-argument nodes; unused parameters are allowed.
  FOR r IN EXECUTE p_old_sql USING v_conv_old, p_a2, p_a3, p_a4, p_a5 LOOP
    v_acc_old  := v_acc_old  || r.accion;
    v_null_old := v_null_old || (r.id IS NULL);
  END LOOP;

  -- ------------------------------------------------------------ NEW run
  IF p_node = 'card_auto' THEN
    v_exec := p_a4 || '-new';
    v_sql  := 'SELECT * FROM cerebro_registrar_beneficiario_auto($1, $2, $3, $4)';
    FOR r IN EXECUTE v_sql USING v_conv_new, p_a2, p_a3, v_exec LOOP
      v_acc_new  := v_acc_new  || r.accion;
      v_null_new := v_null_new || (r.id IS NULL);
      IF r.id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM remittance_operations o
                        WHERE o.id = r.id AND o.conversation_id = v_conv_new) THEN
          RAISE EXCEPTION 'FAIL [% %] NEW returned id % that is not an operation of its conversation (silent orphan)',
            p_node, p_caso, r.id;
        END IF;
      END IF;
    END LOOP;
  ELSIF p_node = 'card_tool' THEN
    v_exec := p_a5 || '-new';
    v_sql  := 'SELECT * FROM cerebro_gestionar_beneficiario($1, $2, $3, $4, $5)';
    FOR r IN EXECUTE v_sql USING v_conv_new, p_a2, p_a3, p_a4, v_exec LOOP
      v_acc_new  := v_acc_new  || r.accion;
      v_null_new := v_null_new || (r.id IS NULL);
      IF r.id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM remittance_operations o
                        WHERE o.id = r.id AND o.conversation_id = v_conv_new) THEN
          RAISE EXCEPTION 'FAIL [% %] NEW returned id % that is not an operation of its conversation (silent orphan)',
            p_node, p_caso, r.id;
        END IF;
      END IF;
    END LOOP;
  ELSIF p_node = 'zelle_auto' THEN
    v_exec := p_a4 || '-new';
    v_sql  := 'SELECT * FROM cerebro_registrar_zelle_auto($1, $2, $3, $4)';
    FOR r IN EXECUTE v_sql USING v_conv_new, p_a2, p_a3, v_exec LOOP
      v_acc_new  := v_acc_new  || r.accion;
      v_null_new := v_null_new || (r.id IS NULL);
      IF r.id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM remittance_operations o
                        WHERE o.id = r.id AND o.conversation_id = v_conv_new) THEN
          RAISE EXCEPTION 'FAIL [% %] NEW returned id % that is not an operation of its conversation (silent orphan)',
            p_node, p_caso, r.id;
        END IF;
      END IF;
    END LOOP;
  ELSIF p_node = 'zelle_tool' THEN
    v_exec := p_a4 || '-new';
    v_sql  := 'SELECT * FROM cerebro_registrar_beneficiario_zelle($1, $2, $3, $4)';
    FOR r IN EXECUTE v_sql USING v_conv_new, p_a2, p_a3, v_exec LOOP
      v_acc_new  := v_acc_new  || r.accion;
      v_null_new := v_null_new || (r.id IS NULL);
      IF r.id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM remittance_operations o
                        WHERE o.id = r.id AND o.conversation_id = v_conv_new) THEN
          RAISE EXCEPTION 'FAIL [% %] NEW returned id % that is not an operation of its conversation (silent orphan)',
            p_node, p_caso, r.id;
        END IF;
      END IF;
    END LOOP;
  ELSE
    RAISE EXCEPTION 'unknown node %', p_node;
  END IF;

  -- --------------------------------------------------- (1) returned rows
  IF (SELECT jsonb_agg(x ORDER BY x) FROM unnest(v_acc_old) x)
     IS DISTINCT FROM
     (SELECT jsonb_agg(x ORDER BY x) FROM unnest(v_acc_new) x) THEN
    RAISE EXCEPTION 'FAIL [% %] accion differs: old=% new=%',
      p_node, p_caso, v_acc_old, v_acc_new;
  END IF;
  IF (SELECT jsonb_agg(y ORDER BY y) FROM unnest(v_null_old) y)
     IS DISTINCT FROM
     (SELECT jsonb_agg(y ORDER BY y) FROM unnest(v_null_new) y) THEN
    RAISE EXCEPTION 'FAIL [% %] returned-id NULL pattern differs: old=% new=%',
      p_node, p_caso, v_null_old, v_null_new;
  END IF;

  -- ------------------------------------------- (2) operation row counts
  SELECT count(*) INTO v_opc_old FROM remittance_operations WHERE conversation_id = v_conv_old;
  SELECT count(*) INTO v_opc_new FROM remittance_operations WHERE conversation_id = v_conv_new;
  IF v_opc_old <> v_opc_new THEN
    RAISE EXCEPTION 'FAIL [% %] operation count differs: old=% new=% (one path created an operation the other did not)',
      p_node, p_caso, v_opc_old, v_opc_new;
  END IF;

  -- --------------------------------------- (3) beneficiary row diff
  -- Conversation-scoped, so it also runs (and must find nothing on both
  -- sides) for the falta_* branches, which create no operation at all.
  v_bo := pg_temp.wu4b_ben(v_conv_old);
  v_bn := pg_temp.wu4b_ben(v_conv_new);
  IF v_bo IS DISTINCT FROM v_bn THEN
    IF p_allow_block_diff
       AND pg_temp.wu4b_ben_noblock(v_conv_old) = pg_temp.wu4b_ben_noblock(v_conv_new) THEN
      RAISE NOTICE 'DIVERGENCE (accepted) [% %] block_index only: old=% new=%',
        p_node, p_caso, pg_temp.wu4b_blocks(v_conv_old), pg_temp.wu4b_blocks(v_conv_new);
    ELSE
      RAISE EXCEPTION E'FAIL [% %] beneficiary rows differ:\n  old=%\n  new=%',
        p_node, p_caso, v_bo, v_bn;
    END IF;
  END IF;

  -- A branch that creates no operation must also create no beneficiary.
  IF v_opc_new = 0 AND v_bn <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [% %] no operation was created but beneficiaries exist: %',
      p_node, p_caso, v_bn;
  END IF;

  -- Measured, deliberately not asserted: the 042 trigger's operation-level
  -- cascade sets remittance_operations.delivery_method from the operation's
  -- first vigente beneficiary_type (or an "ENTREGA EN USD" mark in
  -- deals.notes). 162 does not reproduce it — see the file header.
  IF pg_temp.wu4b_dm(v_conv_old) IS DISTINCT FROM pg_temp.wu4b_dm(v_conv_new) THEN
    RAISE NOTICE 'GAP (measured) [% %] operation.delivery_method old=% new=%',
      p_node, p_caso, pg_temp.wu4b_dm(v_conv_old), pg_temp.wu4b_dm(v_conv_new);
  END IF;

  RAISE NOTICE 'PASS [% / %] accion=% rows=%',
    p_node, p_caso, coalesce(v_acc_new[1], '(none)'), coalesce(array_length(v_acc_new, 1), 0);
END;
$f$;


-- =====================================================================
-- The cases
-- =====================================================================

DO $do$
DECLARE
  c_pipe    CONSTANT text := '78220927-0745-45a8-ba08-a1b33734dbf1';
  c_stage   CONSTANT text := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';
  v_hash    CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_owner   uuid := gen_random_uuid();
  v_account uuid;
  v_seed    bigint := 0;

  -- The deal INSERT the old path uses, as a template: the %L is the notes.
  v_deal_tpl text;
  v_op_setup text;

  -- node SQL, verbatim from the report
  n1 text;
  n2 text;
  n3 text;
  n4 text;
BEGIN
  -- ---------------------------------------------------------- fixtures
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'wu4b-' || v_owner || '@test.invalid', v_hash, now(), now(), now(),
          '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id)
  VALUES (gen_random_uuid(), 'WU4b parity harness', v_owner)
  RETURNING id INTO v_account;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner, 'wu4b owner',
          'wu4b-' || v_owner || '@test.invalid', v_account, 'owner');

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  v_deal_tpl := $s$
INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                   stage_id, title, value, currency, notes, status)
SELECT $3::uuid, $2::uuid, c.contact_id, c.id, '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid,
       '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109'::uuid, 'Remesa WU4B', 0, 'GYD', %L, 'open'
  FROM conversations c WHERE c.id = $1::uuid
$s$;
  v_op_setup := $s$SELECT cerebro_crear_operacion($1::uuid)$s$;

  n1 := $q$
WITH res AS (SELECT * FROM cerebro_resolver_operacion_beneficiario($1::uuid, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'], $2::text)),
idem AS (SELECT $4 || ':Registrar beneficiario auto:' || md5(coalesce($2,'')||'|'||coalesce($3,'')) AS k),
reg AS (
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT (SELECT k FROM idem), 'Registrar beneficiario auto', $4, $1::uuid,
         (SELECT operation_id FROM res), jsonb_build_array(to_jsonb($2::text),to_jsonb($3::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id
),
conv AS (SELECT v.id AS cid, v.contact_id, v.account_id, v.user_id, c.phone FROM conversations v JOIN contacts c ON c.id=v.contact_id WHERE v.id=$1::uuid), abierto AS (SELECT d.id, (COALESCE(d.notes,'') LIKE '%BENEFICIARIO%') AS tiene_benef, (COALESCE(d.notes,'') LIKE '%Tarjeta: ' || $2 || E'\nCelular: ' || $3 || '%') AS mismos_datos FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
   WHERE o.id = (SELECT operation_id FROM res)), upd AS (UPDATE deals SET notes = COALESCE(notes,'') || (CASE WHEN (SELECT tiene_benef FROM abierto) THEN E'\n---\nBENEFICIARIO ACTUALIZADO (auto) - reemplaza al anterior' ELSE E'\n---\nBENEFICIARIO (auto)' END) || E'\nTarjeta: ' || $2 || E'\nCelular: ' || $3, updated_at = now() WHERE id = (SELECT id FROM abierto WHERE NOT mismos_datos) RETURNING id, (SELECT CASE WHEN tiene_benef THEN 'beneficiario ACTUALIZADO en el envio abierto' ELSE 'beneficiario agregado al envio abierto' END FROM abierto) AS accion), ins AS (INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status) SELECT conv.user_id, conv.account_id, conv.contact_id, conv.cid, '78220927-0745-45a8-ba08-a1b33734dbf1', '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109', 'Remesa +' || conv.phone, 0, 'GYD', 'BENEFICIARIO (auto)' || E'\nTarjeta: ' || $2 || E'\nCelular: ' || $3, 'open' FROM conv WHERE NOT EXISTS (SELECT 1 FROM abierto)
     AND (SELECT resultado FROM res) <> 'ambigua' RETURNING id, 'envio nuevo creado con beneficiario auto' AS accion), sin_cambio AS (SELECT id, 'sin cambios: esos datos ya estaban en el envio abierto' AS accion FROM abierto WHERE mismos_datos), limpiar AS (DELETE FROM cerebro_beneficiario_parcial WHERE conversation_id = $1::uuid RETURNING 1),
ambiguo AS (
  SELECT NULL::uuid AS id,
         'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion
    FROM cerebro_registrar_derivacion(
      $1::uuid,
      'Hay varias operaciones abiertas y el caso requiere revisión humana.',
      'operacion_ambigua',
      (SELECT resultado FROM res) = 'ambigua'
    ) d
)
SELECT * FROM upd UNION ALL SELECT * FROM ins UNION ALL SELECT * FROM sin_cambio UNION ALL SELECT * FROM ambiguo;
$q$;

  n3 := $q$
WITH res AS (SELECT * FROM cerebro_resolver_operacion($1::uuid, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])),
idem AS (SELECT $5 || ':gestionar_beneficiario:' || md5(coalesce($2,'')||'|'||coalesce($3,'')||'|'||coalesce($4,'')) AS k),
reg AS (
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT (SELECT k FROM idem), 'gestionar_beneficiario', $5, $1::uuid,
         (SELECT operation_id FROM res), jsonb_build_array(to_jsonb($2::text),to_jsonb($3::text),to_jsonb($4::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id
),
conv AS (SELECT v.id AS cid, v.contact_id, v.account_id, v.user_id, c.phone FROM conversations v JOIN contacts c ON c.id=v.contact_id WHERE v.id=$1::uuid), abierto AS (SELECT d.id, (COALESCE(d.notes,'') LIKE '%BENEFICIARIO%') AS tiene_benef, (COALESCE(d.notes,'') LIKE '%Tarjeta: ' || $3 || E'\nCelular: ' || $4 || '%') AS mismos_datos FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
   WHERE o.id = (SELECT operation_id FROM res)), upd AS (UPDATE deals SET notes = COALESCE(notes,'') || (CASE WHEN (SELECT tiene_benef FROM abierto) THEN E'\n---\nBENEFICIARIO ACTUALIZADO - reemplaza al anterior' ELSE E'\n---\nBENEFICIARIO' END) || (CASE WHEN NULLIF($2,'') IS NOT NULL THEN ' (' || $2 || ')' ELSE '' END) || E'\nTarjeta: ' || $3 || E'\nCelular: ' || $4, updated_at = now() WHERE id = (SELECT id FROM abierto WHERE NOT mismos_datos) RETURNING id, (SELECT CASE WHEN tiene_benef THEN 'beneficiario ACTUALIZADO en el envio abierto' ELSE 'beneficiario agregado al envio abierto' END FROM abierto) AS accion), ins AS (INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status) SELECT conv.user_id, conv.account_id, conv.contact_id, conv.cid, '78220927-0745-45a8-ba08-a1b33734dbf1', '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109', 'Remesa +' || conv.phone, 0, 'GYD', 'BENEFICIARIO' || (CASE WHEN NULLIF($2,'') IS NOT NULL THEN ' (' || $2 || ')' ELSE '' END) || E'\nTarjeta: ' || $3 || E'\nCelular: ' || $4, 'open' FROM conv WHERE NOT EXISTS (SELECT 1 FROM abierto)
     AND (SELECT resultado FROM res) <> 'ambigua' RETURNING id, 'envio nuevo creado' AS accion), sin_cambio AS (SELECT id, 'sin cambios: esos datos ya estaban en el envio abierto' AS accion FROM abierto WHERE mismos_datos),
ambiguo AS (
  SELECT NULL::uuid AS id,
         'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion
    FROM cerebro_registrar_derivacion(
      $1::uuid,
      'Hay varias operaciones abiertas y el caso requiere revisión humana.',
      'operacion_ambigua',
      (SELECT resultado FROM res) = 'ambigua'
    ) d
)
SELECT * FROM upd UNION ALL SELECT * FROM ins UNION ALL SELECT * FROM sin_cambio UNION ALL SELECT * FROM ambiguo;
$q$;

  n2 := $q$
WITH res AS (SELECT * FROM cerebro_resolver_operacion_beneficiario($1::uuid, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'], $3::text)),
idem AS (SELECT $4 || ':Registrar zelle auto:' || md5(coalesce($2,'')||'|'||coalesce($3,'')) AS k),
reg AS (
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT (SELECT k FROM idem), 'Registrar zelle auto', $4, $1::uuid,
         (SELECT operation_id FROM res), jsonb_build_array(to_jsonb($2::text),to_jsonb($3::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id
),
conv AS (
  SELECT v.id AS cid, v.contact_id, v.account_id, v.user_id, c.phone
    FROM conversations v JOIN contacts c ON c.id=v.contact_id
   WHERE v.id=$1::uuid),
cuenta AS (
  SELECT CASE
    WHEN $3 IS NULL THEN NULL
    WHEN $3 LIKE '%@%' THEN btrim($3)
    WHEN btrim($3) LIKE '+%' AND btrim($3) NOT LIKE '+1%' THEN btrim($3)
    WHEN length(regexp_replace($3, '[^0-9]', '', 'g')) = 11
     AND left(regexp_replace($3, '[^0-9]', '', 'g'), 1) = '1'
      THEN right(regexp_replace($3, '[^0-9]', '', 'g'), 10)
    WHEN length(regexp_replace($3, '[^0-9]', '', 'g')) = 10
     AND left(regexp_replace($3, '[^0-9]', '', 'g'), 1) BETWEEN '2' AND '9'
     AND left(regexp_replace($3, '[^0-9]', '', 'g'), 1) <> '5'
      THEN regexp_replace($3, '[^0-9]', '', 'g')
    ELSE btrim($3)
  END AS c
),
abierto AS (
  SELECT d.id,
         (COALESCE(d.notes,'') LIKE '%BENEFICIARIO%') AS tiene_benef,
         (COALESCE(d.notes,'') LIKE '%Nombre: ' || $2 || E'\nCuenta Zelle: ' || (SELECT c FROM cuenta) || '%') AS mismos_datos
    FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
   WHERE o.id = (SELECT operation_id FROM res)
),
falta AS (
  SELECT NULL::uuid AS id, 'ERROR: hacen falta el nombre Y la cuenta. No se registro nada.' AS accion
   WHERE NULLIF($2,'') IS NULL OR NULLIF($3,'') IS NULL
),
upd AS (
  UPDATE deals SET
    notes = COALESCE(notes,'') ||
            (CASE WHEN (SELECT tiene_benef FROM abierto) THEN E'\n---\nBENEFICIARIO ZELLE ACTUALIZADO - reemplaza al anterior' ELSE E'\n---\nBENEFICIARIO ZELLE' END) ||
            E'\nNombre: ' || $2 || E'\nCuenta Zelle: ' || (SELECT c FROM cuenta),
    updated_at = now()
   WHERE id = (SELECT id FROM abierto WHERE NOT mismos_datos)
     AND NULLIF($2,'') IS NOT NULL AND NULLIF($3,'') IS NOT NULL
  RETURNING id, (SELECT CASE WHEN tiene_benef THEN 'beneficiario Zelle ACTUALIZADO en el envio abierto' ELSE 'beneficiario Zelle agregado en el envio abierto' END FROM abierto) AS accion
),
ins AS (
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  SELECT conv.user_id, conv.account_id, conv.contact_id, conv.cid,
         '78220927-0745-45a8-ba08-a1b33734dbf1','96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109',
         'Remesa +' || conv.phone, 0, 'GYD',
         'BENEFICIARIO ZELLE' || E'\nNombre: ' || $2 || E'\nCuenta Zelle: ' || (SELECT c FROM cuenta), 'open'
    FROM conv
   WHERE NOT EXISTS (SELECT 1 FROM abierto)
     AND (SELECT resultado FROM res) <> 'ambigua'
     AND NULLIF($2,'') IS NOT NULL AND NULLIF($3,'') IS NOT NULL
  RETURNING id, 'envio nuevo creado' AS accion
),
sin_cambio AS (
  SELECT id, 'sin cambios: esos datos ya estaban en el envio abierto' AS accion FROM abierto WHERE mismos_datos
),
ambiguo AS (
  SELECT NULL::uuid AS id,
         'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion
    FROM cerebro_registrar_derivacion(
      $1::uuid,
      'Hay varias operaciones abiertas y el caso requiere revisión humana.',
      'operacion_ambigua',
      (SELECT resultado FROM res) = 'ambigua'
    ) d
)
SELECT * FROM falta UNION ALL SELECT * FROM upd UNION ALL SELECT * FROM ins UNION ALL SELECT * FROM sin_cambio UNION ALL SELECT * FROM ambiguo;
$q$;

  n4 := $q$
WITH res AS (SELECT * FROM cerebro_resolver_operacion($1::uuid, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])),
idem AS (SELECT $4 || ':registrar_beneficiario_zelle:' || md5(coalesce($2,'')||'|'||coalesce($3,'')) AS k),
reg AS (
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT (SELECT k FROM idem), 'registrar_beneficiario_zelle', $4, $1::uuid,
         (SELECT operation_id FROM res), jsonb_build_array(to_jsonb($2::text),to_jsonb($3::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id
),
conv AS (
  SELECT v.id AS cid, v.contact_id, v.account_id, v.user_id, c.phone
    FROM conversations v JOIN contacts c ON c.id=v.contact_id
   WHERE v.id=$1::uuid),
cuenta AS (
  SELECT CASE
    WHEN $3 IS NULL THEN NULL
    WHEN $3 LIKE '%@%' THEN btrim($3)
    WHEN btrim($3) LIKE '+%' AND btrim($3) NOT LIKE '+1%' THEN btrim($3)
    WHEN length(regexp_replace($3, '[^0-9]', '', 'g')) = 11
     AND left(regexp_replace($3, '[^0-9]', '', 'g'), 1) = '1'
      THEN right(regexp_replace($3, '[^0-9]', '', 'g'), 10)
    WHEN length(regexp_replace($3, '[^0-9]', '', 'g')) = 10
     AND left(regexp_replace($3, '[^0-9]', '', 'g'), 1) BETWEEN '2' AND '9'
     AND left(regexp_replace($3, '[^0-9]', '', 'g'), 1) <> '5'
      THEN regexp_replace($3, '[^0-9]', '', 'g')
    ELSE btrim($3)
  END AS c
),
abierto AS (
  SELECT d.id,
         (COALESCE(d.notes,'') LIKE '%BENEFICIARIO%') AS tiene_benef,
         (COALESCE(d.notes,'') LIKE '%Nombre: ' || $2 || E'\nCuenta Zelle: ' || (SELECT c FROM cuenta) || '%') AS mismos_datos
    FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
   WHERE o.id = (SELECT operation_id FROM res)
),
falta AS (
  SELECT NULL::uuid AS id, 'ERROR: hacen falta el nombre Y la cuenta. No se registro nada.' AS accion
   WHERE NULLIF($2,'') IS NULL OR NULLIF($3,'') IS NULL
),
upd AS (
  UPDATE deals SET
    notes = COALESCE(notes,'') ||
            (CASE WHEN (SELECT tiene_benef FROM abierto) THEN E'\n---\nBENEFICIARIO ZELLE ACTUALIZADO - reemplaza al anterior' ELSE E'\n---\nBENEFICIARIO ZELLE' END) ||
            E'\nNombre: ' || $2 || E'\nCuenta Zelle: ' || (SELECT c FROM cuenta),
    updated_at = now()
   WHERE id = (SELECT id FROM abierto WHERE NOT mismos_datos)
     AND NULLIF($2,'') IS NOT NULL AND NULLIF($3,'') IS NOT NULL
  RETURNING id, (SELECT CASE WHEN tiene_benef THEN 'beneficiario Zelle ACTUALIZADO en el envio abierto' ELSE 'beneficiario Zelle agregado en el envio abierto' END FROM abierto) AS accion
),
ins AS (
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  SELECT conv.user_id, conv.account_id, conv.contact_id, conv.cid,
         '78220927-0745-45a8-ba08-a1b33734dbf1','96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109',
         'Remesa +' || conv.phone, 0, 'GYD',
         'BENEFICIARIO ZELLE' || E'\nNombre: ' || $2 || E'\nCuenta Zelle: ' || (SELECT c FROM cuenta), 'open'
    FROM conv
   WHERE NOT EXISTS (SELECT 1 FROM abierto)
     AND (SELECT resultado FROM res) <> 'ambigua'
     AND NULLIF($2,'') IS NOT NULL AND NULLIF($3,'') IS NOT NULL
  RETURNING id, 'envio nuevo creado' AS accion
),
sin_cambio AS (
  SELECT id, 'sin cambios: esos datos ya estaban en el envio abierto' AS accion FROM abierto WHERE mismos_datos
),
ambiguo AS (
  SELECT NULL::uuid AS id,
         'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion
    FROM cerebro_registrar_derivacion(
      $1::uuid,
      'Hay varias operaciones abiertas y el caso requiere revisión humana.',
      'operacion_ambigua',
      (SELECT resultado FROM res) = 'ambigua'
    ) d
)
SELECT * FROM falta UNION ALL SELECT * FROM upd UNION ALL SELECT * FROM ins UNION ALL SELECT * FROM sin_cambio UNION ALL SELECT * FROM ambiguo;
$q$;

  -- ===================================================================
  -- card auto (n1)
  -- ===================================================================
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_auto', 'ins_nueva', '', '', n1,
    v_account, v_owner, v_seed, '9224069996859118', '56430816', 'e-ca-1', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_auto', 'upd_no_tiene', format(v_deal_tpl, E'DEPOSITO: 5,000 GYD - Pago movil'),
    v_op_setup, n1, v_account, v_owner, v_seed,
    '9224069996859118', '56430816', 'e-ca-2', NULL, true);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_auto', 'upd_tiene',
    format(v_deal_tpl, E'BENEFICIARIO (auto)\nTarjeta: 5555000011112222\nCelular: 11112222'),
    $s$SELECT cerebro_registrar_beneficiario_auto($1::uuid, '5555000011112222', '11112222', 'e-ca-3-pre')$s$,
    n1, v_account, v_owner, v_seed,
    '9224069996859118', '56430816', 'e-ca-3', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_auto', 'sin_cambio',
    format(v_deal_tpl, E'BENEFICIARIO (auto)\nTarjeta: 9224069996859118\nCelular: 56430816'),
    $s$SELECT cerebro_registrar_beneficiario_auto($1::uuid, '9224069996859118', '56430816', 'e-ca-4-pre')$s$,
    n1, v_account, v_owner, v_seed,
    '9224069996859118', '56430816', 'e-ca-4', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_auto', 'ambigua',
    format(v_deal_tpl, E'DEPOSITO: 1,000 GYD - Pago movil')
      || '; ' || format(v_deal_tpl, E'DEPOSITO: 2,000 GYD - Pago movil'),
    $s$SELECT cerebro_crear_operacion($1::uuid) FROM generate_series(1,2)$s$,
    n1, v_account, v_owner, v_seed,
    '9224069996859118', '56430816', 'e-ca-5', NULL);

  -- ===================================================================
  -- card tool (n3)
  -- ===================================================================
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_tool', 'ins_nueva', '', '', n3,
    v_account, v_owner, v_seed, 'Juan Perez', '9224069996859118', '56430816', 'e-ct-1');

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_tool', 'ins_nueva_sin_nombre', '', '', n3,
    v_account, v_owner, v_seed, '', '9224069996859118', '56430816', 'e-ct-2');

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_tool', 'upd_no_tiene', format(v_deal_tpl, E'DEPOSITO: 5,000 GYD - Pago movil'),
    v_op_setup, n3, v_account, v_owner, v_seed,
    'Juan Perez', '9224069996859118', '56430816', 'e-ct-3', true);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_tool', 'upd_tiene',
    format(v_deal_tpl, E'BENEFICIARIO (Ana Diaz)\nTarjeta: 5555000011112222\nCelular: 11112222'),
    $s$SELECT cerebro_gestionar_beneficiario($1::uuid, 'Ana Diaz', '5555000011112222', '11112222', 'e-ct-4-pre')$s$,
    n3, v_account, v_owner, v_seed,
    'Juan Perez', '9224069996859118', '56430816', 'e-ct-4');

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_tool', 'sin_cambio',
    format(v_deal_tpl, E'BENEFICIARIO (Juan Perez)\nTarjeta: 9224069996859118\nCelular: 56430816'),
    $s$SELECT cerebro_gestionar_beneficiario($1::uuid, 'Juan Perez', '9224069996859118', '56430816', 'e-ct-5-pre')$s$,
    n3, v_account, v_owner, v_seed,
    'Juan Perez', '9224069996859118', '56430816', 'e-ct-5');

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('card_tool', 'ambigua',
    format(v_deal_tpl, E'DEPOSITO: 1,000 GYD - Pago movil')
      || '; ' || format(v_deal_tpl, E'DEPOSITO: 2,000 GYD - Pago movil'),
    $s$SELECT cerebro_crear_operacion($1::uuid) FROM generate_series(1,2)$s$,
    n3, v_account, v_owner, v_seed,
    'Juan Perez', '9224069996859118', '56430816', 'e-ct-6');

  -- ===================================================================
  -- zelle auto (n2)
  -- ===================================================================
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_auto', 'falta_nombre', '', '', n2,
    v_account, v_owner, v_seed, '', '6562442588', 'e-za-1', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_auto', 'falta_cuenta', '', '', n2,
    v_account, v_owner, v_seed, 'Vanesa Medina', '', 'e-za-2', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_auto', 'ins_nueva_normaliza', '', '', n2,
    v_account, v_owner, v_seed, 'Vanesa Medina', '+1 (469) 512-1137', 'e-za-3', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_auto', 'upd_no_tiene', format(v_deal_tpl, E'DEPOSITO: 143,000 GYD'),
    v_op_setup, n2, v_account, v_owner, v_seed,
    'Vanesa Medina', '6562442588', 'e-za-4', NULL, true);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_auto', 'upd_tiene',
    format(v_deal_tpl, E'BENEFICIARIO ZELLE\nNombre: Vanesa Medina\nCuenta Zelle: 6562442588'),
    $s$SELECT cerebro_registrar_zelle_auto($1::uuid, 'Vanesa Medina', '6562442588', 'e-za-5-pre')$s$,
    n2, v_account, v_owner, v_seed,
    'Otra Persona', '3050000009', 'e-za-5', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_auto', 'sin_cambio',
    format(v_deal_tpl, E'BENEFICIARIO ZELLE\nNombre: Vanesa Medina\nCuenta Zelle: 6562442588'),
    $s$SELECT cerebro_registrar_zelle_auto($1::uuid, 'Vanesa Medina', '6562442588', 'e-za-6-pre')$s$,
    n2, v_account, v_owner, v_seed,
    'Vanesa Medina', '6562442588', 'e-za-6', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_auto', 'sin_cambio_normalizado',
    format(v_deal_tpl, E'BENEFICIARIO ZELLE\nNombre: Vanesa Medina\nCuenta Zelle: 4695121137'),
    $s$SELECT cerebro_registrar_zelle_auto($1::uuid, 'Vanesa Medina', '+1 (469) 512-1137', 'e-za-7-pre')$s$,
    n2, v_account, v_owner, v_seed,
    'Vanesa Medina', '4695121137', 'e-za-7', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_auto', 'ambigua',
    format(v_deal_tpl, E'DEPOSITO: 1,000 GYD - Pago movil')
      || '; ' || format(v_deal_tpl, E'DEPOSITO: 2,000 GYD - Pago movil'),
    $s$SELECT cerebro_crear_operacion($1::uuid) FROM generate_series(1,2)$s$,
    n2, v_account, v_owner, v_seed,
    'Vanesa Medina', '6562442588', 'e-za-8', NULL);

  -- ===================================================================
  -- zelle tool (n4)
  -- ===================================================================
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_tool', 'falta_nombre', '', '', n4,
    v_account, v_owner, v_seed, '', '6562442588', 'e-zt-1', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_tool', 'falta_cuenta', '', '', n4,
    v_account, v_owner, v_seed, 'Vanesa Medina', '', 'e-zt-2', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_tool', 'ins_nueva_normaliza', '', '', n4,
    v_account, v_owner, v_seed, 'Vanesa Medina', '+1 (469) 512-1137', 'e-zt-3', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_tool', 'upd_no_tiene', format(v_deal_tpl, E'DEPOSITO: 143,000 GYD'),
    v_op_setup, n4, v_account, v_owner, v_seed,
    'Vanesa Medina', '6562442588', 'e-zt-4', NULL, true);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_tool', 'upd_tiene',
    format(v_deal_tpl, E'BENEFICIARIO ZELLE\nNombre: Vanesa Medina\nCuenta Zelle: 6562442588'),
    $s$SELECT cerebro_registrar_beneficiario_zelle($1::uuid, 'Vanesa Medina', '6562442588', 'e-zt-5-pre')$s$,
    n4, v_account, v_owner, v_seed,
    'Otra Persona', '3050000009', 'e-zt-5', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_tool', 'sin_cambio',
    format(v_deal_tpl, E'BENEFICIARIO ZELLE\nNombre: Vanesa Medina\nCuenta Zelle: 6562442588'),
    $s$SELECT cerebro_registrar_beneficiario_zelle($1::uuid, 'Vanesa Medina', '6562442588', 'e-zt-6-pre')$s$,
    n4, v_account, v_owner, v_seed,
    'Vanesa Medina', '6562442588', 'e-zt-6', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_tool', 'sin_cambio_normalizado',
    format(v_deal_tpl, E'BENEFICIARIO ZELLE\nNombre: Vanesa Medina\nCuenta Zelle: 4695121137'),
    $s$SELECT cerebro_registrar_beneficiario_zelle($1::uuid, 'Vanesa Medina', '+1 (469) 512-1137', 'e-zt-7-pre')$s$,
    n4, v_account, v_owner, v_seed,
    'Vanesa Medina', '4695121137', 'e-zt-7', NULL);

  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4b_case('zelle_tool', 'ambigua',
    format(v_deal_tpl, E'DEPOSITO: 1,000 GYD - Pago movil')
      || '; ' || format(v_deal_tpl, E'DEPOSITO: 2,000 GYD - Pago movil'),
    $s$SELECT cerebro_crear_operacion($1::uuid) FROM generate_series(1,2)$s$,
    n4, v_account, v_owner, v_seed,
    'Vanesa Medina', '6562442588', 'e-zt-8', NULL);

  RAISE NOTICE 'deal-free-beneficiary-writers: ALL CASES PASS (% cases)', v_seed;
END $do$;

ROLLBACK TO SAVEPOINT wu4b_parity;
