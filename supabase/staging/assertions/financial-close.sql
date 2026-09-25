-- =====================================================================
-- Assertions for 121 crm_cierre_financiero (financial close on /resumen).
--
-- RUN ONLY INSIDE A TRANSACTION THAT IS ROLLED BACK: it inserts fixture
-- operations and ledger rows. Every check RAISEs on mismatch, so a
-- failure stops the script with the reason.
--
-- Fixture range: 2026-08-03 (Mon) .. 2026-08-09 (Sun), Guyana days —
-- a week with no real staging data.
--   e1 CUP   completed 2026-08-04 15:00Z (11:00 GY)          1000 / 700 / 300
--   e2 ZELLE completed 2026-08-05 00:30Z (08-04 20:30 GY)    2000 / 1500 / 500  <- counts on 08-04
--   e3 CUP   void      2026-08-06 15:00Z                      999 (never in totals)
--   e4 CUP   verified_pending, no completed_at, entry_date 2026-08-07 <- day 08-07
--   e5 CUP   completed 2026-08-10 15:00Z                      outside the range
--   e6 CUP   completed 2026-08-04 15:00Z, OTHER account       invisible to the member
--   e7 CUP   completed 2026-08-10 03:30Z (08-09 23:30 GY)    500 / 400 / 100   <- counts on 08-09
-- Expected totals: 3 operations, 3500 / 2600 / 900.
-- =====================================================================

CREATE TEMP TABLE fc_ops (tag text PRIMARY KEY, id uuid, account_id uuid) ON COMMIT DROP;

-- The tag rides on quoted_source_amount (1001..1007 -> e1..e7) so each
-- fixture operation is identified deterministically, not by insert order.
-- conversation_id is NOT NULL; staging's only conversation hosts every fixture
-- (the ledger scoping under test is by the entry's account_id, not the chat).
INSERT INTO remittance_operations (status, account_id, conversation_id, service_type, source_country,
       source_currency, destination_currency, delivery_method, quoted_source_amount)
SELECT 'collecting_information', a, '5f69dde1-7b2f-4620-9034-e79d01cbde62', 'remesa', 'GY', 'GYD', 'CUP', 'cuban_card', 1000 + n
  FROM (VALUES (1, '472917ed-fca5-4679-b64c-e76a54089a16'::uuid),
               (2, '472917ed-fca5-4679-b64c-e76a54089a16'),
               (3, '472917ed-fca5-4679-b64c-e76a54089a16'),
               (4, '472917ed-fca5-4679-b64c-e76a54089a16'),
               (5, '472917ed-fca5-4679-b64c-e76a54089a16'),
               (6, 'e736f834-18ab-444e-bea2-3e57f5fd4d7d'),
               (7, '472917ed-fca5-4679-b64c-e76a54089a16')) v(n, a);

INSERT INTO fc_ops (tag, id, account_id)
SELECT 'e' || (quoted_source_amount - 1000)::int, id, account_id
  FROM remittance_operations
 WHERE quoted_source_amount BETWEEN 1001 AND 1007
   AND created_at = now();  -- only this transaction's rows

DO $$
BEGIN
  IF (SELECT count(*) FROM fc_ops) <> 7 THEN
    RAISE EXCEPTION 'fixture: expected 7 operations, got %', (SELECT count(*) FROM fc_ops);
  END IF;
  IF (SELECT account_id FROM fc_ops WHERE tag = 'e6') <> 'e736f834-18ab-444e-bea2-3e57f5fd4d7d' THEN
    RAISE EXCEPTION 'fixture: e6 is not the other-account operation';
  END IF;
END $$;

INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date,
       customer_name, service, amount, amount_currency, facturado_gyd, invertido_gyd, retorno_gyd,
       completed_at, voided_at, void_reason, missing_inputs, delivery_mode, actor_user_id)
