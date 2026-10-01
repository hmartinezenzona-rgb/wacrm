-- =====================================================================
-- reparto-destino-node-adapters.sql — side-by-side parity harness for 163
--
-- MUST run inside an already-open transaction that ends in ROLLBACK (the
-- runner opens BEGIN; … this file; ROLLBACK;). Never COMMIT. Staging only,
-- never production.
--
-- RED before the migration: the two new functions do not exist and the
-- first case fails with 42883 `function public.cerebro_registrar_reparto_
-- multiple(uuid, text, text, text, text, text, text, text, text, text,
-- text) does not exist`.
--
-- WHAT IT PROVES
--   For each of the two nodes (n5 registrar_reparto_multiple,
--   n6 marcar_destino_usd) and each branch, the OLD node SQL (copied
--   verbatim from agent-shared/reports/wu4-n8n-writers.md, run with the
--   node's own $1..$n argument binding order) against a DEAL-BASED
--   operation, and the NEW function against an EQUIVALENT DEAL-FREE
--   operation, must produce:
--     (1) the same returned accion strings, byte for byte, as the same
--         multiset, and the same id-NULL pattern;
--     (2) the same number of remittance_operations for the conversation;
--     (3) the same remittance_beneficiaries rows, column by column
--         (block_index, position, beneficiary_type, name, card_number,
--         phone, zelle_account, amount, currency, status, source,
--         amount_origin, delivery_method, and whether replaced_at is set);
--     (4) the same remittance_operations.delivery_method, EXCEPT in the
--         documented GAP (below), which is printed and not asserted.
--   For every id the new function returns, it must be an operation of the
--   conversation it was given — the explicit orphan check the brief asks
--   for. And for every case, the new conversation must end with ZERO
--   deals rows (count before/after the new run), which is what "no deals
--   anywhere in the new path" means concretely.
--
-- NEGATIVE CONTROL (last block): the harness is re-run on one case with a
--   deliberately stubbed accion. It MUST raise FAIL; a harness that
--   accepts a wrong accion is proven worthless and the run aborts.
--
-- BRANCHES COVERED
--   reparto (n5, 11 binds): err_sin_op / err_con_op / err_tercer_parcial /
--     ins_dos / ins_tres / upd_no_tiene / upd_tiene / repetida /
--     repetida_otro_turno / ambigua                        = 10
--   marcar  (n6, 3 binds):  falta_otro / falta_vacio / falta_tropical_padded /
--     ins_clasica / ins_tropical / ins_efectivo / upd_no_marcado /
--     upd_efectivo / sin_cambio / sin_cambio_efectivo /
--     divergencia_ya_tipado / ambigua                      = 12
--
-- MEASURED (asserted as narrowly as possible, otherwise printed)
--   1. block_index on "op exists, no beneficiary yet, notes had a
--      preamble": the old path counts notes blocks (2), the new path has
--      no notes and lands at max(block_index)+1 (1). Case upd_no_tiene
--      runs with p_allow_block_diff and requires block_index to be the
--      ONLY difference (the no-block projection must be equal).
--   2. operation.delivery_method: the trigger's cascade
--      (coalesce(<notes marker>, first vigente beneficiary_type,
--      delivery_method), the marker being 151's
--      CASE WHEN v_usd='Efectivo' THEN 'efectivo_usd' ELSE lower(v_usd) END)
--      is not reproduced by the reparto function, for the same reason 162
--      did not reproduce it. Printed as GAP (measured) per case, never
--      asserted.
--   3. marcar "already marked" when the rail was typed by 157 with no
--      notes marker: accion differs, database state identical. Case
--      divergencia_ya_tipado runs with p_allow_accion_diff; the accion
--      mismatch is printed as DIVERGENCE (accepted) and every DB check
--      still runs strictly.
--   4. Last block, report-only, no assertions on the counterpart:
--      cerebro_detectar_destino vs the node's own rail rule;
--      cerebro_registrar_destino with zero open operations and with a
--      locked delivery_method, as a non-member (automation) actor;
--      cerebro_aplicar_reparto's row shape on an input it accepts; and
--      the inlined resolver vs the live two-argument overload, including
--      statuses outside the node's four-state filter.
--
-- Assertion convention (as operation-creator-without-deals.sql and
-- deal-free-beneficiary-writers.sql): SAVEPOINT at the top, ROLLBACK TO
-- SAVEPOINT at the end; helpers live in pg_temp.
-- =====================================================================

SAVEPOINT wu4c_parity;


-- ---------------------------------------------------------------------
-- Canonical projections (same shapes as the WU4b harness)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.wu4c_ben(p_conv uuid) RETURNS jsonb
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

CREATE OR REPLACE FUNCTION pg_temp.wu4c_ben_noblock(p_conv uuid) RETURNS jsonb
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

CREATE OR REPLACE FUNCTION pg_temp.wu4c_blocks(p_conv uuid) RETURNS integer[]
LANGUAGE sql STABLE AS $f$
  SELECT coalesce(array_agg(DISTINCT b.block_index ORDER BY b.block_index), '{}')
    FROM remittance_beneficiaries b
    JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.conversation_id = p_conv;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.wu4c_dm(p_conv uuid) RETURNS text[]
LANGUAGE sql STABLE AS $f$
  SELECT coalesce(array_agg(DISTINCT coalesce(o.delivery_method, '<NULL>')
                            ORDER BY coalesce(o.delivery_method, '<NULL>')), '{}')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.wu4c_ops(p_conv uuid) RETURNS bigint
LANGUAGE sql STABLE AS $f$
  SELECT count(*) FROM remittance_operations o WHERE o.conversation_id = p_conv;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.wu4c_deals(p_conv uuid) RETURNS bigint
LANGUAGE sql STABLE AS $f$
  SELECT count(*) FROM deals d WHERE d.conversation_id = p_conv;
$f$;

-- The inlined resolver, exactly as 161/162/163 inline it. Used only by the
-- report-only resolver comparison at the end.
CREATE OR REPLACE FUNCTION pg_temp.wu4c_res(p_conv uuid)
RETURNS TABLE(resultado text, operation_id uuid)
LANGUAGE sql STABLE AS $f$
  SELECT CASE WHEN count(*) = 0 THEN 'ninguna'
              WHEN count(*) = 1 THEN 'unica'
              ELSE 'ambigua' END,
         CASE WHEN count(*) = 1
              THEN (SELECT o.id FROM remittance_operations o
                     WHERE o.conversation_id = p_conv
                       AND o.status NOT IN ('completed','cancelled')
                       AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])
                     LIMIT 1)
         END
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv
     AND o.status NOT IN ('completed','cancelled')
     AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);
