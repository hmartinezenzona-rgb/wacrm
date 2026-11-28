-- =====================================================================
-- Assertions for 234 cerebro_dashboard_resumen (the Finanzas "Resumen" cards) coming from the calculator ledger.
--
-- RUN ONLY INSIDE A TRANSACTION THAT IS ROLLED BACK: it inserts fixture operations and ledger rows and leaves nothing.
--   BEGIN; <this file>; ROLLBACK;     (never `psql -1` alone: it can COMMIT the fixture)
-- Every check RAISEs on mismatch, so a failure stops the script with the reason.
--
-- Fixture (account A = staging's account, member feeccc91...; account B = the other staging account), dated by Guyana days relative to today:
--   b1 bot  completed  today              1,000      counted
--   b2 bot  completed  yesterday          2,000      counted
--   b3 bot  completed  Monday of the week 4,000      counted
--   b4 bot  completed  the 15th of last month 8,000  counted
--   m1 manual completed today            16,000      counted (manual entries are included)
--   m2 manual completed yesterday        32,000      counted
--   v1 bot  void       today             64,000      never counted
--   d1 manual void + deleted_at today   100,000      never counted
--   p1 bot  verified_pending today (no figures)      never counted
--   o1 bot  completed  today, ACCOUNT B 256,000      never visible to the member
-- Expected per period = what the fixture adds on top of the baseline read before inserting it, and the card ALWAYS equals
-- crm_cierre_financiero over the same dates (operations and facturado).
-- =====================================================================

CREATE TEMP TABLE rl_ops (tag text PRIMARY KEY, id uuid, account_id uuid) ON COMMIT DROP;
CREATE TEMP TABLE rl_fx (tag text PRIMARY KEY, dia date, fact numeric, counted boolean) ON COMMIT DROP;

-- Baseline: the five cards as the member sees them before the fixture exists.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"feeccc91-5c2d-446e-8366-21e97ceeb23f","role":"authenticated"}', true);
SELECT set_config('rl.base', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.orden)::text FROM public.cerebro_dashboard_resumen() r), '[]'), true);
RESET ROLE;

INSERT INTO remittance_operations (status, account_id, conversation_id, service_type, source_country,
       source_currency, destination_currency, delivery_method, quoted_source_amount)
SELECT 'collecting_information', v.a, '5f69dde1-7b2f-4620-9034-e79d01cbde62', 'remesa', 'GY', 'GYD', 'CUP', 'cuban_card', 7000 + v.n
  FROM (VALUES (1, '472917ed-fca5-4679-b64c-e76a54089a16'::uuid), (2, '472917ed-fca5-4679-b64c-e76a54089a16'),
               (3, '472917ed-fca5-4679-b64c-e76a54089a16'), (4, '472917ed-fca5-4679-b64c-e76a54089a16'),
               (5, '472917ed-fca5-4679-b64c-e76a54089a16'), (6, '472917ed-fca5-4679-b64c-e76a54089a16'),
               (7, 'e736f834-18ab-444e-bea2-3e57f5fd4d7d')) v(n, a);

-- tags ride on quoted_source_amount 7001..7007: b1 b2 b3 b4 v1 p1 o1
INSERT INTO rl_ops (tag, id, account_id)
SELECT (ARRAY['b1','b2','b3','b4','v1','p1','o1'])[(quoted_source_amount - 7000)::int], id, account_id
  FROM remittance_operations
 WHERE quoted_source_amount BETWEEN 7001 AND 7007 AND created_at = now();

DO $$
BEGIN
  IF (SELECT count(*) FROM rl_ops) <> 7 THEN
    RAISE EXCEPTION 'fixture: expected 7 operations, got %', (SELECT count(*) FROM rl_ops);
  END IF;
END $$;

-- The fixture days (Guyana) and what each row is worth.
INSERT INTO rl_fx (tag, dia, fact, counted)
SELECT f.tag, f.dia, f.fact, f.counted
  FROM (SELECT (now() AT TIME ZONE 'America/Guyana')::date AS t) h,
       LATERAL (VALUES
         ('b1', h.t,                                                        1000::numeric,   true),
         ('b2', h.t - 1,                                                    2000,            true),
         ('b3', date_trunc('week', h.t)::date,                              4000,            true),
         ('b4', (date_trunc('month', h.t) - interval '1 month')::date + 14, 8000,            true),
         ('m1', h.t,                                                        16000,           true),
         ('m2', h.t - 1,                                                    32000,           true),
         ('v1', h.t,                                                        64000,           false),
         ('d1', h.t,                                                        100000,          false),
         ('p1', h.t,                                                        NULL,            false),
         ('o1', h.t,                                                        256000,          false)) f(tag, dia, fact, counted);

