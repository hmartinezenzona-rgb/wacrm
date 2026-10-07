-- =====================================================================
-- 226 -- Delete a calculator entry (staging first)
--
-- odd/tasks/calculator-delete-and-weekly-clear.md (T1). Owner request (Osmany, 2026-10-07): "que se pueda eliminar una
-- entrada aunque ya este completada". An admin deletes a chat-fed entry, completed or verified_pending: it becomes a
-- DURABLE void -- status void, voided_at, void_reason 'deleted by <actor>', deleted_at and deleted_by -- figures
-- untouched (the append-only guard of 104/149 already allows completed -> void with the figures unchanged, so it is not
-- touched). A void row that came from a reverted operation (no deleted_at) is revived by the feed as before.
--   * remittance_calculator_entries.deleted_at / deleted_by (nullable; the marker of a deletion on purpose).
--   * crm_eliminar_entrada_calculadora(p_entry_id): admin+, SECURITY DEFINER; chat-fed entries in status completed or
--     verified_pending only (a void, an already deleted, a manual entry: 22023; another account's entry or no session:
--     42501; unknown id: P0002); one audit row (human_calculator_entry_deleted, new in the audit action CHECK, whose
--     vocabulary is carried forward from staging). The linked operation is not touched; nothing is sent.
--   * calculator_feed_operation: the upsert's revival condition (ON CONFLICT ... WHERE status = 'void') also requires
--     deleted_at IS NULL, so re-completion, crm_feed_calculator and the combo cost path never bring a deleted entry back.
--   * calculator_unfed_operations: a deleted entry counts as "fed" for its part, so the operation is not listed as
--     unfed because of a deletion on purpose.
-- Finanzas (crm_cierre_financiero), the dashboard and the Calculator already ignore void rows: a deleted entry stops
-- counting everywhere and the close lists it under "excluidas" with its reason. No undo in this step.
-- Pre-migration md5 on staging (2026-10-07): calculator_feed_operation 7f985d9d6adeaee998e3a246a530a5e8;
-- calculator_unfed_operations view (pg_get_viewdef) cd475518e23ac05d71659378d1ef33fe; audit action CHECK
-- (pg_get_constraintdef) 3da4b785eea18913c4bca6b65c9927bb.
-- Guarded by supabase/staging/assertions/calculator-entry-delete.sql. ROLLBACK: ROLLBACK-226-calculator-entry-delete.sql
-- =====================================================================

ALTER TABLE remittance_calculator_entries
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_by uuid;

ALTER TABLE remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit
  ADD CONSTRAINT remittance_admin_audit_action_chk
  CHECK (action IN (
    'automation_write_suppressed',
    'automation_completion_suppressed',
    'automation_revert_suppressed',
    'human_correction',
    'human_reassignment',
    'human_deposit_verification',
    'human_forced_verification',
    'human_delivery',
    'calculator_feed_failed',
    'calculator_pending_resolved',
    'human_beneficiary_added',
    'automation_reparto_registered',
    'human_calculator_correction',
    'automation_cash_delivery_data_registered',
    'automation_late_deposit_verification',
    'human_manual_close',
    'human_operation_deleted',
    'automation_recharge_numbers_registered',
    'automation_combo_recipient_registered',
    'human_combo_cost_set',
    'automation_visa_registered',
    'human_calculator_entry_deleted'
  ));

CREATE OR REPLACE FUNCTION public.crm_eliminar_entrada_calculadora(p_entry_id uuid)
 RETURNS remittance_calculator_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry  remittance_calculator_entries;
  v_before jsonb;
  v_actor  text;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to delete calculator entries' USING ERRCODE = '42501';
  END IF;

  IF v_entry.source <> 'completed_operation' THEN
    RAISE EXCEPTION 'only a chat-fed entry can be deleted here' USING ERRCODE = '22023';
  END IF;

  IF v_entry.status NOT IN ('completed', 'verified_pending') THEN
    RAISE EXCEPTION 'entry is % and cannot be deleted', v_entry.status USING ERRCODE = '22023';
  END IF;

  v_before := to_jsonb(v_entry);
  v_actor  := wacrm_current_actor();

  -- completed -> void keeps every figure (the append-only guard checks it); the deletion marker is not a figure.
  UPDATE remittance_calculator_entries
     SET status      = 'void',
         voided_at   = clock_timestamp(),
         void_reason = 'deleted by ' || coalesce(v_actor, 'unknown'),
         deleted_at  = clock_timestamp(),
         deleted_by  = auth.uid()
   WHERE id = p_entry_id
  RETURNING * INTO v_entry;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id, 'status,deleted_at',
          'human_calculator_entry_deleted', v_actor, v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$function$;