$f$;


-- ---------------------------------------------------------------------
-- One parity case: fixtures -> [pre] -> OLD run -> NEW run -> diff
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.wu4c_case(
  p_node      text,          -- 'reparto' | 'marcar'
  p_caso      text,
  p_old_setup text,          -- SQL, $1=conv_old $2=account $3=owner ('' = nothing)
  p_new_setup text,          -- SQL, $1=conv_new $2=account $3=owner ('' = nothing)
  p_old_sql   text,          -- the node SQL verbatim, $1..$11
  p_old_pre   text,          -- '' or node SQL run first with the same $1..$11
  p_new_pre   text,          -- '' or new-fn SQL run first with the same $1..$11
  p_account   uuid,
  p_owner     uuid,
  p_seed      bigint,
  p_args      text[],        -- node data args in node order, WITHOUT $1
  p_allow_block_diff  boolean DEFAULT false,
  p_allow_accion_diff boolean DEFAULT false,
  p_stub              boolean DEFAULT false
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
  v_d_old    bigint;
  v_d_new    bigint;
  v_bo       jsonb;
  v_bn       jsonb;
  v_exec     text;
  v_sql      text;
  r          record;
BEGIN
  IF array_length(p_args, 1) IS NULL THEN p_args := ARRAY[]::text[]; END IF;
  WHILE array_length(p_args, 1) < 10 LOOP p_args := p_args || ''::text; END LOOP;

  -- ---------------------------------------------------------- fixtures
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), p_owner, '1666' || lpad((p_seed * 10 + 1)::text, 7, '0'),
          'WU4C ' || p_caso || ' old', p_account)
  RETURNING id INTO v_c1;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), p_owner, v_c1, p_account)
  RETURNING id INTO v_conv_old;

  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), p_owner, '1666' || lpad((p_seed * 10 + 2)::text, 7, '0'),
          'WU4C ' || p_caso || ' new', p_account)
  RETURNING id INTO v_c2;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), p_owner, v_c2, p_account)
  RETURNING id INTO v_conv_new;

  IF p_old_setup <> '' THEN EXECUTE p_old_setup USING v_conv_old, p_account, p_owner; END IF;
  IF p_new_setup <> '' THEN EXECUTE p_new_setup USING v_conv_new, p_account, p_owner; END IF;

  -- ------------------------------------------------------ optional pre-run
  -- The node SQL itself, with the same binding order; results discarded.
  -- Used for the turn-scoped dedupe cases.
  IF p_old_pre <> '' THEN
    EXECUTE p_old_pre USING v_conv_old,
      p_args[1], p_args[2], p_args[3], p_args[4], p_args[5], p_args[6],
      p_args[7], p_args[8], p_args[9], p_args[10];
  END IF;
  IF p_new_pre <> '' THEN
    EXECUTE p_new_pre USING v_conv_new,
      p_args[1], p_args[2], p_args[3], p_args[4], p_args[5], p_args[6],
      p_args[7], p_args[8], p_args[9], p_args[10];
  END IF;

  -- ------------------------------------------------------------ OLD run
  FOR r IN EXECUTE p_old_sql USING v_conv_old,
             p_args[1], p_args[2], p_args[3], p_args[4], p_args[5], p_args[6],
             p_args[7], p_args[8], p_args[9], p_args[10] LOOP
    v_acc_old  := v_acc_old  || r.accion;
    v_null_old := v_null_old || (r.id IS NULL);
  END LOOP;

  -- ------------------------------------------------------------ NEW run
  v_d_new := pg_temp.wu4c_deals(v_conv_new);

  IF p_node = 'reparto' THEN
    v_exec := p_args[10] || '-new';
    v_sql  := 'SELECT * FROM cerebro_registrar_reparto_multiple($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)';
    FOR r IN EXECUTE v_sql USING v_conv_new,
               p_args[1], p_args[2], p_args[3], p_args[4], p_args[5], p_args[6],
               p_args[7], p_args[8], p_args[9], v_exec LOOP
      v_acc_new  := v_acc_new  || r.accion;
      v_null_new := v_null_new || (r.id IS NULL);
      IF r.id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM remittance_operations o
            WHERE o.id = r.id AND o.conversation_id = v_conv_new) THEN
        RAISE EXCEPTION 'FAIL [% %] NEW returned id % that is not an operation of its conversation (silent orphan)',
          p_node, p_caso, r.id;
      END IF;
    END LOOP;
  ELSIF p_node = 'marcar' THEN
    v_exec := p_args[2] || '-new';
    v_sql  := 'SELECT * FROM cerebro_marcar_destino_usd($1,$2,$3)';
    FOR r IN EXECUTE v_sql USING v_conv_new, p_args[1], v_exec LOOP
      v_acc_new  := v_acc_new  || r.accion;
      v_null_new := v_null_new || (r.id IS NULL);
      IF r.id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM remittance_operations o
            WHERE o.id = r.id AND o.conversation_id = v_conv_new) THEN
        RAISE EXCEPTION 'FAIL [% %] NEW returned id % that is not an operation of its conversation (silent orphan)',
          p_node, p_caso, r.id;
      END IF;
    END LOOP;
  ELSE
    RAISE EXCEPTION 'unknown node %', p_node;
  END IF;

  -- ------------------------------------- (4a) no deals row may be created
  IF pg_temp.wu4c_deals(v_conv_new) <> v_d_new THEN
    RAISE EXCEPTION 'FAIL [% %] the new function created a deals row: before=% after=%',
      p_node, p_caso, v_d_new, pg_temp.wu4c_deals(v_conv_new);
  END IF;
  IF v_d_new <> 0 THEN
    RAISE EXCEPTION 'FAIL [% %] the deal-free fixture already had % deals rows',
      p_node, p_caso, v_d_new;
  END IF;

  -- Negative control: stub one accion so the comparison MUST fail.
  IF p_stub AND array_length(v_acc_new, 1) >= 1 THEN
    v_acc_new[1] := v_acc_new[1] || ' [STUB]';
  END IF;

  -- --------------------------------------------------- (1) returned rows
  IF (SELECT jsonb_agg(x ORDER BY x) FROM unnest(v_acc_old) x)
     IS DISTINCT FROM
     (SELECT jsonb_agg(x ORDER BY x) FROM unnest(v_acc_new) x) THEN
    IF p_allow_accion_diff THEN
      RAISE NOTICE 'DIVERGENCE (accepted) [% %] accion old=% new=%',
        p_node, p_caso, v_acc_old, v_acc_new;
    ELSE
      RAISE EXCEPTION 'FAIL [% %] accion differs: old=% new=%',
        p_node, p_caso, v_acc_old, v_acc_new;
    END IF;
  END IF;
  IF (SELECT jsonb_agg(y ORDER BY y) FROM unnest(v_null_old) y)
     IS DISTINCT FROM
     (SELECT jsonb_agg(y ORDER BY y) FROM unnest(v_null_new) y) THEN
    RAISE EXCEPTION 'FAIL [% %] returned-id NULL pattern differs: old=% new=%',
      p_node, p_caso, v_null_old, v_null_new;
  END IF;

  -- ------------------------------------------- (2) operation row counts
  SELECT count(*) INTO v_opc_old FROM remittance_operations WHERE conversation_id = v_conv_old;
  v_opc_new := pg_temp.wu4c_ops(v_conv_new);
  IF v_opc_old <> v_opc_new THEN
    RAISE EXCEPTION 'FAIL [% %] operation count differs: old=% new=% (one path created an operation the other did not)',
      p_node, p_caso, v_opc_old, v_opc_new;
  END IF;

  -- --------------------------------------- (3) beneficiary row diff
  v_bo := pg_temp.wu4c_ben(v_conv_old);
  v_bn := pg_temp.wu4c_ben(v_conv_new);
  IF v_bo IS DISTINCT FROM v_bn THEN
    IF p_allow_block_diff
       AND pg_temp.wu4c_ben_noblock(v_conv_old) = pg_temp.wu4c_ben_noblock(v_conv_new) THEN
      RAISE NOTICE 'DIVERGENCE (accepted) [% %] block_index only: old=% new=%',
        p_node, p_caso, pg_temp.wu4c_blocks(v_conv_old), pg_temp.wu4c_blocks(v_conv_new);
    ELSE
      RAISE EXCEPTION E'FAIL [% %] beneficiary rows differ:\n  old=%\n  new=%',
        p_node, p_caso, v_bo, v_bn;
    END IF;
  END IF;

  IF v_opc_new = 0 AND v_bn <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [% %] no operation was created but beneficiaries exist: %',
      p_node, p_caso, v_bn;
  END IF;

  -- ------------------------------------------- (4) operation delivery_method
  IF pg_temp.wu4c_dm(v_conv_old) IS DISTINCT FROM pg_temp.wu4c_dm(v_conv_new) THEN
    IF p_node = 'marcar' THEN
      RAISE EXCEPTION 'FAIL [% %] delivery_method differs: old=% new=%',
        p_node, p_caso, pg_temp.wu4c_dm(v_conv_old), pg_temp.wu4c_dm(v_conv_new);
    END IF;
    -- reparto: the 042 cascade, deliberately not reproduced (header note).
    RAISE NOTICE 'GAP (measured) [% %] operation.delivery_method old=% new=%',
      p_node, p_caso, pg_temp.wu4c_dm(v_conv_old), pg_temp.wu4c_dm(v_conv_new);
  END IF;

  RAISE NOTICE 'PASS [% / %] accion=% rows=%',
    p_node, p_caso, coalesce(v_acc_new[1], '(none)'),
    coalesce(array_length(v_acc_new, 1), 0);
