-- =====================================================================
-- 169 — reparto with a USD card rail (Clasica / Tropical)
--
-- Production case a29ef5e8 (2026-10-01): one 65,000 GYD deposit split as
-- 15,000 GYD to an MN (CUP) card and 50,000 GYD to a Clasica card. It was
-- stored as TWO 'clasica' beneficiaries, BOTH in CUP (45,000 and 150,000):
--
--   * cerebro_aplicar_reparto only knew 'zelle' and 'cuban_card', so the
--     Clasica share could only arrive as a CUP card;
--   * 157's BEFORE INSERT trigger re-types every 'cuban_card' row of a
--     conversation whose pending destination is clasica/tropical, so both
--     cards of the reparto became 'clasica', including the MN one.
--   Type came from the trigger, currency from the payload: 'clasica' + CUP.
--
-- This migration:
--   1. cerebro_aplicar_reparto accepts 'clasica' and 'tropical' shares
--      (validated like a card: 16 digits + Cuban mobile), stores their
--      card number, and requires type and currency to agree (cuban_card
--      in CUP; zelle/clasica/tropical in USD). CUP + USD shares are
--      already checked in GYD by 129's mixed rule, unchanged.
--   2. Fail closed: when the conversation's pending destination is
--      clasica/tropical and no share is on that rail, the reparto is
--      refused ('destino_sin_asignar') instead of stored and locked.
--   3. The trigger leaves rows written by a reparto alone.
--
-- The n8n node "Detectar repartos" (v5) is what now sends the rail per
-- share. No data is touched. Safe on a database at 157 and on one at 166:
-- neither function is redefined by 158-166.
-- =====================================================================

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
  v_suma_usd  numeric := 0;
  v_suma_cup  numeric := 0;
  v_n_cup     integer := 0;
  v_resto     numeric;
  v_objetivo  numeric;
  v_usd       numeric := crm_tasa_vigente('usd');
  v_cup       numeric := crm_tasa_vigente('gyd');
  v_actuales  text[];
  v_iguales   boolean;
  v_block     integer;
  v_pos       integer := 0;
  v_actor     text := wacrm_current_actor();
  v_origen    text := current_setting('wacrm.origin', true);
  v_riel      text;
  v_tipos     text[] := ARRAY[]::text[];
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
    ELSIF v_tipo IN ('cuban_card', 'clasica', 'tropical') THEN
      v_cuenta := regexp_replace(coalesce(v_item->>'cuenta', ''), '\D', '', 'g');
      v_celular := right(regexp_replace(coalesce(v_item->>'celular', ''), '\D', '', 'g'), 8);
      -- (130) Cuban mobiles start with 5, or with 63 for lines issued since 2023-12-30 (ETECSA).
      IF length(v_cuenta) <> 16 OR v_celular !~ '^(5[0-9]{7}|63[0-9]{6})$' THEN
        RETURN jsonb_build_object('aplicado', false, 'motivo', 'formato');
      END IF;
    ELSE
      RETURN jsonb_build_object('aplicado', false, 'motivo', 'formato');
    END IF;
    -- (167) Each rail has ONE currency: a CUP card is quoted in CUP; Zelle, Clasica and Tropical in
    -- USD. A share whose type and currency disagree is never stored.
    IF (v_tipo = 'cuban_card') <> (v_moneda = 'CUP') THEN
      RETURN jsonb_build_object('aplicado', false, 'motivo', 'formato');
    END IF;
    v_tipos := v_tipos || v_tipo;
    IF v_cuenta = ANY (v_cuentas) THEN RETURN jsonb_build_object('aplicado', false, 'motivo', 'cuenta_repetida'); END IF;
    v_cuentas := v_cuentas || v_cuenta;
    v_monedas := v_monedas || v_moneda;
    v_suma := v_suma + v_monto;
    IF v_moneda = 'USD' THEN v_suma_usd := v_suma_usd + v_monto; ELSE v_suma_cup := v_suma_cup + v_monto; v_n_cup := v_n_cup + 1; END IF;
    v_filas := v_filas || jsonb_build_object('tipo', v_tipo, 'cuenta', v_cuenta, 'celular', v_celular,
                                             'nombre', nullif(btrim(coalesce(v_item->>'nombre', '')), ''),
                                             'monto', v_monto, 'moneda', v_moneda);
  END LOOP;

  IF coalesce(array_length(v_cuentas, 1), 0) < 2 THEN
    RETURN jsonb_build_object('aplicado', false, 'motivo', 'no_es_reparto');
  END IF;
  IF (SELECT count(DISTINCT m) FROM unnest(v_monedas) m) = 1 THEN
    -- One currency: the amounts must add up EXACTLY to the deposit.
    v_objetivo := CASE v_monedas[1]
                    WHEN 'USD' THEN CASE WHEN v_usd > 0 THEN floor(v_op.quoted_source_amount / v_usd) END
                    ELSE CASE WHEN v_cup > 0 THEN round(v_op.quoted_source_amount * v_cup) END
                  END;
    IF v_objetivo IS NULL OR v_suma <> v_objetivo THEN
      RETURN jsonb_build_object('aplicado', false, 'motivo', 'suma_no_cuadra', 'suma', v_suma, 'deposito', v_objetivo);
    END IF;
  ELSE
    -- (129) MIXED cards (CUP) + Zelle (USD): everything is brought to GYD. The Zelle shares are
    -- whole USD, always rounded down (business rule), so the deposit may be covered exactly or leave
    -- less than 1 USD over; CUP shares converted back to GYD get half a GYD of rounding each.
    IF NOT (v_usd > 0 AND v_cup > 0) THEN
      RETURN jsonb_build_object('aplicado', false, 'motivo', 'suma_no_cuadra');
    END IF;
    v_suma := v_suma_usd * v_usd + v_suma_cup / v_cup;
    v_objetivo := v_op.quoted_source_amount;
    v_resto := v_objetivo - v_suma;
    IF NOT (abs(v_resto) < 0.5 * greatest(v_n_cup, 1) OR (v_resto > 0 AND v_resto < v_usd)) THEN
      RETURN jsonb_build_object('aplicado', false, 'motivo', 'suma_no_cuadra', 'suma_gyd', round(v_suma, 2), 'deposito', v_objetivo);
    END IF;
  END IF;

  -- (167) The customer named a USD card rail (157's pending destination) but no share of this
  -- reparto is on it: the detector could not tell WHICH card is the Clasica/Tropical one. Storing
  -- it would quote that card in CUP and lock the mistake, so it is left for a person.
  SELECT p.tipo INTO v_riel
    FROM cerebro_destino_pendiente p
   WHERE p.conversation_id = v_op.conversation_id
     AND p.tipo IN ('clasica', 'tropical')
     AND p.actualizado > now() - interval '24 hours';
  IF v_riel IS NOT NULL AND NOT (v_riel = ANY (v_tipos)) THEN
    RETURN jsonb_build_object('aplicado', false, 'motivo', 'destino_sin_asignar', 'destino', v_riel);
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
      CASE WHEN v_item->>'tipo' <> 'zelle' THEN v_item->>'cuenta' END,
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

CREATE OR REPLACE FUNCTION public.cerebro_destino_pendiente_antes_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tipo text;
BEGIN
  -- (167) A reparto states each share's own rail; the conversation-wide pending destination must
  -- not turn its CUP cards into Clasica/Tropical ones.
  IF NEW.beneficiary_type = 'cuban_card' AND NEW.operation_id IS NOT NULL
     AND NEW.source IS DISTINCT FROM 'reparto_auto' THEN
    SELECT p.tipo INTO v_tipo
      FROM public.cerebro_destino_pendiente p
      JOIN public.remittance_operations o ON o.conversation_id = p.conversation_id
     WHERE o.id = NEW.operation_id
       AND p.tipo IN ('clasica', 'tropical')
       AND p.actualizado > now() - interval '24 hours'
     LIMIT 1;

    IF v_tipo IS NOT NULL THEN
      NEW.beneficiary_type := v_tipo;
    END IF;
  END IF;

  RETURN NEW;
END $$;