-- Bot lines.
INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service,
       amount, amount_currency, facturado_gyd, invertido_gyd, retorno_gyd, completed_at, voided_at, void_reason, missing_inputs)
SELECT o.account_id, 'completed_operation',
       CASE o.tag WHEN 'v1' THEN 'void' WHEN 'p1' THEN 'verified_pending' ELSE 'completed' END,
       o.id, x.dia, 'RL ' || o.tag, 'CUP', 1000, 'CUP',
       CASE WHEN o.tag = 'p1' THEN NULL ELSE x.fact END,
       CASE WHEN o.tag = 'p1' THEN NULL ELSE x.fact * 0.7 END,
       CASE WHEN o.tag = 'p1' THEN NULL ELSE x.fact * 0.3 END,
       CASE WHEN o.tag = 'p1' THEN NULL ELSE ((x.dia + time '12:00') AT TIME ZONE 'America/Guyana') END,
       CASE WHEN o.tag = 'v1' THEN ((x.dia + time '13:00') AT TIME ZONE 'America/Guyana') END,
       CASE WHEN o.tag = 'v1' THEN 'fixture void' END,
       CASE WHEN o.tag = 'p1' THEN ARRAY['cup_rate'] END
  FROM rl_ops o JOIN rl_fx x ON x.tag = o.tag;

-- Manual lines (operation_id NULL), one of them voided AND deleted.
INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service,
       amount, amount_currency, facturado_gyd, invertido_gyd, retorno_gyd, completed_at, voided_at, void_reason, deleted_at, deleted_by)
SELECT '472917ed-fca5-4679-b64c-e76a54089a16', 'manual', CASE x.tag WHEN 'd1' THEN 'void' ELSE 'completed' END,
       NULL, x.dia, 'RL ' || x.tag, 'CUP', 1000, 'CUP', x.fact, x.fact * 0.7, x.fact * 0.3,
       ((x.dia + time '12:00') AT TIME ZONE 'America/Guyana'),
       CASE WHEN x.tag = 'd1' THEN ((x.dia + time '13:00') AT TIME ZONE 'America/Guyana') END,
       CASE WHEN x.tag = 'd1' THEN 'fixture deleted' END,
       CASE WHEN x.tag = 'd1' THEN ((x.dia + time '13:00') AT TIME ZONE 'America/Guyana') END,
       CASE WHEN x.tag = 'd1' THEN 'feeccc91-5c2d-446e-8366-21e97ceeb23f'::uuid END
  FROM rl_fx x WHERE x.tag IN ('m1', 'm2', 'd1');

-- Read as the member, as a stranger and with no identity at all.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"feeccc91-5c2d-446e-8366-21e97ceeb23f","role":"authenticated"}', true);
SELECT set_config('rl.after', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.orden)::text FROM public.cerebro_dashboard_resumen() r), true);
SELECT set_config('rl.close', (
  SELECT jsonb_agg(jsonb_build_object('orden', r.orden, 'totales', public.crm_cierre_financiero(r.desde, r.hasta)->'totales') ORDER BY r.orden)::text
    FROM public.cerebro_dashboard_resumen() r), true);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SELECT set_config('rl.stranger', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.orden)::text FROM public.cerebro_dashboard_resumen() r), true);
SELECT set_config('request.jwt.claims', '', true);
SELECT set_config('rl.noid', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.orden)::text FROM public.cerebro_dashboard_resumen() r), true);
RESET ROLE;

DO $$
DECLARE
  v_base   jsonb := current_setting('rl.base')::jsonb;
  v_after  jsonb := current_setting('rl.after')::jsonb;
  v_close  jsonb := current_setting('rl.close')::jsonb;
  v_str    jsonb := current_setting('rl.stranger')::jsonb;
  v_noid   jsonb := current_setting('rl.noid')::jsonb;
  v_t      date  := (now() AT TIME ZONE 'America/Guyana')::date;
  v_periods text[] := ARRAY['hoy', 'ayer', 'esta semana', 'este mes', 'mes pasado'];
  v_desde  date[] := ARRAY[v_t, v_t - 1, date_trunc('week', v_t)::date, date_trunc('month', v_t)::date,
                           (date_trunc('month', v_t) - interval '1 month')::date];
  v_hasta  date[] := ARRAY[v_t, v_t - 1, v_t, v_t, (date_trunc('month', v_t) - interval '1 day')::date];
  i int;
  v_ops_d numeric; v_fact_d numeric; a jsonb; b jsonb; c jsonb;