END;
$f$;


-- =====================================================================
-- The cases
-- =====================================================================

DO $do$
DECLARE
  v_hash    CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_owner   uuid := gen_random_uuid();
  v_account uuid;
  v_seed    bigint := 0;

  v_deal_tpl text;   -- %L = notes
  v_op       text := $s$SELECT cerebro_crear_operacion($1::uuid)$s$;

  n5 text;           -- registrar_reparto_multiple, verbatim
  n6 text;           -- marcar_destino_usd, verbatim

  -- fixture data (already normalized, so notes and arguments agree)
  t1 CONSTANT text := '1234567890123456';
  c1 CONSTANT text := '12345678';
  m1 CONSTANT text := '25000';
  t2 CONSTANT text := '6543210987654321';
  c2 CONSTANT text := '87654321';
  m2 CONSTANT text := '15000';
  t3 CONSTANT text := '1111222233334444';
  c3 CONSTANT text := '11223344';
  m3 CONSTANT text := '10000';
  v_block2 text;     -- the 2-beneficiary reparto block, as the parser sees it
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'wu4c-' || v_owner || '@test.invalid', v_hash, now(), now(), now(),
          '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id)
  VALUES (gen_random_uuid(), 'WU4c parity harness', v_owner)
  RETURNING id INTO v_account;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner, 'wu4c owner',
          'wu4c-' || v_owner || '@test.invalid', v_account, 'owner');

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  v_deal_tpl := $s$
INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                   stage_id, title, value, currency, notes, status)
SELECT $3::uuid, $2::uuid, c.contact_id, c.id, '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid,
       '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109'::uuid, 'Remesa WU4C', 0, 'GYD', %L, 'open'
  FROM conversations c WHERE c.id = $1::uuid
$s$;

  v_block2 := 'REPARTO ENTRE VARIOS BENEFICIARIOS'
              || E'\n1) Tarjeta: ' || t1 || ' | Celular: ' || c1 || ' | Recibe: ' || m1 || ' CUP'
              || E'\n2) Tarjeta: ' || t2 || ' | Celular: ' || c2 || ' | Recibe: ' || m2 || ' CUP';

  -- ------------------------------------------------------------------
  -- n5 — registrar_reparto_multiple, VERBATIM from the WU4 report
  -- ------------------------------------------------------------------
  n5 := $q$
