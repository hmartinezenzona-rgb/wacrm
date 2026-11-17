-- 380: the MMG ledger deposits nobody owns, for the panel's "link a deposit" picker (T3b of odd/tasks/panel-fully-editable.md).
--
-- Production, 30 days to 2026-11-17: 61 ledger deposits without an operation, and 36 of the developer's 298 audited corrections were
-- deposit <-> operation links. Case: conversation 78e3540b (2026-11-17), a real 13,000 GYD deposit stayed free because a burst of several
-- receipts only processed one.
--
-- A deposit is free when it has no operation and was not consumed, annulled or discarded. The panel lists the newest first (last 45 days,
-- 40 rows) and links one with the existing verify (crm_verificar_deposito, with its TransID and amount), so this function only reads.
-- The ledger has no account column (one business): access is checked through the operation the agent is looking at.

CREATE OR REPLACE FUNCTION public.crm_depositos_sin_dueno(p_operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  SELECT account_id INTO v_account_id FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to read the deposits of this operation' USING ERRCODE = '42501';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'trans_id', d.trans_id, 'amount', d.monto, 'currency', d.moneda, 'received_at', d.recibido_en, 'holder', d.titular)
           ORDER BY d.recibido_en DESC)
      FROM (SELECT * FROM depositos_mmg x
             WHERE x.operation_id IS NULL AND x.consumido_en IS NULL AND x.anulado_en IS NULL AND x.descartado_en IS NULL
               AND x.recibido_en > now() - interval '45 days'
             ORDER BY x.recibido_en DESC
             LIMIT 40) d
  ), '[]'::jsonb);
END $function$;

REVOKE ALL ON FUNCTION public.crm_depositos_sin_dueno(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_depositos_sin_dueno(uuid) TO authenticated;
