-- =====================================================================
-- 127 — Register a reparto (one deposit shared among several beneficiaries)
--
-- The Cerebro only knows how to register ONE beneficiary automatically. When a
-- customer splits one deposit among several people ("A esta le pasa 100 zel …
-- A esta 50 zel …"), nothing is registered and a person has to type it all.
-- The model understands these conversations; what was missing is a safe way to
-- store several beneficiaries with their amounts.
--
-- cerebro_aplicar_reparto(operation, reparto jsonb) is the write side. The
-- pairing itself (which amount goes with which account) is done by the
-- validated prototype running in the "Cerebro - Repartos automaticos" n8n
-- workflow: 10/10 real beneficiaries correct, 0 wrong, checked against the
-- team's delivery proofs. This function is the SECOND lock: it writes nothing
-- unless the reparto is coherent on its own.
--   - The operation is an open remesa, not locked by a person.
--   - There are at least two distinct accounts, each with an amount > 0, all in
--     one currency.
--   - The amounts add up EXACTLY to the deposit at today's rate: floor(GYD /
--     usd rate) for USD, round(GYD × cup rate) for CUP.
--   - It never replaces a DIFFERENT existing beneficiary. Only one that is part
--     of the reparto (the Cerebro may have registered the first account alone)
--     is replaced.
--   - Idempotent: the same reparto again is a no-op.
-- When applied it:
--   - replaces the current beneficiaries with the reparto, each with its amount
--     (amount_origin 'manual');
--   - locks `beneficiaries`, so a later automatic single-beneficiary note cannot
--     undo it (cerebro_sync_beneficiarios honours the lock since 098); a person
--     can still correct it from the panel;
--   - writes an 'automation_reparto_registered' audit row.
--
-- ROLLBACK: ROLLBACK-127-reparto-auto.sql
-- Guarded by supabase/staging/assertions/reparto-auto.sql
-- =====================================================================

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
    'automation_reparto_registered'
  ));