BEGIN
  IF jsonb_array_length(v_after) <> 5 THEN
    RAISE EXCEPTION 'the Resumen must keep returning five periods, got %', jsonb_array_length(v_after);
  END IF;
  FOR i IN 1 .. 5 LOOP
    a := v_after -> (i - 1);  b := v_base -> (i - 1);  c := v_close -> (i - 1);
    -- Same periods, same order, as before.
    IF (a->>'orden')::int <> i OR a->>'periodo' <> v_periods[i]
       OR (a->>'desde')::date <> v_desde[i] OR (a->>'hasta')::date <> v_hasta[i] THEN
      RAISE EXCEPTION 'period % changed shape: got %', i, a;
    END IF;
    -- The card equals the close over the same dates (operations and facturado) ...
    IF (a->>'operaciones')::numeric <> (c->'totales'->>'operaciones')::numeric
       OR (a->>'volumen_gyd')::numeric <> (c->'totales'->>'facturado_gyd')::numeric THEN
      RAISE EXCEPTION '% must equal the close: card % vs close %', v_periods[i], a, c->'totales';
    END IF;
    -- ... and the ticket is facturado / operaciones (NULL without operations).
    IF (a->>'operaciones')::numeric = 0 THEN
      IF a->'ticket_medio_gyd' <> 'null'::jsonb THEN RAISE EXCEPTION '% ticket must be NULL without operations: %', v_periods[i], a; END IF;
    ELSIF (a->>'ticket_medio_gyd')::numeric <> round((a->>'volumen_gyd')::numeric / (a->>'operaciones')::numeric) THEN
      RAISE EXCEPTION '% ticket must be round(facturado / operaciones): %', v_periods[i], a;
    END IF;
    -- The fixture adds exactly its counted visible rows (bot + manual in; void, deleted, pending and the other account out).
    SELECT count(*), coalesce(sum(fact), 0) INTO v_ops_d, v_fact_d
      FROM rl_fx WHERE counted AND dia BETWEEN v_desde[i] AND v_hasta[i];
    IF (a->>'operaciones')::numeric - (b->>'operaciones')::numeric <> v_ops_d
       OR (a->>'volumen_gyd')::numeric - (b->>'volumen_gyd')::numeric <> v_fact_d THEN
      RAISE EXCEPTION '% fixture delta: expected +% operations / +% GYD, got % -> %', v_periods[i], v_ops_d, v_fact_d, b, a;
    END IF;
  END LOOP;

  -- Sanity of the oracle itself: the fixture does reach the cards that matter (manual and bot both).
  IF (SELECT count(*) FROM rl_fx WHERE counted AND dia = v_t) < 2 THEN
    RAISE EXCEPTION 'fixture: expected a bot and a manual entry today';
  END IF;

  -- Someone who is not a member of the account sees nothing; so does a request without identity (the close's own behaviour).
  FOR i IN 0 .. 4 LOOP
    IF (v_str->i->>'operaciones')::numeric <> 0 OR (v_str->i->>'volumen_gyd')::numeric <> 0
       OR v_str->i->'ticket_medio_gyd' <> 'null'::jsonb THEN
      RAISE EXCEPTION 'a stranger must see zeros, got %', v_str->i;
    END IF;
    IF (v_noid->i->>'operaciones')::numeric <> 0 OR (v_noid->i->>'volumen_gyd')::numeric <> 0
       OR v_noid->i->'ticket_medio_gyd' <> 'null'::jsonb THEN
      RAISE EXCEPTION 'no identity must see zeros, got %', v_noid->i;
    END IF;
  END LOOP;
END $$;

-- The dashboard widgets keep reading the operations views: the views are untouched and still count the OPERATIONS
-- (the fixture operations are not completed, so the proof is the view definition, not a number).
DO $$
BEGIN
  IF pg_get_viewdef('public.cerebro_volumen_diario'::regclass) NOT LIKE '%remittance_operations%' THEN
    RAISE EXCEPTION 'cerebro_volumen_diario must keep reading remittance_operations';
  END IF;
  IF pg_get_viewdef('public.cerebro_resumen_volumen'::regclass) NOT LIKE '%cerebro_volumen_diario%' THEN
    RAISE EXCEPTION 'cerebro_resumen_volumen must keep reading cerebro_volumen_diario';
  END IF;
END $$;

-- Grants unchanged: authenticated and service_role may execute, anon and PUBLIC may not.
DO $$
BEGIN
  IF NOT has_function_privilege('authenticated', 'public.cerebro_dashboard_resumen()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_dashboard_resumen()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_dashboard_resumen()', 'EXECUTE') THEN
    RAISE EXCEPTION 'cerebro_dashboard_resumen grants changed';
  END IF;
END $$;

SELECT 'resumen-from-ledger assertions: ALL PASSED' AS result;