SELECT o.account_id, 'completed_operation', f.status, o.id, f.entry_date,
       'FC ' || f.tag, f.service, f.amount, 'CUP', f.fact, f.inv, f.ret,
       f.completed_at, f.voided_at, f.void_reason, f.missing, f.mode, f.actor
  FROM fc_ops o
  JOIN (VALUES
    ('e1', 'completed',        '2026-08-04'::date, 'CUP',   3000, 1000, 700,  300,  '2026-08-04 15:00Z'::timestamptz, NULL::timestamptz, NULL, NULL::text[], 'proof_sent', 'feeccc91-5c2d-446e-8366-21e97ceeb23f'::uuid),
    ('e2', 'completed',        '2026-08-05',       'ZELLE', 20,   2000, 1500, 500,  '2026-08-05 00:30Z',              NULL,              NULL, NULL,         'no_proof',   NULL),
    ('e3', 'void',             '2026-08-06',       'CUP',   2997, 999,  600,  399,  '2026-08-06 15:00Z',              '2026-08-06 16:00Z', 'fixture void', NULL,   'proof_sent', NULL),
    ('e4', 'verified_pending', '2026-08-07',       'CUP',   1000, NULL, NULL, NULL, NULL,                             NULL,              NULL, ARRAY['cup_rate'], NULL,     NULL),
    ('e5', 'completed',        '2026-08-10',       'CUP',   3000, 7000, 1,    6999, '2026-08-10 15:00Z',              NULL,              NULL, NULL,         'skip_proof', NULL),
    ('e6', 'completed',        '2026-08-04',       'CUP',   3000, 8000, 1,    7999, '2026-08-04 15:00Z',              NULL,              NULL, NULL,         'proof_sent', NULL),
    ('e7', 'completed',        '2026-08-10',       'CUP',   1500, 500,  400,  100,  '2026-08-10 03:30Z',              NULL,              NULL, NULL,         'skip_proof', NULL)
  ) f(tag, status, entry_date, service, amount, fact, inv, ret, completed_at, voided_at, void_reason, missing, mode, actor)
    ON f.tag = o.tag;

-- ---------------------------------------------------------------------
-- Call as the account member (viewer or above), then as a non-member.
-- ---------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"feeccc91-5c2d-446e-8366-21e97ceeb23f","role":"authenticated"}', true);
SELECT set_config('fc.week', public.crm_cierre_financiero('2026-08-03', '2026-08-09')::text, true);
SELECT set_config('fc.day',  public.crm_cierre_financiero('2026-08-04', '2026-08-04')::text, true);
SELECT set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SELECT set_config('fc.stranger', public.crm_cierre_financiero('2026-08-03', '2026-08-09')::text, true);
RESET ROLE;

DO $$
DECLARE
  w jsonb := current_setting('fc.week')::jsonb;
  d jsonb := current_setting('fc.day')::jsonb;
  s jsonb := current_setting('fc.stranger')::jsonb;
  v_pending jsonb;