CREATE OR REPLACE FUNCTION cerebro_aplicar_reparto(p_operation_id uuid, p_reparto jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op        remittance_operations%ROWTYPE;
  v_item      jsonb;
  v_filas     jsonb := '[]'::jsonb;
  v_tipo      text;
  v_cuenta    text;
  v_celular   text;
  v_monto     numeric;
  v_moneda    text;
  v_monedas   text[] := ARRAY[]::text[];
  v_cuentas   text[] := ARRAY[]::text[];
  v_suma      numeric := 0;
  v_objetivo  numeric;
  v_usd       numeric := crm_tasa_vigente('usd');
  v_cup       numeric := crm_tasa_vigente('gyd');
  v_actuales  text[];
  v_iguales   boolean;
  v_block     integer;
  v_pos       integer := 0;
  v_actor     text := wacrm_current_actor();
  v_origen    text := current_setting('wacrm.origin', true);
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('aplicado', false, 'motivo', 'no_existe'); END IF;
  IF v_op.status IN ('completed', 'cancelled') THEN RETURN jsonb_build_object('aplicado', false, 'motivo', 'cerrada'); END IF;
  IF v_op.service_type IS DISTINCT FROM 'remesa' THEN RETURN jsonb_build_object('aplicado', false, 'motivo', 'no_es_remesa'); END IF;

  -- Normalize and validate every entry.
  IF p_reparto IS NULL OR jsonb_typeof(p_reparto) <> 'array' THEN
    RETURN jsonb_build_object('aplicado', false, 'motivo', 'formato');
  END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_reparto) LOOP
    v_tipo := v_item->>'tipo';
    v_moneda := upper(coalesce(v_item->>'moneda', ''));
    BEGIN
      v_monto := (v_item->>'monto')::numeric;
    EXCEPTION WHEN OTHERS THEN v_monto := NULL;
    END;
    IF v_monto IS NULL OR v_monto <= 0 OR v_moneda NOT IN ('USD', 'CUP') THEN
      RETURN jsonb_build_object('aplicado', false, 'motivo', 'formato');
    END IF;
    IF v_tipo = 'zelle' THEN
      v_cuenta := lower(regexp_replace(coalesce(v_item->>'cuenta', ''), '\s', '', 'g'));
      IF position('@' in v_cuenta) = 0 THEN
        v_cuenta := regexp_replace(v_cuenta, '\D', '', 'g');
        IF length(v_cuenta) = 11 AND left(v_cuenta, 1) = '1' THEN v_cuenta := substr(v_cuenta, 2); END IF;
        IF length(v_cuenta) <> 10 THEN RETURN jsonb_build_object('aplicado', false, 'motivo', 'formato'); END IF;
      END IF;
      v_celular := NULL;
    ELSIF v_tipo = 'cuban_card' THEN
      v_cuenta := regexp_replace(coalesce(v_item->>'cuenta', ''), '\D', '', 'g');
      v_celular := right(regexp_replace(coalesce(v_item->>'celular', ''), '\D', '', 'g'), 8);
      IF length(v_cuenta) <> 16 OR v_celular !~ '^5[0-9]{7}$' THEN
        RETURN jsonb_build_object('aplicado', false, 'motivo', 'formato');
      END IF;
    ELSE
      RETURN jsonb_build_object('aplicado', false, 'motivo', 'formato');
    END IF;
    IF v_cuenta = ANY (v_cuentas) THEN RETURN jsonb_build_object('aplicado', false, 'motivo', 'cuenta_repetida'); END IF;
    v_cuentas := v_cuentas || v_cuenta;
    v_monedas := v_monedas || v_moneda;
    v_suma := v_suma + v_monto;
    v_filas := v_filas || jsonb_build_object('tipo', v_tipo, 'cuenta', v_cuenta, 'celular', v_celular,
                                             'nombre', nullif(btrim(coalesce(v_item->>'nombre', '')), ''),
                                             'monto', v_monto, 'moneda', v_moneda);
  END LOOP;

  IF coalesce(array_length(v_cuentas, 1), 0) < 2 THEN
    RETURN jsonb_build_object('aplicado', false, 'motivo', 'no_es_reparto');
  END IF;
  IF (SELECT count(DISTINCT m) FROM unnest(v_monedas) m) <> 1 THEN
    RETURN jsonb_build_object('aplicado', false, 'motivo', 'formato');
  END IF;

  -- The amounts must add up EXACTLY to the deposit.
  v_objetivo := CASE v_monedas[1]
                  WHEN 'USD' THEN CASE WHEN v_usd > 0 THEN floor(v_op.quoted_source_amount / v_usd) END
                  ELSE CASE WHEN v_cup > 0 THEN round(v_op.quoted_source_amount * v_cup) END
                END;
  IF v_objetivo IS NULL OR v_suma <> v_objetivo THEN
    RETURN jsonb_build_object('aplicado', false, 'motivo', 'suma_no_cuadra', 'suma', v_suma, 'deposito', v_objetivo);
  END IF;

  -- Idempotent: exactly this reparto is already there.
  SELECT count(*) = jsonb_array_length(v_filas)
         AND bool_and(EXISTS (SELECT 1 FROM jsonb_array_elements(v_filas) f
                               WHERE f->>'cuenta' = coalesce(b.zelle_account, b.card_number)
                                 AND (f->>'monto')::numeric = b.amount))
    INTO v_iguales
    FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente';
  IF coalesce(v_iguales, false) THEN RETURN jsonb_build_object('aplicado', false, 'motivo', 'ya_aplicado'); END IF;

  IF v_op.admin_locked_fields ? 'beneficiaries' THEN
    RETURN jsonb_build_object('aplicado', false, 'motivo', 'bloqueado');
  END IF;

  -- Never over a different existing beneficiary.
  SELECT array_agg(lower(coalesce(b.zelle_account, b.card_number))) INTO v_actuales
    FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente';
  IF EXISTS (SELECT 1 FROM unnest(coalesce(v_actuales, ARRAY[]::text[])) a WHERE NOT (a = ANY (v_cuentas))) THEN
    RETURN jsonb_build_object('aplicado', false, 'motivo', 'otro_beneficiario');
  END IF;

  -- Apply.
  UPDATE remittance_beneficiaries SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = p_operation_id AND status = 'vigente';
  SELECT coalesce(max(block_index), 0) + 1 INTO v_block FROM remittance_beneficiaries WHERE operation_id = p_operation_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_filas) LOOP
    v_pos := v_pos + 1;
    INSERT INTO remittance_beneficiaries (
      operation_id, beneficiary_type, name, card_number, phone, zelle_account,
      amount, currency, amount_origin, position, block_index, source, status)
    VALUES (
      p_operation_id, v_item->>'tipo', v_item->>'nombre',
      CASE WHEN v_item->>'tipo' = 'cuban_card' THEN v_item->>'cuenta' END,
      v_item->>'celular',
      CASE WHEN v_item->>'tipo' = 'zelle' THEN v_item->>'cuenta' END,
      (v_item->>'monto')::numeric, v_item->>'moneda', 'manual', v_pos, v_block, 'reparto_auto', 'vigente');
  END LOOP;

  -- 096 only lets a human actor change the lock map. This single write is
  -- flagged as administrative, and the previous origin is restored right after,
  -- so nothing else in the caller's transaction inherits it. The audit keeps
  -- the real (automation) actor captured above.
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations
     SET admin_locked_fields = coalesce(admin_locked_fields, '{}'::jsonb)
           || jsonb_build_object('beneficiaries', jsonb_build_object('by', 'reparto_auto', 'at', now()))
   WHERE id = p_operation_id;
  PERFORM set_config('wacrm.origin', coalesce(v_origen, ''), true);

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_op.account_id, 'remittance_operations', p_operation_id, 'beneficiaries', 'automation_reparto_registered',
          v_actor,
          jsonb_build_object('vigentes', coalesce(to_jsonb(v_actuales), '[]'::jsonb)),
          jsonb_build_object('reparto', v_filas, 'suma', v_suma, 'deposito', v_objetivo));

  RETURN jsonb_build_object('aplicado', true, 'motivo', 'aplicado', 'n', v_pos, 'suma', v_suma);
END $$;

COMMENT ON FUNCTION cerebro_aplicar_reparto(uuid, jsonb) IS
  '127. Writes a reparto (several beneficiaries with amounts) on an open remesa '
  'only if the amounts add up exactly to the deposit; never over a different '
  'beneficiary; locks beneficiaries and audits.';

REVOKE EXECUTE ON FUNCTION cerebro_aplicar_reparto(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_aplicar_reparto(uuid, jsonb) TO service_role;

NOTIFY pgrst, 'reload schema';
