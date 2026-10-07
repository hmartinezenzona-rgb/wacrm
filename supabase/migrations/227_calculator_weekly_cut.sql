-- =====================================================================
-- 227 -- "Limpiar todo" as a weekly cut that archives the week and keeps the history (staging first)
--
-- odd/tasks/calculator-delete-and-weekly-clear.md (T2). Owner request (2026-10-07): at the end of the week Osmany clears
-- the Calculator to start clean, but the history must stay: everything cleared keeps counting in Finanzas, the dashboard
-- and the closes, and the cleared week can be opened again, read-only. Until now "Limpiar Todo" only emptied the manual
-- text on the client (the text was lost) and chat entries were never cleared.
--   * remittance_calculator_weeks: one archived week per cut -- cut_at, cut_by, the manual text and period label the
--     client held, the manual totals the client computed (manual lines are parsed on the client and cannot be recomputed
--     here, so they are stored as sent), the chat totals computed HERE from the entries shown (completed, not void,
--     not already archived: count, facturado, invertido, retorno) and a snapshot of those entries (id, operation_id,
--     service, customer, amount, currency, date, the three figures). RLS: any account member reads; clients cannot
--     write (the RPC is the only writer); anon has nothing.
--   * remittance_calculator_week_entries (entry_id PK, week_id, account_id): which entries each week archived. It is what
--     the Calculator view subtracts. The entries table is NOT touched (completed rows are append-only, 104/149), so
--     Finanzas, the dashboard and every close read exactly the same rows before and after a cut.
--   * calculator_current_entries (view, security_invoker): the chat entries of the Calculator = source
--     completed_operation, not void, not archived. A verified_pending line is never archived (it still needs a price),
--     so it stays visible whatever its age, and a pending line resolved after a cut stays in the new week. An entry
--     completed after the cut is not archived either, so it shows. The Calculator reads this view; history readers keep
--     reading the table.
--   * crm_cerrar_semana_calculadora(p_account_id, p_raw_text, p_period_label, p_manual_facturado, p_manual_invertido,
--     p_manual_retorno): agent+ (the role that can save the document today, crm_guardar_documento_calculadora); archives
--     the week, records the cut, empties the document (raw_text and period_label to ''). The text and the manual totals
--     come from the client because the autosave can lag the textarea; two cuts in a row work (the second archive holds
--     only what came after the first). One cut at a time per account (advisory lock). Not audited beyond the week row
--     itself (cut_by, cut_at).
--   The legacy crm_limpiar_calculadora(uuid) and remittance_calculator_clearances (not created by any migration in this
--   repository, never called by the app) are left as they are: a new name avoids overloading the old RPC.
-- Guarded by supabase/staging/assertions/calculator-weekly-cut.sql. ROLLBACK: ROLLBACK-227-calculator-weekly-cut.sql
-- =====================================================================

CREATE TABLE remittance_calculator_weeks (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id      uuid NOT NULL REFERENCES accounts(id),
  cut_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  cut_by          uuid REFERENCES auth.users(id),
  raw_text        text NOT NULL DEFAULT '',
  period_label    text NOT NULL DEFAULT '',
  manual_totals   jsonb NOT NULL,
  chat_totals     jsonb NOT NULL,
  entries         jsonb NOT NULL DEFAULT '[]'::jsonb,
  CONSTRAINT remittance_calculator_weeks_entries_array_chk CHECK (jsonb_typeof(entries) = 'array')
);
CREATE INDEX remittance_calculator_weeks_account_cut_idx ON remittance_calculator_weeks (account_id, cut_at DESC);

CREATE TABLE remittance_calculator_week_entries (
  entry_id    uuid PRIMARY KEY REFERENCES remittance_calculator_entries(id),
  week_id     uuid NOT NULL REFERENCES remittance_calculator_weeks(id) ON DELETE CASCADE,
  account_id  uuid NOT NULL REFERENCES accounts(id)
);
CREATE INDEX remittance_calculator_week_entries_week_idx ON remittance_calculator_week_entries (week_id);

ALTER TABLE remittance_calculator_weeks ENABLE ROW LEVEL SECURITY;
ALTER TABLE remittance_calculator_week_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY remittance_calculator_weeks_select ON remittance_calculator_weeks
  FOR SELECT TO authenticated USING (is_account_member(account_id));
CREATE POLICY remittance_calculator_week_entries_select ON remittance_calculator_week_entries
  FOR SELECT TO authenticated USING (is_account_member(account_id));

REVOKE ALL ON remittance_calculator_weeks, remittance_calculator_week_entries FROM PUBLIC, anon, authenticated;
GRANT SELECT ON remittance_calculator_weeks, remittance_calculator_week_entries TO authenticated;
GRANT ALL ON remittance_calculator_weeks, remittance_calculator_week_entries TO service_role;