WITH res AS (SELECT * FROM cerebro_resolver_operacion($1::uuid, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])),
idem AS (SELECT $11 || ':registrar_reparto_multiple:' || md5(coalesce($2,'')||'|'||coalesce($3,'')||'|'||coalesce($4,'')||'|'||coalesce($5,'')||'|'||coalesce($6,'')||'|'||coalesce($7,'')||'|'||coalesce($8,'')||'|'||coalesce($9,'')||'|'||coalesce($10,'')) AS k),
reg AS (
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT (SELECT k FROM idem), 'registrar_reparto_multiple', $11, $1::uuid,
         (SELECT operation_id FROM res), jsonb_build_array(to_jsonb($2::text),to_jsonb($3::text),to_jsonb($4::text),to_jsonb($5::text),to_jsonb($6::text),to_jsonb($7::text),to_jsonb($8::text),to_jsonb($9::text),to_jsonb($10::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id
),
conv AS (SELECT v.id AS cid, v.contact_id, v.account_id, v.user_id, c.phone FROM conversations v JOIN contacts c ON c.id=v.contact_id WHERE v.id=$1::uuid), p AS (SELECT regexp_replace(COALESCE($2,''),'[^0-9]','','g') AS t1, right(regexp_replace(COALESCE($3,''),'[^0-9]','','g'),8) AS c1, regexp_replace(COALESCE($4,''),'[^0-9]','','g') AS m1, regexp_replace(COALESCE($5,''),'[^0-9]','','g') AS t2, right(regexp_replace(COALESCE($6,''),'[^0-9]','','g'),8) AS c2, regexp_replace(COALESCE($7,''),'[^0-9]','','g') AS m2, regexp_replace(COALESCE($8,''),'[^0-9]','','g') AS t3, right(regexp_replace(COALESCE($9,''),'[^0-9]','','g'),8) AS c3, regexp_replace(COALESCE($10,''),'[^0-9]','','g') AS m3), val AS (SELECT (p.t1 ~ '^[0-9]{16}$' AND p.c1 ~ '^[0-9]{8}$' AND p.m1 <> '' AND p.t2 ~ '^[0-9]{16}$' AND p.c2 ~ '^[0-9]{8}$' AND p.m2 <> '' AND (p.t3 = '' OR (p.t3 ~ '^[0-9]{16}$' AND p.c3 ~ '^[0-9]{8}$' AND p.m3 <> ''))) AS ok FROM p), abierto AS (SELECT d.id, (COALESCE(d.notes,'') LIKE '%BENEFICIARIO%') AS tiene_benef FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
   WHERE o.id = (SELECT operation_id FROM res)), bloque AS (SELECT (CASE WHEN (SELECT tiene_benef FROM abierto) THEN 'REPARTO ACTUALIZADO ENTRE VARIOS BENEFICIARIOS - reemplaza lo anterior' ELSE 'REPARTO ENTRE VARIOS BENEFICIARIOS' END) || E'\n1) Tarjeta: ' || p.t1 || ' | Celular: ' || p.c1 || ' | Recibe: ' || p.m1 || ' CUP' || E'\n2) Tarjeta: ' || p.t2 || ' | Celular: ' || p.c2 || ' | Recibe: ' || p.m2 || ' CUP' || (CASE WHEN p.t3 <> '' THEN E'\n3) Tarjeta: ' || p.t3 || ' | Celular: ' || p.c3 || ' | Recibe: ' || p.m3 || ' CUP' ELSE '' END) AS txt FROM p), upd AS (UPDATE deals SET notes = COALESCE(notes,'') || E'\n---\n' || (SELECT txt FROM bloque), updated_at=now() WHERE id=(SELECT id FROM abierto) AND (SELECT ok FROM val) AND EXISTS (SELECT 1 FROM reg) RETURNING id, 'reparto registrado en el envio abierto' AS accion), ins AS (INSERT INTO deals (user_id,account_id,contact_id,conversation_id,pipeline_id,stage_id,title,value,currency,notes,status) SELECT conv.user_id,conv.account_id,conv.contact_id,conv.cid,'78220927-0745-45a8-ba08-a1b33734dbf1','96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109','Remesa +'||conv.phone,0,'GYD',(SELECT txt FROM bloque),'open' FROM conv WHERE NOT EXISTS (SELECT 1 FROM abierto)
     AND (SELECT resultado FROM res) <> 'ambigua' AND (SELECT ok FROM val) AND EXISTS (SELECT 1 FROM reg) RETURNING id, 'envio nuevo creado con reparto' AS accion), err AS (SELECT NULL::uuid AS id, 'ERROR: faltan datos o algun numero no es valido. Pide al cliente los datos que falten, no inventes nada.' AS accion WHERE NOT (SELECT ok FROM val)),
ambiguo AS (
  SELECT NULL::uuid AS id,
         'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion
    FROM cerebro_registrar_derivacion(
      $1::uuid,
      'Hay varias operaciones abiertas y el caso requiere revisión humana.',
      'operacion_ambigua',
      (SELECT resultado FROM res) = 'ambigua'
    ) d
),
repetida AS (
  SELECT NULL::uuid AS id,
         'sin cambios: ese mismo reparto ya se registro en este turno' AS accion
   WHERE NOT EXISTS (SELECT 1 FROM reg)
)
SELECT * FROM upd UNION ALL SELECT * FROM ins UNION ALL SELECT * FROM err UNION ALL SELECT * FROM ambiguo UNION ALL SELECT * FROM repetida;
$q$;

  -- ------------------------------------------------------------------
  -- n6 — marcar_destino_usd, VERBATIM from the WU4 report
  -- ------------------------------------------------------------------
  n6 := $q$
WITH res AS (SELECT * FROM cerebro_resolver_operacion($1::uuid, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])),
idem AS (SELECT $3 || ':marcar_destino_usd:' || md5(coalesce($2,'')) AS k),
reg AS (
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT (SELECT k FROM idem), 'marcar_destino_usd', $3, $1::uuid,
         (SELECT operation_id FROM res), jsonb_build_array(to_jsonb($2::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id
),
conv AS (
  SELECT v.id AS cid, v.contact_id, v.account_id, v.user_id, c.phone
    FROM conversations v JOIN contacts c ON c.id=v.contact_id
   WHERE v.id=$1::uuid
),
tipo AS (
  SELECT CASE WHEN lower($2) LIKE 'trop%' THEN 'Tropical'
              WHEN lower($2) LIKE 'cl%'   THEN 'Clasica'
              WHEN lower($2) LIKE 'efec%' THEN 'Efectivo'
              ELSE NULL END AS t
),
abierto AS (
  SELECT d.id,
         (COALESCE(d.notes,'') LIKE '%ENTREGA EN USD: ' || (SELECT t FROM tipo) || '%') AS ya_marcado
    FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
   WHERE o.id = (SELECT operation_id FROM res)
),
falta AS (
  SELECT NULL::uuid AS id, 'ERROR: el tipo debe ser clasica, tropical o efectivo. No se marco nada.' AS accion
   WHERE (SELECT t FROM tipo) IS NULL
),
upd AS (
  UPDATE deals SET
    notes = COALESCE(notes,'') || E'\n---\nENTREGA EN USD: ' || (SELECT t FROM tipo),
    updated_at = now()
   WHERE id = (SELECT id FROM abierto WHERE NOT ya_marcado)
     AND (SELECT t FROM tipo) IS NOT NULL
  RETURNING id, 'destino marcado: entrega en USD por ' || (SELECT t FROM tipo) AS accion
),
ins AS (
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  SELECT conv.user_id, conv.account_id, conv.contact_id, conv.cid,
         '78220927-0745-45a8-ba08-a1b33734dbf1','96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109',
         'Remesa +' || conv.phone, 0, 'GYD',
         'ENTREGA EN USD: ' || (SELECT t FROM tipo), 'open'
    FROM conv
   WHERE NOT EXISTS (SELECT 1 FROM abierto)
     AND (SELECT resultado FROM res) <> 'ambigua'
     AND (SELECT t FROM tipo) IS NOT NULL
  RETURNING id, 'envio nuevo creado, entrega en USD por ' || (SELECT t FROM tipo) AS accion
),
sin_cambio AS (
  SELECT id, 'sin cambios: ese destino ya estaba marcado' AS accion FROM abierto WHERE ya_marcado
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
  -- reparto (n5) — 11 binds: conv, t1,c1,m1, t2,c2,m2, t3,c3,m3, exec
  -- ===================================================================

  -- err, no open operation
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('reparto', 'err_sin_op', '', '', n5, '', '',
    v_account, v_owner, v_seed,
    ARRAY['123', c1, m1, t2, c2, m2, '', '', '', 'e-rp-1'], false);

  -- err, operation open but args invalid (a 15-digit tarjeta)
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('reparto', 'err_con_op',
    format(v_deal_tpl, E'DEPOSITO: 143,000 GYD'), v_op, n5, '', '',
    v_account, v_owner, v_seed,
    ARRAY['123456789012345', c1, m1, t2, c2, m2, '', '', '', 'e-rp-2'], false);

  -- err, third beneficiary only half given (empty celular3)
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('reparto', 'err_tercer_parcial',
    format(v_deal_tpl, E'DEPOSITO: 143,000 GYD'), v_op, n5, '', '',
    v_account, v_owner, v_seed,
    ARRAY[t1, c1, m1, t2, c2, m2, t3, '', m3, 'e-rp-3'], false);

  -- ins, two beneficiaries, mixed separators in the raw numbers
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('reparto', 'ins_dos', '', '', n5, '', '',
    v_account, v_owner, v_seed,
    ARRAY['1234 5678 9012 3456', '+53 51234567', '25,000', t2, c2, '15000', '', '', '', 'e-rp-4'], false);

  -- ins, three beneficiaries
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('reparto', 'ins_tres', '', '', n5, '', '',
    v_account, v_owner, v_seed,
    ARRAY[t1, c1, m1, t2, c2, m2, t3, c3, m3, 'e-rp-5'], false);

  -- upd, operation exists with a preamble block and no beneficiary yet.
  -- The old block_index counts the notes blocks (2); the new path has no
  -- notes and lands at max(block_index)+1 = 1. Accepted, narrowly.
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('reparto', 'upd_no_tiene',
    format(v_deal_tpl, E'DEPOSITO: 143,000 GYD'), v_op, n5, '', '',
    v_account, v_owner, v_seed,
    ARRAY[t1, c1, m1, t2, c2, m2, '', '', '', 'e-rp-6'], true);

  -- upd, operation already has a reparto: prior rows become reemplazado,
  -- the new block lands at 2 on both sides.
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('reparto', 'upd_tiene',
    format(v_deal_tpl, v_block2), v_op, n5,
    '', -- no pre-run on the old side: the fixture deal is the history
    $s$SELECT * FROM cerebro_registrar_reparto_multiple($1::uuid,$2,$3,$4,$5,$6,$7,$8,$9,$10, $11 || '-seed')$s$,
    v_account, v_owner, v_seed,
    ARRAY[t1, c1, m1, t2, c2, m2, '', '', '', 'e-rp-7'], false);

  -- repetida, same turn (same execution id) re-sent, twice over
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('reparto', 'repetida', '', '', n5,
    n5, -- pre-run with the SAME exec id -> key already used
    -- must match the main run's key exactly: exec || '-new'
    $s$SELECT * FROM cerebro_registrar_reparto_multiple($1::uuid,$2,$3,$4,$5,$6,$7,$8,$9,$10, $11 || '-new')$s$,
    v_account, v_owner, v_seed,
    ARRAY[t1, c1, m1, t2, c2, m2, '', '', '', 'e-rp-8'], false);

  -- the same data one turn later (a different execution id) is applied
  -- again, on both sides: the dedupe is turn-scoped, not history-scoped.
  -- The pre-run is the node SQL verbatim except for its $11, replaced by a
  -- literal so it is a genuinely different turn from the main run below
  -- ($11 is a bound parameter, and the key is built from it).
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('reparto', 'repetida_otro_turno', '', '', n5,
    replace(n5, '$11', $x$'e-rp-9-oldpre'$x$),
    $s$SELECT * FROM cerebro_registrar_reparto_multiple($1::uuid,$2,$3,$4,$5,$6,$7,$8,$9,$10, $11 || '-newpre')$s$,
    v_account, v_owner, v_seed,
    ARRAY[t1, c1, m1, t2, c2, m2, '', '', '', 'e-rp-9'], false);

  -- ambigua, two open operations
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('reparto', 'ambigua',
    format(v_deal_tpl, E'DEPOSITO: 1,000 GYD')
      || '; ' || format(v_deal_tpl, E'DEPOSITO: 2,000 GYD'),
    $s$SELECT cerebro_crear_operacion($1::uuid); SELECT cerebro_crear_operacion($1::uuid)$s$,
    n5, '', '',
    v_account, v_owner, v_seed,
    ARRAY[t1, c1, m1, t2, c2, m2, '', '', '', 'e-rp-10'], false);

  -- ===================================================================
  -- marcar (n6) — 3 binds: conv, tipo, exec
  -- ===================================================================

  -- falta, a word the node's LIKE chain does not accept
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'falta_otro', '', '', n6, '', '',
    v_account, v_owner, v_seed, ARRAY['tarjeta', 'e-md-1'], false);

  -- falta, empty
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'falta_vacio', '', '', n6, '', '',
    v_account, v_owner, v_seed, ARRAY['', 'e-md-2'], false);

  -- ins, Clasica (no accent)
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'ins_clasica', '', '', n6, '', '',
    v_account, v_owner, v_seed, ARRAY['clasica', 'e-md-3'], false);

  -- ins, Tropical, capitalized as the model may send it
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'ins_tropical', '', '', n6, '', '',
    v_account, v_owner, v_seed, ARRAY['Tropical', 'e-md-4'], false);

  -- falta, Tropical PADDED. The node's rule is `lower($2) LIKE 'trop%'`, which
  -- is anchored at the start: ' tropical ' does NOT match, so both sides emit
  -- the falta literal. Kept as evidence that trimming is NOT part of the
  -- contract and the new function does not silently add it.
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'falta_tropical_padded', '', '', n6, '', '',
    v_account, v_owner, v_seed, ARRAY[' tropical ', 'e-md-4b'], false);

  -- ins, Efectivo: 151 line 77 maps the notes marker to the literal
  -- 'efectivo_usd', so this DOES set a rail on both sides.
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'ins_efectivo', '', '', n6, '', '',
    v_account, v_owner, v_seed, ARRAY['efectivo', 'e-md-5'], false);

  -- upd, operation open, nothing marked yet
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'upd_no_marcado',
    format(v_deal_tpl, E'DEPOSITO: 143,000 GYD'), v_op, n6, '', '',
    v_account, v_owner, v_seed, ARRAY['Tropical', 'e-md-6'], false);

  -- upd, operation open, nothing marked yet, Efectivo (the 151 -> 'efectivo_usd' rail)
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'upd_efectivo',
    format(v_deal_tpl, E'DEPOSITO: 143,000 GYD'), v_op, n6, '', '',
    v_account, v_owner, v_seed, ARRAY['Efectivo', 'e-md-6b'], false);

  -- sin_cambio, already marked with the same rail
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'sin_cambio',
    format(v_deal_tpl, E'ENTREGA EN USD: Clasica'),
    $s$SELECT cerebro_crear_operacion($1::uuid); UPDATE remittance_operations SET delivery_method='clasica' WHERE conversation_id=$1::uuid$s$,
    n6, '', '',
    v_account, v_owner, v_seed, ARRAY['Clasica', 'e-md-7'], false);

  -- sin_cambio, Efectivo: the marked state is 'efectivo_usd', not 'efectivo'
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'sin_cambio_efectivo',
    format(v_deal_tpl, E'ENTREGA EN USD: Efectivo'),
    $s$SELECT cerebro_crear_operacion($1::uuid); UPDATE remittance_operations SET delivery_method='efectivo_usd' WHERE conversation_id=$1::uuid$s$,
    n6, '', '',
    v_account, v_owner, v_seed, ARRAY['Efectivo', 'e-md-7b'], false);

  -- DIVERGENCE (accepted): the rail was typed by 157 with no notes marker.
  -- The old node cannot see it and re-marks; the new function sees the
  -- operation's own delivery_method and answers 'sin cambios'. DB state is
  -- identical on both sides; the accion is the only difference.
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'divergencia_ya_tipado',
    format(v_deal_tpl, E'DEPOSITO: 143,000 GYD')
      || '; UPDATE remittance_operations SET delivery_method=''clasica'' WHERE conversation_id=$1::uuid',
    $s$SELECT cerebro_crear_operacion($1::uuid); UPDATE remittance_operations SET delivery_method='clasica' WHERE conversation_id=$1::uuid$s$,
    n6, '', '',
    v_account, v_owner, v_seed, ARRAY['Clasica', 'e-md-8'], false, true);

  -- ambigua, two open operations
  v_seed := v_seed + 1;
  PERFORM pg_temp.wu4c_case('marcar', 'ambigua',
    format(v_deal_tpl, E'DEPOSITO: 1,000 GYD')
      || '; ' || format(v_deal_tpl, E'DEPOSITO: 2,000 GYD'),
    $s$SELECT cerebro_crear_operacion($1::uuid); SELECT cerebro_crear_operacion($1::uuid)$s$,
    n6, '', '',
    v_account, v_owner, v_seed, ARRAY['clasica', 'e-md-9'], false);

  RAISE NOTICE 'reparto-destino-node-adapters: ALL PARITY CASES PASS (% cases)', v_seed;
