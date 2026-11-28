-- =====================================================================
-- 332 -- Funding case in the panel (phase 4a)
--
-- The operator needs to see the case behind an operation and resolve an incident. These two
-- SECURITY DEFINER functions are the panel's only new data path:
--   * funding_caso_panel(conversation): the active case (or the latest closed one) with the verified /
--     assigned / available GYD, the linked deposits and the allocations. Membership 'viewer'.
--   * funding_caso_resolver_panel(case): clears an incident and re-runs funding_reconciliar. Membership
--     'agent'. The resolver never clears a conflict that the data still shows: the engine sets the
--     case back to incident.
-- They check is_account_member themselves, so a direct RPC call cannot bypass the API route.
--
-- Assertion: supabase/staging/assertions/funding-caso-panel.sql.
-- Rollback: ROLLBACK-332-funding-caso-panel.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.funding_caso_panel(p_conversation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_case    funding_case%ROWTYPE;
  v_dep     numeric;
  v_asig    numeric;
  v_disp    numeric;
BEGIN
  IF p_conversation IS NULL THEN
    RAISE EXCEPTION 'conversation is required' USING ERRCODE = '22023';
  END IF;

  SELECT c.account_id INTO v_account FROM conversations c WHERE c.id = p_conversation;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'conversation not found' USING ERRCODE = 'P0002';
  END IF;
  IF auth.uid() IS NULL OR NOT is_account_member(v_account, 'viewer'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to read this funding case' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_case
    FROM funding_case fc
   WHERE fc.conversation_id = p_conversation AND fc.status <> 'closed'
   ORDER BY fc.opened_at DESC
   LIMIT 1;
  IF NOT FOUND THEN
    SELECT * INTO v_case
      FROM funding_case fc
     WHERE fc.conversation_id = p_conversation
     ORDER BY fc.opened_at DESC
     LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('case', NULL);
    END IF;
  END IF;

  SELECT s.depositado, s.asignado, s.disponible
    INTO v_dep, v_asig, v_disp
    FROM funding_case_saldo(v_case.id) s;

  RETURN jsonb_build_object('case', jsonb_build_object(
    'id', v_case.id,
    'status', v_case.status,
    'opened_at', v_case.opened_at,
    'closed_at', v_case.closed_at,
    'note', v_case.note,
    'depositado', v_dep,
    'asignado', v_asig,
    'disponible', v_disp,
    'deposits', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'trans_id', d.trans_id,
               'monto', d.monto,
               'recibido_en', d.recibido_en,
               'anulado_en', d.anulado_en)
             ORDER BY d.recibido_en DESC)
        FROM case_deposits cd
        JOIN depositos_mmg d ON d.trans_id = cd.deposit_trans_id
       WHERE cd.case_id = v_case.id), '[]'::jsonb),
    'allocations', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'operation_id', a.operation_id,
               'service', cerebro_riel_op(a.operation_id),
               'amount_gyd', a.amount_gyd,
               'status', a.status,
               'evidence_type', a.evidence_type,
               'created_at', a.created_at)
             ORDER BY a.created_at)
        FROM funding_allocations a
       WHERE a.case_id = v_case.id), '[]'::jsonb)
  ));
END $function$;

COMMENT ON FUNCTION public.funding_caso_panel(uuid) IS
  '332: the case of a conversation for the panel: status, verified/assigned/available GYD, deposits '
  'and allocations. SECURITY DEFINER; requires the viewer role in the case account.';

CREATE OR REPLACE FUNCTION public.funding_caso_resolver_panel(p_case uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_conv    uuid;
BEGIN
  IF p_case IS NULL THEN
    RAISE EXCEPTION 'case is required' USING ERRCODE = '22023';
  END IF;

  SELECT account_id, conversation_id INTO v_account, v_conv
    FROM funding_case
   WHERE id = p_case;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'funding case not found' USING ERRCODE = 'P0002';
  END IF;
  IF auth.uid() IS NULL OR NOT is_account_member(v_account, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to resolve this funding case' USING ERRCODE = '42501';
  END IF;

  PERFORM funding_case_resolver(p_case, 'panel:' || auth.uid()::text);
  RETURN funding_reconciliar(v_conv, 'panel:' || auth.uid()::text);
END $function$;

COMMENT ON FUNCTION public.funding_caso_resolver_panel(uuid) IS
  '332: clears an incident and re-runs the reconciliation for the panel. A conflict the data still '
  'shows returns the case to incident. SECURITY DEFINER; requires the agent role in the case account.';

REVOKE ALL ON FUNCTION public.funding_caso_panel(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.funding_caso_resolver_panel(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.funding_caso_panel(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.funding_caso_resolver_panel(uuid) TO authenticated, service_role;