CREATE VIEW public.calculator_current_entries WITH (security_invoker = true) AS
 SELECT e.*
   FROM remittance_calculator_entries e
  WHERE e.source = 'completed_operation'
    AND e.status <> 'void'
    AND NOT EXISTS (SELECT 1 FROM remittance_calculator_week_entries we WHERE we.entry_id = e.id);

REVOKE ALL ON public.calculator_current_entries FROM PUBLIC, anon;
GRANT SELECT ON public.calculator_current_entries TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.crm_cerrar_semana_calculadora(
  p_account_id        uuid,
  p_raw_text          text,
  p_period_label      text,
  p_manual_facturado  numeric,
  p_manual_invertido  numeric,
  p_manual_retorno    numeric
) RETURNS remittance_calculator_weeks
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_week    remittance_calculator_weeks;
  v_ids     uuid[];
  v_entries jsonb;
  v_totals  jsonb;
BEGIN
  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT is_account_member(p_account_id, 'agent') THEN
    RAISE EXCEPTION 'not authorized to clear the calculator' USING ERRCODE = '42501';
  END IF;

  IF p_raw_text IS NULL OR p_period_label IS NULL THEN
    RAISE EXCEPTION 'raw_text and period_label are required' USING ERRCODE = '22023';
  END IF;

  IF p_manual_facturado IS NULL OR p_manual_invertido IS NULL OR p_manual_retorno IS NULL
     OR abs(p_manual_facturado) >= 1e15 OR abs(p_manual_invertido) >= 1e15 OR abs(p_manual_retorno) >= 1e15 THEN
    RAISE EXCEPTION 'the manual totals are required and must be below 1e15' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('calculator-cut:' || p_account_id::text, 0));

  -- The entries shown: completed, not void, not archived by an earlier cut. A pending line is never archived.
  SELECT coalesce(array_agg(c.id ORDER BY c.entry_date, c.created_at, c.id), ARRAY[]::uuid[]),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'operation_id', c.operation_id, 'service', c.service, 'customer_name', c.customer_name,
           'amount', c.amount, 'amount_currency', c.amount_currency, 'entry_date', c.entry_date,
           'facturado_gyd', c.facturado_gyd, 'invertido_gyd', c.invertido_gyd, 'retorno_gyd', c.retorno_gyd)
           ORDER BY c.entry_date, c.created_at, c.id), '[]'::jsonb),
         jsonb_build_object('count', count(*),
                            'facturado_gyd', coalesce(sum(c.facturado_gyd), 0),
                            'invertido_gyd', coalesce(sum(c.invertido_gyd), 0),
                            'retorno_gyd',   coalesce(sum(c.retorno_gyd), 0))
    INTO v_ids, v_entries, v_totals
    FROM calculator_current_entries c
   WHERE c.account_id = p_account_id AND c.status = 'completed';

  INSERT INTO remittance_calculator_weeks (account_id, cut_by, raw_text, period_label, manual_totals, chat_totals, entries)
  VALUES (p_account_id, auth.uid(), p_raw_text, p_period_label,
          jsonb_build_object('facturado_gyd', p_manual_facturado, 'invertido_gyd', p_manual_invertido, 'retorno_gyd', p_manual_retorno),
          v_totals, v_entries)
  RETURNING * INTO v_week;

  INSERT INTO remittance_calculator_week_entries (entry_id, week_id, account_id)
  SELECT id, v_week.id, p_account_id FROM unnest(v_ids) AS id;

  INSERT INTO remittance_calculator_documents (account_id, raw_text, period_label, updated_by, updated_at)
  VALUES (p_account_id, '', '', auth.uid(), clock_timestamp())
  ON CONFLICT (account_id) DO UPDATE
    SET raw_text     = '',
        period_label = '',
        updated_by   = EXCLUDED.updated_by,
        updated_at   = EXCLUDED.updated_at;

  RETURN v_week;
END;
$function$;

REVOKE ALL ON FUNCTION public.crm_cerrar_semana_calculadora(uuid, text, text, numeric, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_cerrar_semana_calculadora(uuid, text, text, numeric, numeric, numeric) TO authenticated;

COMMENT ON FUNCTION public.crm_cerrar_semana_calculadora(uuid, text, text, numeric, numeric, numeric) IS
  'Agent+ only. Weekly cut of the Calculator: archives the manual text, period and totals sent by the client plus the chat '
  'entries shown (totals computed here), records the cut and empties the manual document. The entries table is untouched, '
  'so history readers (Finanzas, dashboard, closes) are unchanged.';