END $do$;


-- =====================================================================
-- MEASURED / REPORT-ONLY BLOCKS (no assertion on the counterpart)
-- =====================================================================

-- ---- the inlined resolver vs the live two-argument overload -----------
DO $do$
DECLARE
  v_owner   uuid := gen_random_uuid();
  v_account uuid;
  v_contact uuid;
  v_conv    uuid;
  v_hash    CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_my      record;
  v_live    record;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'wu4c-r-' || v_owner || '@test.invalid', v_hash, now(), now(), now(),
          '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id)
  VALUES (gen_random_uuid(), 'WU4c resolver probe', v_owner) RETURNING id INTO v_account;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner, '1666' || lpad((900 + (random()*99)::int)::text, 7, '0'),
          'WU4c resolver', v_account) RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner, v_contact, v_account) RETURNING id INTO v_conv;

  SELECT * INTO v_my FROM pg_temp.wu4c_res(v_conv);
  SELECT resultado, operation_id INTO v_live
    FROM cerebro_resolver_operacion(v_conv,
         ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);
  RAISE NOTICE 'RESOLVER 0 ops:     inline=(%,%) live2arg=(%,%) %',
    v_my.resultado, v_my.operation_id, v_live.resultado, v_live.operation_id,
    CASE WHEN v_my.resultado IS NOT DISTINCT FROM v_live.resultado
          AND v_my.operation_id IS NOT DISTINCT FROM v_live.operation_id
         THEN 'MATCH' ELSE 'DIFFER' END;

  PERFORM cerebro_crear_operacion(v_conv);
  SELECT * INTO v_my FROM pg_temp.wu4c_res(v_conv);
  SELECT resultado, operation_id INTO v_live
    FROM cerebro_resolver_operacion(v_conv,
         ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);
  RAISE NOTICE 'RESOLVER 1 op:      inline=(%,%) live2arg=(%,%) %',
    v_my.resultado, v_my.operation_id, v_live.resultado, v_live.operation_id,
    CASE WHEN v_my.resultado IS NOT DISTINCT FROM v_live.resultado
          AND v_my.operation_id IS NOT DISTINCT FROM v_live.operation_id
         THEN 'MATCH' ELSE 'DIFFER' END;

  PERFORM cerebro_crear_operacion(v_conv);
  SELECT * INTO v_my FROM pg_temp.wu4c_res(v_conv);
  SELECT resultado, operation_id INTO v_live
    FROM cerebro_resolver_operacion(v_conv,
         ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);
  RAISE NOTICE 'RESOLVER 2 ops:     inline=(%,%) live2arg=(%,%) %',
    v_my.resultado, v_my.operation_id, v_live.resultado, v_live.operation_id,
    CASE WHEN v_my.resultado IS NOT DISTINCT FROM v_live.resultado
          AND v_my.operation_id IS NOT DISTINCT FROM v_live.operation_id
         THEN 'MATCH' ELSE 'DIFFER' END;

  -- A status OUTSIDE the node's four-state filter but not closed.
  UPDATE remittance_operations SET status = 'awaiting_deposit'
   WHERE conversation_id = v_conv;
  SELECT * INTO v_my FROM pg_temp.wu4c_res(v_conv);
  SELECT resultado, operation_id INTO v_live
    FROM cerebro_resolver_operacion(v_conv,
         ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);
  RAISE NOTICE 'RESOLVER 2 awaiting_deposit (outside the node''s filter): inline=(%,%) live2arg=(%,%) %',
    v_my.resultado, v_my.operation_id, v_live.resultado, v_live.operation_id,
    CASE WHEN v_my.resultado IS NOT DISTINCT FROM v_live.resultado
          AND v_my.operation_id IS NOT DISTINCT FROM v_live.operation_id
         THEN 'MATCH' ELSE 'DIFFER' END;
