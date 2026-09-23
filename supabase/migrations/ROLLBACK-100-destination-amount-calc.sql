-- =====================================================================
-- ROLLBACK-100 — reverts 100_destination_amount_calc.sql
--
-- Drops the recalculation triggers and functions, restores
-- crm_operaciones_de_conversacion to its exact 097 shape, and drops the
-- 3 columns this migration added.
-- =====================================================================

DROP TRIGGER IF EXISTS trg_zz_recalc_destino_operations ON remittance_operations;
DROP TRIGGER IF EXISTS trg_zz_recalc_destino_beneficiaries ON remittance_beneficiaries;
DROP TRIGGER IF EXISTS trg_zz_destino_manual_origin ON remittance_operations;

DROP FUNCTION IF EXISTS remittance_operations_recalc_destino_trigger();
DROP FUNCTION IF EXISTS remittance_beneficiaries_recalc_destino_trigger();
DROP FUNCTION IF EXISTS remittance_operations_destino_manual_origin_guard();

DROP FUNCTION IF EXISTS crm_calcular_monto_destino(uuid);
DROP FUNCTION IF EXISTS crm_tasa_vigente(text);

-- Restore crm_operaciones_de_conversacion to the exact 097 shape.
DROP FUNCTION IF EXISTS crm_operaciones_de_conversacion(uuid);

CREATE FUNCTION crm_operaciones_de_conversacion(
  p_conversation_id uuid
) RETURNS TABLE (
  resolver_resultado                  text,
  resolver_operation_id               uuid,
  resolver_candidatas                 integer,
  operation_id                        uuid,
  operation_status                    text,
  operation_service_type              text,
  operation_source_currency           text,
  operation_destination_currency      text,
  operation_delivery_method           text,
  operation_deposit_method            text,
  operation_quoted_source_amount      numeric,
  operation_quoted_destination_amount numeric,
  operation_admin_locked_fields       jsonb,
  operation_created_at                timestamptz,
  operation_completed_at              timestamptz,
  beneficiary_id                      uuid,
  beneficiary_type                    text,
  beneficiary_name                    text,
  beneficiary_card_number             text,
  beneficiary_phone                   text,
  beneficiary_zelle_account           text,
  beneficiary_delivery_method         text,
  beneficiary_amount                  numeric,
  beneficiary_currency                text,
  beneficiary_position                integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id            uuid;
  v_resolver_resultado    text;
  v_resolver_operation_id uuid;
  v_resolver_candidatas   integer;
BEGIN
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  SELECT c.account_id INTO v_account_id
    FROM conversations c
   WHERE c.id = p_conversation_id;

  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO v_resolver_candidatas
    FROM remittance_operations
   WHERE conversation_id = p_conversation_id
     AND status NOT IN ('completed', 'cancelled');

  IF v_resolver_candidatas = 0 THEN
    v_resolver_resultado := 'ninguna';
    v_resolver_operation_id := NULL;
  ELSIF v_resolver_candidatas = 1 THEN
    v_resolver_resultado := 'unica';
    SELECT o.id INTO v_resolver_operation_id
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status NOT IN ('completed', 'cancelled');
  ELSE
    v_resolver_resultado := 'ambigua';
    v_resolver_operation_id := NULL;
  END IF;

  RETURN QUERY
  SELECT
    r.resultado,
    r.operation_id,
    r.candidatas,
    o.id,
    o.status,
    o.service_type,
    o.source_currency,
    o.destination_currency,
    o.delivery_method,
    o.deposit_method,
    o.quoted_source_amount,
    o.quoted_destination_amount,
    o.admin_locked_fields,
    o.created_at,
    o.completed_at,
    b.id,
    b.beneficiary_type,
    b.name,
    b.card_number,
    b.phone,
    b.zelle_account,
    b.delivery_method,
    b.amount,
    b.currency,
    b.position
  FROM (SELECT v_resolver_resultado AS resultado, v_resolver_operation_id AS operation_id, v_resolver_candidatas AS candidatas) r
  LEFT JOIN remittance_operations o
         ON o.conversation_id = p_conversation_id
        AND o.status NOT IN ('completed', 'cancelled')
        AND o.service_type = 'remesa'
  LEFT JOIN remittance_beneficiaries b
         ON b.operation_id = o.id
        AND b.status = 'vigente'
  ORDER BY o.created_at DESC NULLS LAST, b.position ASC NULLS LAST;
END $$;

REVOKE ALL ON FUNCTION crm_operaciones_de_conversacion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_operaciones_de_conversacion(uuid) TO authenticated;

ALTER TABLE remittance_operations
  DROP COLUMN IF EXISTS quoted_destination_rate,
  DROP COLUMN IF EXISTS quoted_destination_origin;

ALTER TABLE remittance_beneficiaries
  DROP COLUMN IF EXISTS amount_origin;