REVOKE ALL ON FUNCTION public.crm_eliminar_entrada_calculadora(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_eliminar_entrada_calculadora(uuid) TO authenticated;

COMMENT ON FUNCTION public.crm_eliminar_entrada_calculadora(uuid) IS
  'Admin+ only. Deletes a chat-fed calculator entry (completed or verified_pending) as a durable void: the feed never '
  'revives it. Figures untouched; one audit row (human_calculator_entry_deleted). The operation is not touched.';

CREATE OR REPLACE FUNCTION public.calculator_feed_operation(p_operation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op        remittance_operations;
  v_rates     calculator_rate_versions;
  v_sell      numeric;
  v_zrate     numeric;
  v_part      record;
  v_missing   text[];
  v_basis     numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_currency  text;
  v_customer  text;
  v_entry_id  uuid;
  v_first_id  uuid;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.status <> 'completed' THEN
    RETURN NULL;
  END IF;

  IF v_op.quoted_source_amount IS NULL OR v_op.quoted_source_amount <= 0 THEN
    RETURN NULL;
  END IF;

  v_rates := calculator_rates_vigentes(v_op.account_id);
  -- (215) The Zelle sale rate is the tier of the deposit's TOTAL (also for a part of a split deposit).
  SELECT z.tasa INTO v_zrate FROM cerebro_zelle_cotizar_op(v_op.id, v_op.quoted_source_amount) z;

  SELECT c.name INTO v_customer
    FROM conversations conv JOIN contacts c ON c.id = conv.contact_id
   WHERE conv.id = v_op.conversation_id;

  FOR v_part IN SELECT * FROM calculator_operation_parts(v_op, v_rates) LOOP
    v_basis     := v_part.basis;
    v_amount    := NULL;
    v_facturado := NULL;
    v_invertido := NULL;
    v_missing   := calculator_missing_rates(v_part.service, v_rates) || coalesce(v_part.missing, ARRAY[]::text[]);
    -- (199) a recharge whose deposit matches no recharge price cannot be priced
    IF v_part.service = 'RECARGA' AND cerebro_recarga_precio(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['recargaPrecioGyd'];
    END IF;
    -- (223) a mobile balance whose deposit is not a whole number of packages cannot be priced: no silent rounding
    IF v_part.service = 'SALDO_MOVIL' AND cerebro_saldo_paquetes(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['saldoPaquetes'];
    END IF;
    -- (209) a combo whose cost the admin has not entered yet stays pending
    IF v_part.service = 'COMBO' AND v_op.combo_costo_gyd IS NULL THEN
      v_missing := v_missing || ARRAY['comboCosto'];
    END IF;
    v_currency  := CASE WHEN v_part.service = 'CUP' THEN 'CUP' WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN 'REC'
                        WHEN v_part.service IN ('COMBO', 'VISA') THEN 'GYD' ELSE 'USD' END;
    -- (193) The sale rate of the line: a cash dollar sells at efectivo_usd_gyd; every other USD service at
    -- usdt_sell_gyd. The cost (usdt_buy_gyd) is shared. Snapshotted in usdt_sell_gyd (= the sale rate used).
    v_sell      := CASE WHEN v_part.service = 'EFECTIVO' THEN v_rates.efectivo_usd_gyd
                        -- (199) a recharge sells at the price its deposit pays (198 cerebro_recarga_precio)
                        WHEN v_part.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis)
                        -- (223) a mobile balance sells at the package price (cerebro_saldo_precio)
                        WHEN v_part.service = 'SALDO_MOVIL' THEN cerebro_saldo_precio()
                        -- (215) Zelle: tiered (still pending while the calculator has no sell rate); Clasica, Tropical and the rest keep usdt_sell_gyd
                        WHEN v_part.service = 'ZELLE' AND v_rates.usdt_sell_gyd IS NOT NULL THEN coalesce(v_zrate, v_rates.usdt_sell_gyd)
                        ELSE v_rates.usdt_sell_gyd END;

    IF v_part.service = 'COMBO' THEN
      -- (209) facturado = the verified deposit (GYD), invertido = the cost entered on the operation.
      IF v_basis IS NOT NULL AND v_basis > 0 AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_amount    := v_basis;
        v_facturado := v_basis;
        v_invertido := v_op.combo_costo_gyd;
      END IF;
    ELSIF v_part.service = 'VISA' THEN
      -- (213) facturado = the verified deposit (GYD), invertido = 0 (owner: all of it is profit). No rate, never pending.
      IF v_basis IS NOT NULL AND v_basis > 0 AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_amount    := v_basis;
        v_facturado := v_basis;
        v_invertido := 0;
      END IF;
    ELSIF v_basis IS NOT NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := calculator_amount_from_basis(v_part.service, v_basis, v_rates.cup_global_rate, v_sell);
      v_facturado := calculator_facturado(v_part.service, v_amount, v_rates.cup_global_rate, v_sell);
      v_invertido := CASE WHEN v_part.service = 'RECARGA'
                          -- (199) units x USDT cost per recharge x USDT buy rate (the guide's "rec promo" line)
                          THEN v_amount * v_rates.recarga_costo_usdt * v_rates.usdt_buy_gyd
                          -- (223) packages x USDT cost per package x USDT buy rate
                          WHEN v_part.service = 'SALDO_MOVIL' THEN v_amount * v_rates.saldo_costo_usdt * v_rates.usdt_buy_gyd
                          ELSE calculator_invertido(v_part.service, v_amount, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd) END;
    END IF;

    IF v_basis IS NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_missing := ARRAY['beneficiaryAmounts'];
    END IF;

    IF v_amount IS NULL OR v_amount <= 0 THEN
      v_amount := v_part.placeholder_amount;
      v_facturado := NULL;
      v_invertido := NULL;
      IF coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_missing := ARRAY['beneficiaryAmounts'];
      END IF;
    END IF;

    -- (223) The amount of a mobile balance line is the saldo itself (packages x saldo per package) in 'SM'; without an exact
    -- package count there is no saldo to show, so the raw deposit stays, labelled GYD (never SM). facturado/invertido
    -- above were already computed from the package count.
    IF v_part.service = 'SALDO_MOVIL' THEN
      IF cerebro_saldo_paquetes(v_basis) IS NOT NULL THEN
        v_amount   := cerebro_saldo_paquetes(v_basis) * cerebro_saldo_unidad();
        v_currency := 'SM';
      ELSE
        v_currency := 'GYD';
      END IF;
    END IF;

    -- (209) The cost of a combo is entered by hand and can change. Completed lines are append-only (149), so a live COMBO
    -- line whose figures differ is VOIDED here (figures untouched) and the upsert below revives that row with the new
    -- ones, the way a reverted-then-completed operation is re-fed. Identical figures: nothing is touched (idempotent).
    IF v_part.service = 'COMBO' THEN
      UPDATE remittance_calculator_entries e
         SET status = 'void', voided_at = clock_timestamp(), void_reason = 'combo cost or deposit changed; re-fed'
       WHERE e.account_id = v_op.account_id AND e.operation_id = v_op.id AND e.source = 'completed_operation'
         AND e.service = 'COMBO' AND e.status <> 'void'
         AND (e.status IS DISTINCT FROM CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END
              OR e.amount IS DISTINCT FROM v_amount OR e.facturado_gyd IS DISTINCT FROM v_facturado
              OR e.invertido_gyd IS DISTINCT FROM v_invertido OR e.basis_gyd IS DISTINCT FROM v_basis);
    END IF;

    INSERT INTO remittance_calculator_entries (
      account_id, source, status, operation_id, entry_date, customer_name,
      service, amount, amount_currency, basis_gyd,
      cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id,
      facturado_gyd, invertido_gyd, retorno_gyd,
      missing_inputs, delivery_mode, actor_user_id, completed_at, cost_gyd, sale_gyd
    ) VALUES (
      v_op.account_id, 'completed_operation',
      CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END,
      v_op.id, coalesce(v_op.completed_at, clock_timestamp())::date, v_customer,
      v_part.service, v_amount, v_currency, v_basis,
      -- (199) A RECARGA line reads like a manual "rec promo" one: cup_rate = USDT rate, cost_gyd = USDT cost, sale_gyd = price.
      -- (209) A COMBO line snapshots no rate (it does not depend on them). (213) Nor does a VISA line.
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_rates.cup_global_rate END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL
           WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN v_rates.usdt_buy_gyd ELSE v_rates.usdt_sell_cup END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_rates.usdt_buy_gyd END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_sell END, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp()),
      CASE WHEN v_part.service = 'RECARGA' THEN v_rates.recarga_costo_usdt
           WHEN v_part.service = 'SALDO_MOVIL' THEN v_rates.saldo_costo_usdt
           WHEN v_part.service = 'COMBO' THEN v_op.combo_costo_gyd
           WHEN v_part.service = 'VISA' THEN 0 END,
      CASE WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN v_sell
           WHEN v_part.service IN ('COMBO', 'VISA') THEN v_facturado END
    )
    ON CONFLICT (account_id, operation_id, service) WHERE source = 'completed_operation'
    DO UPDATE SET
      status          = EXCLUDED.status,
      entry_date      = EXCLUDED.entry_date,
      customer_name   = EXCLUDED.customer_name,
      amount          = EXCLUDED.amount,
      amount_currency = EXCLUDED.amount_currency,
      basis_gyd       = EXCLUDED.basis_gyd,
      cup_global_rate = EXCLUDED.cup_global_rate,
      cup_rate        = EXCLUDED.cup_rate,
      usdt_buy_gyd    = EXCLUDED.usdt_buy_gyd,
      usdt_sell_gyd   = EXCLUDED.usdt_sell_gyd,
      rate_version_id = EXCLUDED.rate_version_id,
      facturado_gyd   = EXCLUDED.facturado_gyd,
      invertido_gyd   = EXCLUDED.invertido_gyd,
      retorno_gyd     = EXCLUDED.retorno_gyd,
      missing_inputs  = EXCLUDED.missing_inputs,
      delivery_mode   = EXCLUDED.delivery_mode,
      actor_user_id   = EXCLUDED.actor_user_id,
      completed_at    = EXCLUDED.completed_at,
      cost_gyd        = EXCLUDED.cost_gyd,
      sale_gyd        = EXCLUDED.sale_gyd,
      voided_at       = NULL,
      void_reason     = NULL
    -- (226) a row the admin deleted on purpose (deleted_at) is never revived: only a reverted operation's void row is
    WHERE remittance_calculator_entries.status = 'void'
      AND remittance_calculator_entries.deleted_at IS NULL
    RETURNING id INTO v_entry_id;

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
END;
$function$;

CREATE OR REPLACE VIEW public.calculator_unfed_operations AS
SELECT o.id AS operation_id,
    o.account_id,
    o.completed_at,
    o.delivery_method,
    o.quoted_source_amount,
    calculator_resolve_operation_service(o.id, o.delivery_method) AS service,
        CASE
            WHEN (p.n_parts = 0) THEN 'service_unresolved'::text
            WHEN (p.n_parts > 1) THEN 'mixed_part_unfed'::text
            ELSE NULL::text
        END AS unfed_reason
   FROM ((remittance_operations o
     CROSS JOIN calculator_feed_state s)
     CROSS JOIN LATERAL ( SELECT count(*) AS n_parts,
            count(*) FILTER (WHERE (NOT (EXISTS ( SELECT 1
                   FROM remittance_calculator_entries e
                  WHERE ((e.account_id = o.account_id) AND (e.operation_id = o.id) AND (e.source = 'completed_operation'::text) AND (e.service = part.service) AND ((e.status <> 'void'::text) OR (e.deleted_at IS NOT NULL))))))) AS n_unfed
           FROM calculator_operation_parts(o.*, calculator_rates_vigentes(o.account_id)) part(service, basis, placeholder_amount, missing)) p)
  WHERE ((o.status = 'completed'::text) AND (o.completed_at >= s.feed_started_at) AND (o.quoted_source_amount > (0)::numeric) AND ((p.n_parts = 0) OR (p.n_unfed > 0)));