END $do$;


-- ---- 157 vs the node: rail acceptance, zero ops, admin lock ----------
DO $do$
DECLARE
  v_owner   uuid := gen_random_uuid();
  v_account uuid;
  v_contact uuid;
  v_contact2 uuid;
  v_conv    uuid;
  v_conv2   uuid;
  v_user2   uuid := gen_random_uuid();
  v_hash    CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_t       text;
  v_r       record;
  v_before  text;
  v_after   text;
  v_n       bigint;
BEGIN
  IF to_regprocedure('public.cerebro_registrar_destino(uuid,text)') IS NULL THEN
    RAISE NOTICE 'SKIPPED 157 comparison: cerebro_registrar_destino(uuid,text) is not in this database';
    RETURN;
  END IF;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'wu4c-157-' || v_owner || '@test.invalid', v_hash, now(), now(), now(),
          '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id)
  VALUES (gen_random_uuid(), 'WU4c 157 probe', v_owner) RETURNING id INTO v_account;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner, 'WU4c 157 owner',
          'wu4c-157-' || v_owner || '@test.invalid', v_account, 'owner');
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner, '1666007001001', 'WU4c 157', v_account) RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner, v_contact, v_account) RETURNING id INTO v_conv;
  -- A second, SEPARATE contact: ux_conversations_account_contact forbids two
  -- conversations for one (account_id, contact_id), and
  -- idx_contacts_account_phone_normalized (022) forbids two contacts with the
  -- same normalized phone in one account — so the phones are fixed, not random.
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner, '1666007001002', 'WU4c 157b', v_account) RETURNING id INTO v_contact2;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner, v_contact2, v_account) RETURNING id INTO v_conv2;

  -- (1) rail acceptance: the node's own rule vs cerebro_detectar_destino
  FOREACH v_t IN ARRAY ARRAY['clasica','Clasica','CLASICA','tropical','tropico','tarjeta',
                             'efectivo','efectivo/tropical','claro','clasico o tropical','']
  LOOP
    RAISE NOTICE 'RAIL node(%) -> %, detectar(%) -> %',
      coalesce(quote_literal(v_t),'NULL'),
      coalesce((SELECT CASE WHEN lower(v_t) LIKE 'trop%' THEN 'Tropical'
                            WHEN lower(v_t) LIKE 'cl%'   THEN 'Clasica'
                            WHEN lower(v_t) LIKE 'efec%' THEN 'Efectivo' END), 'NULL'),
      coalesce(quote_literal(v_t),'NULL'),
      coalesce(cerebro_detectar_destino(v_t), 'NULL');
  END LOOP;

  -- (2) zero open operations: 157 records a pending row and creates nothing;
  --     the node's contract creates a new remesa. Both are printed.
  v_n := pg_temp.wu4c_ops(v_conv2);
  RAISE NOTICE 'ZERO-OPS before: ops=% pending=%',
    v_n,
    (SELECT count(*) FROM cerebro_destino_pendiente WHERE conversation_id = v_conv2);
  RAISE NOTICE 'ZERO-OPS 157 registrar_destino -> %', cerebro_registrar_destino(v_conv2, 'clasica');
  RAISE NOTICE 'ZERO-OPS after 157: ops=% pending=%',
    pg_temp.wu4c_ops(v_conv2),
    (SELECT count(*) FROM cerebro_destino_pendiente WHERE conversation_id = v_conv2);
  RAISE NOTICE 'ZERO-OPS node-contract fn on the same empty conversation -> %',
    (SELECT string_agg(x.accion, ' | ') FROM cerebro_marcar_destino_usd(v_conv, 'clasica', 'e-157-zero') x);
  RAISE NOTICE 'ZERO-OPS after node-contract fn: ops=% delivery=%',
    pg_temp.wu4c_ops(v_conv), pg_temp.wu4c_dm(v_conv);

  -- (3) a locked delivery_method. The lock itself must be written by a HUMAN
  --     actor (096 line 229: a non-human write to admin_locked_fields is
  --     reverted), so the owner claims are installed for that one UPDATE and
  --     then dropped: is_account_member() then sees auth.uid() = NULL and the
  --     following calls are automation. Every write below prints the 096
  --     suppression WARNING if it fires.
  --     v_conv already carries exactly one open operation, created by the
  --     node-contract call above; no second one is needed (and a second
  --     would make the delivery_method read below ambiguous).
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations
     SET admin_locked_fields = coalesce(admin_locked_fields, '{}'::jsonb) || '{"delivery_method":true}'::jsonb,
         delivery_method = 'tropical'
   WHERE conversation_id = v_conv;
  v_before := (SELECT delivery_method FROM remittance_operations WHERE conversation_id = v_conv);

  PERFORM set_config('request.jwt.claims', '', true);
  FOR v_r IN SELECT * FROM cerebro_marcar_destino_usd(v_conv, 'clasica', 'e-157-lock') LOOP
    RAISE NOTICE 'LOCK (automation) node-contract fn -> accion=%', v_r.accion;
  END LOOP;
  v_after := (SELECT delivery_method FROM remittance_operations WHERE conversation_id = v_conv);
  RAISE NOTICE 'LOCK (automation) after node-contract fn: delivery_method % -> % (unchanged=%)',
    v_before, v_after, (v_before = v_after);

  RAISE NOTICE 'LOCK 157 registrar_destino -> %', cerebro_registrar_destino(v_conv, 'clasica');
  RAISE NOTICE 'LOCK 157 after: delivery_method=%',
    (SELECT delivery_method FROM remittance_operations WHERE conversation_id = v_conv);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