BEGIN
  -- Totals: e1 + e2 + e7 only.
  IF (w->'totales') <> '{"operaciones": 3, "facturado_gyd": 3500, "invertido_gyd": 2600, "retorno_gyd": 900}'::jsonb THEN
    RAISE EXCEPTION 'totales: got %', w->'totales';
  END IF;

  -- Per service, facturado desc: ZELLE 2000 then CUP 1500 (e1 + e7).
  IF jsonb_array_length(w->'por_servicio') <> 2
     OR w->'por_servicio'->0->>'service' <> 'ZELLE'
     OR (w->'por_servicio'->0->>'facturado_gyd')::numeric <> 2000
     OR w->'por_servicio'->1->>'service' <> 'CUP'
     OR (w->'por_servicio'->1->>'operaciones')::int <> 2
     OR (w->'por_servicio'->1->>'facturado_gyd')::numeric <> 1500 THEN
    RAISE EXCEPTION 'por_servicio: got %', w->'por_servicio';
  END IF;

  -- Per day: 7 rows, gaps zeroed, the 20:30 GY entry on 08-04, the 23:30 GY on 08-09.
  IF jsonb_array_length(w->'por_dia') <> 7 THEN
    RAISE EXCEPTION 'por_dia: expected 7 days, got %', jsonb_array_length(w->'por_dia');
  END IF;
  IF w->'por_dia'->0->>'dia' <> '2026-08-03' OR (w->'por_dia'->0->>'operaciones')::int <> 0 THEN
    RAISE EXCEPTION 'por_dia[0]: got %', w->'por_dia'->0;
  END IF;
  IF w->'por_dia'->1->>'dia' <> '2026-08-04' OR (w->'por_dia'->1->>'operaciones')::int <> 2
     OR (w->'por_dia'->1->>'facturado_gyd')::numeric <> 3000 THEN
    RAISE EXCEPTION 'por_dia 08-04 (20:30 GY must count here): got %', w->'por_dia'->1;
  END IF;
  IF w->'por_dia'->6->>'dia' <> '2026-08-09' OR (w->'por_dia'->6->>'facturado_gyd')::numeric <> 500 THEN
    RAISE EXCEPTION 'por_dia 08-09 (23:30 GY must count here): got %', w->'por_dia'->6;
  END IF;

  -- Detail: the 3 completed entries, in completion order, with the actor name resolved.
  IF jsonb_array_length(w->'detalle') <> 3
     OR w->'detalle'->0->>'customer_name' <> 'FC e1'
     OR w->'detalle'->1->>'customer_name' <> 'FC e2'
     OR w->'detalle'->2->>'customer_name' <> 'FC e7' THEN
    RAISE EXCEPTION 'detalle: got %', w->'detalle';
  END IF;
  IF w->'detalle'->0->>'actor_name' IS NULL THEN
    RAISE EXCEPTION 'detalle: actor_name not resolved for a known user';
  END IF;
  IF w->'detalle'->1->'actor_name' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'detalle: actor_name must be null without an actor, got %', w->'detalle'->1->'actor_name';
  END IF;

  -- Excluded: the void and the pending entry, never in totals.
  IF jsonb_array_length(w->'excluidas') <> 2 THEN
    RAISE EXCEPTION 'excluidas: expected 2, got %', w->'excluidas';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(w->'excluidas') x
                  WHERE x->>'status' = 'void' AND x->>'void_reason' = 'fixture void') THEN
    RAISE EXCEPTION 'excluidas: void entry missing, got %', w->'excluidas';
  END IF;
  SELECT x INTO v_pending FROM jsonb_array_elements(w->'excluidas') x
   WHERE x->>'status' = 'verified_pending';
  IF v_pending IS NULL THEN
    RAISE EXCEPTION 'excluidas: pending entry missing, got %', w->'excluidas';
  END IF;
  -- A pending row without completed_at keeps its own entry_date as its day.
  IF v_pending->>'dia' <> '2026-08-07' THEN
    RAISE EXCEPTION 'excluidas: pending entry must stay on its entry_date 2026-08-07, got %', v_pending->>'dia';
  END IF;

  -- One-day range.
  IF (d->'totales'->>'operaciones')::int <> 2 OR (d->'totales'->>'facturado_gyd')::numeric <> 3000
     OR jsonb_array_length(d->'por_dia') <> 1 THEN
    RAISE EXCEPTION 'single day 08-04: got %', d;
  END IF;

  -- A non-member sees nothing: zero totals, empty lists, but still every day.
  IF (s->'totales') <> '{"operaciones": 0, "facturado_gyd": 0, "invertido_gyd": 0, "retorno_gyd": 0}'::jsonb
     OR s->'detalle' <> '[]'::jsonb OR s->'excluidas' <> '[]'::jsonb OR s->'por_servicio' <> '[]'::jsonb
     OR jsonb_array_length(s->'por_dia') <> 7 THEN
    RAISE EXCEPTION 'non-member must see nothing: got %', s;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Validation: 22023 for missing bounds, reversed bounds, > 366 days.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_cases text[][] := ARRAY[
    ARRAY[NULL, '2026-08-09'],
    ARRAY['2026-08-10', '2026-08-09'],
    ARRAY['2025-08-01', '2026-08-03']
  ];
  i int;
BEGIN
  FOR i IN 1 .. array_length(v_cases, 1) LOOP
    BEGIN
      PERFORM public.crm_cierre_financiero(v_cases[i][1]::date, v_cases[i][2]::date);
      RAISE EXCEPTION 'validation case % did not raise', i USING ERRCODE = 'P0001';
    EXCEPTION
      WHEN invalid_parameter_value THEN NULL;  -- 22023, expected
    END;
  END LOOP;
  -- 366 days exactly is allowed.
  PERFORM public.crm_cierre_financiero('2025-08-03', '2026-08-03');
END $$;

SELECT 'financial-close assertions: ALL PASSED' AS result;