END $do$;


-- ---- cerebro_aplicar_reparto (127/129/130): why it was not reused -----
DO $do$
DECLARE
  v_owner   uuid := gen_random_uuid();
  v_account uuid;
  v_contact uuid;
  v_conv    uuid;
  v_op      uuid;
  v_hash    CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_res     jsonb;
  v_rows    jsonb;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'wu4c-127-' || v_owner || '@test.invalid', v_hash, now(), now(), now(),
          '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id)
  VALUES (gen_random_uuid(), 'WU4c 127 probe', v_owner) RETURNING id INTO v_account;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner, '1666' || lpad((980 + (random()*9)::int)::text, 7, '0'),
          'WU4c 127', v_account) RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner, v_contact, v_account) RETURNING id INTO v_conv;

  v_op := cerebro_crear_operacion(v_conv, 40000, 'GYD');

  BEGIN
    v_res := cerebro_aplicar_reparto(v_op, jsonb_build_array(
      jsonb_build_object('tipo','cuban_card','cuenta','1234567890123456','celular','51234567','monto',25000,'moneda','CUP'),
      jsonb_build_object('tipo','cuban_card','cuenta','6543210987654321','celular','58765432','monto',15000,'moneda','CUP')));
    RAISE NOTICE '127 apply -> %', v_res;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '127 apply RAISED % : %', SQLSTATE, SQLERRM;
  END;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'tipo', b.beneficiary_type, 'source', b.source, 'origin', b.amount_origin,
           'currency', b.currency) ORDER BY b.position), '[]'::jsonb)
    INTO v_rows
    FROM remittance_beneficiaries b WHERE b.operation_id = v_op;
  RAISE NOTICE '127 rows after -> %', v_rows;

  -- The same reparto through the node-contract function, for contrast.
  PERFORM cerebro_registrar_reparto_multiple(v_conv,
    '1234567890123456','51234567','25000','6543210987654321','58765432','15000','','','','e-127-contrast');
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'tipo', b.beneficiary_type, 'source', b.source, 'origin', b.amount_origin,
           'currency', b.currency) ORDER BY b.position), '[]'::jsonb)
    INTO v_rows
    FROM remittance_beneficiaries b WHERE b.operation_id = v_op;
  RAISE NOTICE '163 rows (same data, node contract) -> %', v_rows;
END $do$;


-- =====================================================================
-- NEGATIVE CONTROL — the harness must reject a wrong accion
-- =====================================================================
DO $do$
DECLARE
  v_owner   uuid := gen_random_uuid();
  v_account uuid;
  v_hash    CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  n6 text := $q$
WITH res AS (SELECT * FROM cerebro_resolver_operacion($1::uuid, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])),
idem AS (SELECT $3 || ':marcar_destino_usd:' || md5(coalesce($2,'')) AS k),
reg AS (
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT (SELECT k FROM idem), 'marcar_destino_usd', $3, $1::uuid,
         (SELECT operation_id FROM res), jsonb_build_array(to_jsonb($2::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id
),
conv AS (SELECT v.id AS cid, v.contact_id, v.account_id, v.user_id, c.phone FROM conversations v JOIN contacts c ON c.id=v.contact_id WHERE v.id=$1::uuid),
tipo AS (SELECT CASE WHEN lower($2) LIKE 'trop%' THEN 'Tropical'
                     WHEN lower($2) LIKE 'cl%'   THEN 'Clasica'
                     WHEN lower($2) LIKE 'efec%' THEN 'Efectivo' END AS t),
abierto AS (SELECT d.id, (COALESCE(d.notes,'') LIKE '%ENTREGA EN USD: ' || (SELECT t FROM tipo) || '%') AS ya_marcado FROM deals d JOIN remittance_operations o ON o.deal_id = d.id WHERE o.id = (SELECT operation_id FROM res)),
falta AS (SELECT NULL::uuid AS id, 'ERROR: el tipo debe ser clasica, tropical o efectivo. No se marco nada.' AS accion WHERE (SELECT t FROM tipo) IS NULL),
upd AS (UPDATE deals SET notes = COALESCE(notes,'') || E'\n---\nENTREGA EN USD: ' || (SELECT t FROM tipo), updated_at = now() WHERE id = (SELECT id FROM abierto WHERE NOT ya_marcado) AND (SELECT t FROM tipo) IS NOT NULL RETURNING id, 'destino marcado: entrega en USD por ' || (SELECT t FROM tipo) AS accion),
ins AS (INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status) SELECT conv.user_id, conv.account_id, conv.contact_id, conv.cid, '78220927-0745-45a8-ba08-a1b33734dbf1','96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109','Remesa +' || conv.phone, 0, 'GYD', 'ENTREGA EN USD: ' || (SELECT t FROM tipo), 'open' FROM conv WHERE NOT EXISTS (SELECT 1 FROM abierto) AND (SELECT resultado FROM res) <> 'ambigua' AND (SELECT t FROM tipo) IS NOT NULL RETURNING id, 'envio nuevo creado, entrega en USD por ' || (SELECT t FROM tipo) AS accion),
sin_cambio AS (SELECT id, 'sin cambios: ese destino ya estaba marcado' AS accion FROM abierto WHERE ya_marcado),
ambiguo AS (SELECT NULL::uuid AS id, 'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.' AS accion FROM cerebro_registrar_derivacion($1::uuid, 'Hay varias operaciones abiertas y el caso requiere revisión humana.', 'operacion_ambigua', (SELECT resultado FROM res) = 'ambigua') d)
SELECT * FROM falta UNION ALL SELECT * FROM upd UNION ALL SELECT * FROM ins UNION ALL SELECT * FROM sin_cambio UNION ALL SELECT * FROM ambiguo;
$q$;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'wu4c-nc-' || v_owner || '@test.invalid', v_hash, now(), now(), now(),
          '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id)
  VALUES (gen_random_uuid(), 'WU4c negative control', v_owner) RETURNING id INTO v_account;

  BEGIN
    PERFORM pg_temp.wu4c_case('marcar', 'NEGATIVE_CONTROL_falta', '', '', n6, '', '',
      v_account, v_owner, 9999, ARRAY['tarjeta', 'e-nc-1'], false, false, true);
    RAISE EXCEPTION 'NEGATIVE CONTROL FAILED: the harness accepted a stubbed accion';
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE 'FAIL%' THEN
      RAISE NOTICE 'NEGATIVE CONTROL OK: the harness rejected the stubbed accion -> %', SQLERRM;
    ELSE
      RAISE;
    END IF;
  END;
END $do$;

ROLLBACK TO SAVEPOINT wu4c_parity;
