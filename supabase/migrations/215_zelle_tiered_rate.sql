-- =====================================================================
-- 215 -- Tiered Zelle rate (staging first)
--
-- odd/tasks/zelle-tiered-rate.md (T1). Zelle is priced by tiers of USD received: 260 GYD per USD for 50-999 USD, 250 for
-- 1,000-1,999, 245 from 2,000. The customer gets the best tier the deposit reaches: from GYD, floor(gyd/245) >= 2000 -> 245;
-- elsif floor(gyd/250) >= 1000 -> 250; else 260. Owner decision: a deposit split among several beneficiaries takes its tier
-- from the TOTAL of the deposit, not from each part.
--
-- Only Zelle changes. Clasica, Tropical, USDT and Mexico keep the single rate (calculator_rate_versions.usdt_sell_gyd, the
-- `tasas` view, crm_tasa_vigente('usd')). The Zelle minimum stays 13,000 GYD. The calculator's invested side keeps
-- usdt_buy_gyd: only the selling rate of a Zelle line is tiered.
--
-- NEW: cerebro_config 'zelle_tiers' (the tiers as data), cerebro_zelle_cotizar_gyd(gyd) -> (usd, tasa),
-- cerebro_tasa_zelle(usd) -> rate, cerebro_zelle_usd_desde_gyd(gyd) -> usd. service_role only, like the other cerebro helpers.
--
-- SWITCHED (Zelle path only): crm_calcular_monto_destino, crm_monto_resto_zelle, cerebro_aplicar_reparto (tier from the
-- deposit total), cerebro_resolver_operacion_beneficiario, cerebro_fijar_objetivo (USD -> GYD), calculator_feed_operation
-- (ZELLE line), crm_resolve_pending_entry (ZELLE line). Left as is, shared with other rails: the {tasa_usd} placeholder of
-- cerebro_servicio_get (only used by the cash service text), calculator_operation_parts (a mixed remesa's Zelle line takes
-- the remainder of the deposit, then is priced by the feed).
--
-- Guarded by supabase/staging/assertions/zelle-tiered-rate.sql
-- ROLLBACK: ROLLBACK-215-zelle-tiered-rate.sql
-- =====================================================================

-- Tier configuration, as data (same store as the other cerebro settings): a JSON list of {min_usd, rate_gyd}. The best
-- tier is the highest min_usd the deposit reaches; below the lowest tier the lowest tier's rate applies.
INSERT INTO cerebro_config (clave, valor, descripcion) VALUES
  ('zelle_tiers', '[{"min_usd":50,"rate_gyd":260},{"min_usd":1000,"rate_gyd":250},{"min_usd":2000,"rate_gyd":245}]',
   'Zelle sale rate by tier of USD received: [{min_usd, rate_gyd}]. 260 for 50-999 USD, 250 for 1,000-1,999, 245 from 2,000 (215).')
ON CONFLICT (clave) DO NOTHING;

-- Tier of a deposit in GYD: the best tier whose floor(gyd / rate) reaches its minimum USD; below the lowest tier, the
-- lowest tier's rate. Returns the USD (whole units, rounded DOWN) and the rate. No row for a missing or non-positive deposit.
-- If the configuration is missing or unreadable it falls back to the single rate, so the Zelle path never breaks.
CREATE OR REPLACE FUNCTION public.cerebro_zelle_cotizar_gyd(p_gyd numeric)
RETURNS TABLE(usd numeric, tasa numeric)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_tiers jsonb;
  v_rate  numeric;
BEGIN
  IF p_gyd IS NULL OR p_gyd <= 0 THEN RETURN; END IF;
  BEGIN
    v_tiers := NULLIF(cerebro_config_get('zelle_tiers'), '')::jsonb;
  EXCEPTION WHEN OTHERS THEN v_tiers := NULL;
  END;
  IF v_tiers IS NOT NULL AND jsonb_typeof(v_tiers) = 'array' AND jsonb_array_length(v_tiers) > 0 THEN
    SELECT t.rate_gyd INTO v_rate
      FROM jsonb_to_recordset(v_tiers) AS t(min_usd numeric, rate_gyd numeric)
     WHERE t.rate_gyd > 0 AND floor(p_gyd / t.rate_gyd) >= t.min_usd
     ORDER BY t.min_usd DESC LIMIT 1;
    IF v_rate IS NULL THEN
      SELECT t.rate_gyd INTO v_rate
        FROM jsonb_to_recordset(v_tiers) AS t(min_usd numeric, rate_gyd numeric)
       WHERE t.rate_gyd > 0 ORDER BY t.min_usd ASC LIMIT 1;
    END IF;
  END IF;
  v_rate := coalesce(v_rate, crm_tasa_vigente('usd'));
  IF v_rate IS NULL OR v_rate <= 0 THEN RETURN; END IF;
  RETURN QUERY SELECT floor(p_gyd / v_rate), v_rate;
END $function$;

-- Rate for an amount of USD received (the customer asks for N USD): the highest tier N reaches; below the lowest tier,
-- the lowest tier's rate.
CREATE OR REPLACE FUNCTION public.cerebro_tasa_zelle(p_usd numeric)
RETURNS numeric
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_tiers jsonb;
  v_rate  numeric;
BEGIN
  IF p_usd IS NULL OR p_usd <= 0 THEN RETURN NULL; END IF;
  BEGIN
    v_tiers := NULLIF(cerebro_config_get('zelle_tiers'), '')::jsonb;
  EXCEPTION WHEN OTHERS THEN v_tiers := NULL;
  END;
  IF v_tiers IS NOT NULL AND jsonb_typeof(v_tiers) = 'array' AND jsonb_array_length(v_tiers) > 0 THEN
    SELECT t.rate_gyd INTO v_rate
      FROM jsonb_to_recordset(v_tiers) AS t(min_usd numeric, rate_gyd numeric)
     WHERE t.rate_gyd > 0 AND p_usd >= t.min_usd
     ORDER BY t.min_usd DESC LIMIT 1;
    IF v_rate IS NULL THEN
      SELECT t.rate_gyd INTO v_rate
        FROM jsonb_to_recordset(v_tiers) AS t(min_usd numeric, rate_gyd numeric)
       WHERE t.rate_gyd > 0 ORDER BY t.min_usd ASC LIMIT 1;
    END IF;
  END IF;
  RETURN coalesce(v_rate, crm_tasa_vigente('usd'));
END $function$;

-- USD (whole units, rounded down) a deposit in GYD buys on the Zelle tiers.
CREATE OR REPLACE FUNCTION public.cerebro_zelle_usd_desde_gyd(p_gyd numeric)
RETURNS numeric
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT z.usd FROM cerebro_zelle_cotizar_gyd(p_gyd) z;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_zelle_cotizar_gyd(numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_zelle_cotizar_gyd(numeric) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_tasa_zelle(numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_tasa_zelle(numeric) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_zelle_usd_desde_gyd(numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_zelle_usd_desde_gyd(numeric) TO service_role;

-- The Zelle readers, one minimal edit each. Their current staging definitions (213 redefined two of them).

CREATE OR REPLACE FUNCTION public.crm_calcular_monto_destino(p_operation_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op            remittance_operations%ROWTYPE;
  v_found         boolean := true;
  v_vigente_count integer;
  v_ben           remittance_beneficiaries%ROWTYPE;
  v_rate          numeric;
  v_amount        numeric;
  v_currency      text;
  v_computable    boolean := false;
BEGIN
  -- Recursion guard: the UPDATEs below re-fire this migration's own AFTER
  -- triggers. If a calculation is already running higher up the call stack,
  -- do nothing here — the flag belongs to that outer invocation, so this
  -- nested call must not touch (and must not reset) it.
  IF current_setting('wacrm.calc_destino', true) = 'on' THEN
    RETURN;
  END IF;

  PERFORM set_config('wacrm.calc_destino', 'on', true);

  BEGIN
    SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
    IF NOT FOUND THEN
      v_found := false;
    END IF;

    -- Eligible at all: exists, is a remesa, is still open, its destination
    -- amount isn't human-locked, and it either has no destination amount
    -- yet or the one it has is this function's own prior calculation (never
    -- a pre-existing/manual value).
    IF v_found
       AND v_op.service_type = 'remesa'
       AND v_op.status NOT IN ('completed', 'cancelled')
       AND NOT (v_op.admin_locked_fields ? 'quoted_destination_amount')
       AND (v_op.quoted_destination_amount IS NULL
            OR coalesce(v_op.quoted_destination_origin, '') = 'calculated')
    THEN
      SELECT count(*) INTO v_vigente_count
        FROM remittance_beneficiaries
       WHERE operation_id = p_operation_id AND status = 'vigente';

      IF v_vigente_count = 1
         AND coalesce(v_op.quoted_source_amount, 0) > 0
         AND upper(coalesce(v_op.source_currency, 'GYD')) = 'GYD'
      THEN
        SELECT * INTO v_ben
          FROM remittance_beneficiaries
         WHERE operation_id = p_operation_id AND status = 'vigente';

        IF v_ben.beneficiary_type IN ('zelle', 'clasica', 'tropical') THEN
          -- (215) Zelle is priced by tier of the deposit; Clasica and Tropical keep the single rate.
          IF v_ben.beneficiary_type = 'zelle' THEN
            SELECT z.tasa INTO v_rate FROM cerebro_zelle_cotizar_gyd(v_op.quoted_source_amount) z;
          ELSE
            v_rate := crm_tasa_vigente('usd');
          END IF;
          IF v_rate > 0 THEN
            -- Whole units, rounded DOWN, in the business's favour: a
            -- part-unit is never delivered as a full one, because that
            -- hands over more value than the deposit covers (75,000 GYD
            -- at 260 is 288.46 USD; delivering 289 gives away 140 GYD).
            -- Mirrors document-rates.ts deriveAmountFromDeposit and 111's
            -- calculator_amount_from_basis, so the panel and the ledger
            -- cannot disagree about one remesa. n8n's bot has always
            -- floored — this brings the panel in line with it.
            v_amount := floor(v_op.quoted_source_amount / v_rate);
            v_currency := 'USD';
            v_computable := true;
          END IF;
        ELSIF v_ben.beneficiary_type = 'efectivo_usd' THEN
          -- (188) Cash USD has its own rate, the calculator's efectivo_usd_gyd (via `tasas`
          -- as 'efectivo'). Whole dollars, rounded DOWN, like the other USD rails.
          v_rate := crm_tasa_vigente('efectivo');
          IF v_rate > 0 THEN
            v_amount := floor(v_op.quoted_source_amount / v_rate);
            v_currency := 'USD';
            v_computable := true;
          END IF;
        ELSIF v_ben.beneficiary_type = 'cuban_card' THEN
          v_rate := crm_tasa_vigente('gyd');
          IF v_rate > 0 THEN
            v_amount := round(v_op.quoted_source_amount * v_rate);
            v_currency := 'CUP';
            v_computable := true;
          END IF;
        END IF;
      END IF;

      IF v_computable THEN
        UPDATE remittance_operations
           SET quoted_destination_amount = v_amount,
               destination_currency = v_currency,
               quoted_destination_rate = v_rate,
               quoted_destination_origin = 'calculated'
         WHERE id = p_operation_id
           AND (quoted_destination_amount IS DISTINCT FROM v_amount
                OR destination_currency IS DISTINCT FROM v_currency
                OR quoted_destination_rate IS DISTINCT FROM v_rate
                OR quoted_destination_origin IS DISTINCT FROM 'calculated');

        IF NOT (v_op.admin_locked_fields ? 'beneficiaries')
           AND (v_ben.amount IS NULL OR v_ben.amount_origin = 'calculated')
        THEN
          UPDATE remittance_beneficiaries
             SET amount = v_amount,
                 currency = v_currency,
                 amount_origin = 'calculated'
           WHERE id = v_ben.id
             AND (amount IS DISTINCT FROM v_amount
                  OR currency IS DISTINCT FROM v_currency
                  OR amount_origin IS DISTINCT FROM 'calculated');
        END IF;
      ELSIF v_op.quoted_destination_origin = 'calculated' THEN
        -- No longer computable (e.g. a second beneficiary showed up, or the
        -- rate disappeared) but the current value was this function's own
        -- stale calculation — clear it rather than leave a number nothing
        -- can now reproduce. destination_currency is left untouched: it is
        -- not exclusively this migration's field to clear.
        UPDATE remittance_operations
           SET quoted_destination_amount = NULL,
               quoted_destination_rate = NULL,
               quoted_destination_origin = NULL
         WHERE id = p_operation_id;

        IF NOT (v_op.admin_locked_fields ? 'beneficiaries') THEN
          UPDATE remittance_beneficiaries
             SET amount = NULL,
                 currency = NULL,
                 amount_origin = NULL
           WHERE operation_id = p_operation_id
             AND status = 'vigente'
             AND amount_origin = 'calculated';
        END IF;
      END IF;

      -- (176) Several beneficiaries, one of them a Zelle without its amount (kept by
      -- 175 next to a card reparto): the Zelle gets what is left of the remesa.
      IF v_vigente_count > 1 AND NOT (v_op.admin_locked_fields ? 'beneficiaries') THEN
        PERFORM crm_monto_resto_zelle(p_operation_id);
      END IF;
    END IF;

    PERFORM set_config('wacrm.calc_destino', 'off', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('wacrm.calc_destino', 'off', true);
    RAISE;
  END;
END $function$;

CREATE OR REPLACE FUNCTION public.crm_monto_resto_zelle(p_operation_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op    remittance_operations%ROWTYPE;
  v_total numeric;
  v_usd   numeric := crm_tasa_vigente('usd');
  v_cup   numeric := crm_tasa_vigente('gyd');
  v_zrate numeric;
  v_zelle uuid;
  v_resto numeric;
  v_monto numeric;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.admin_locked_fields ? 'beneficiaries' OR NOT (v_usd > 0 AND v_cup > 0) THEN RETURN NULL; END IF;

  v_total := CASE WHEN coalesce(v_op.quoted_source_amount, 0) > 0 THEN v_op.quoted_source_amount
                  ELSE cerebro_cotizacion_vigente(v_op.conversation_id) END;
  IF v_total IS NULL OR v_total <= 0 THEN RETURN NULL; END IF;

  -- (215) The Zelle share is priced at the tier of the deposit's TOTAL; the other USD shares keep the single rate.
  SELECT z.tasa INTO v_zrate FROM cerebro_zelle_cotizar_gyd(v_total) z;
  v_zrate := coalesce(v_zrate, v_usd);

  -- Exactly one vigente Zelle without a human amount; every other vigente share priced.
  IF (SELECT count(*) FROM remittance_beneficiaries
       WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type = 'zelle'
         AND (amount IS NULL OR amount_origin = 'calculated')) <> 1
     OR (SELECT count(*) FROM remittance_beneficiaries
          WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type = 'zelle') <> 1
     OR EXISTS (SELECT 1 FROM remittance_beneficiaries
                 WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type <> 'zelle'
                   AND (amount IS NULL OR currency NOT IN ('CUP', 'USD'))) THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_zelle FROM remittance_beneficiaries
   WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type = 'zelle';

  SELECT v_total - coalesce(sum(CASE WHEN currency = 'CUP' THEN amount / v_cup ELSE amount * v_usd END), 0)
    INTO v_resto
    FROM remittance_beneficiaries
   WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type <> 'zelle';

  v_monto := floor(v_resto / v_zrate);
  IF v_monto <= 0 THEN v_monto := NULL; END IF;

  UPDATE remittance_beneficiaries
     SET amount = v_monto,
         currency = CASE WHEN v_monto IS NULL THEN NULL ELSE 'USD' END,
         amount_origin = CASE WHEN v_monto IS NULL THEN NULL ELSE 'calculated' END
   WHERE id = v_zelle
     AND (amount IS DISTINCT FROM v_monto OR (v_monto IS NOT NULL AND amount_origin IS DISTINCT FROM 'calculated'));
  RETURN v_monto;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_aplicar_reparto(p_operation_id uuid, p_reparto jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_suma_zelle numeric := 0;
  v_n_otro_usd integer := 0;
  v_zrate     numeric;
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
    -- (215) Zelle shares are priced by tier; the other USD rails (Clasica, Tropical) keep the single rate.
    IF v_tipo = 'zelle' THEN v_suma_zelle := v_suma_zelle + v_monto; ELSIF v_moneda = 'USD' THEN v_n_otro_usd := v_n_otro_usd + 1; END IF;
    v_filas := v_filas || jsonb_build_object('tipo', v_tipo, 'cuenta', v_cuenta, 'celular', v_celular,
                                             'nombre', nullif(btrim(coalesce(v_item->>'nombre', '')), ''),
                                             'monto', v_monto, 'moneda', v_moneda);
  END LOOP;

  IF coalesce(array_length(v_cuentas, 1), 0) < 2 THEN
    RETURN jsonb_build_object('aplicado', false, 'motivo', 'no_es_reparto');
  END IF;
  -- (215) The Zelle tier comes from the TOTAL of the deposit, never from each part.
  SELECT z.tasa INTO v_zrate FROM cerebro_zelle_cotizar_gyd(v_op.quoted_source_amount) z;
  v_zrate := coalesce(v_zrate, v_usd);
  IF (SELECT count(DISTINCT m) FROM unnest(v_monedas) m) = 1 THEN
    -- One currency: the amounts must add up EXACTLY to the deposit.
    v_objetivo := CASE v_monedas[1]
                    WHEN 'USD' THEN CASE WHEN v_n_otro_usd = 0 AND v_suma_zelle > 0 AND v_zrate > 0 THEN floor(v_op.quoted_source_amount / v_zrate)
                                         WHEN v_usd > 0 THEN floor(v_op.quoted_source_amount / v_usd) END
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
    v_suma := (v_suma_usd - v_suma_zelle) * v_usd + v_suma_zelle * v_zrate + v_suma_cup / v_cup;
    v_objetivo := v_op.quoted_source_amount;
    v_resto := v_objetivo - v_suma;
    IF NOT (abs(v_resto) < 0.5 * greatest(v_n_cup, 1) OR (v_resto > 0 AND v_resto < CASE WHEN v_suma_zelle > 0 THEN v_zrate ELSE v_usd END)) THEN
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
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_resolver_operacion_beneficiario(p_conversation_id uuid, p_estados text[], p_cuenta text)
 RETURNS TABLE(resultado text, operation_id uuid, candidatas integer, metodo text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_total     integer;
  v_unica     uuid;
  v_cuenta    text;
  v_es_correo boolean;
  v_es_tarjeta boolean;
  v_usd       numeric := crm_tasa_vigente('usd');
  v_cup       numeric := crm_tasa_vigente('gyd');
  v_desde     timestamptz;
  v_anchor_i  integer;
  v_anchor_t  timestamptz;
  v_m         record;
  v_num       text[];
  v_n         numeric;
  v_hit       uuid;
  v_hits      integer;
  v_cand      boolean;
  v_newest    uuid;
BEGIN
  -- (213) A visa and a combo are never the remesa target (the writers refuse them): they are not candidates here.
  -- 0/1 open operation: identical to cerebro_resolver_operacion.
  SELECT count(*) INTO v_total FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados));
  IF v_total = 0 THEN
    RETURN QUERY SELECT 'ninguna'::text, NULL::uuid, 0, 'ninguna'::text; RETURN;
  ELSIF v_total = 1 THEN
    SELECT o.id INTO v_unica FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
       AND (p_estados IS NULL OR o.status = ANY(p_estados));
    RETURN QUERY SELECT 'unica'::text, v_unica, 1, 'unica'::text; RETURN;
  END IF;

  -- Several: normalize the account the node is about to register.
  v_cuenta := lower(regexp_replace(coalesce(p_cuenta,''), '\s', '', 'g'));
  v_es_correo := position('@' in v_cuenta) > 0;
  IF NOT v_es_correo THEN
    v_cuenta := regexp_replace(v_cuenta, '\D', '', 'g');
    IF length(v_cuenta) = 11 AND left(v_cuenta, 1) = '1' THEN v_cuenta := substr(v_cuenta, 2); END IF;
  END IF;
  v_es_tarjeta := NOT v_es_correo AND length(v_cuenta) = 16;
  IF v_cuenta = '' THEN
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'sin_cuenta'::text; RETURN;
  END IF;

  -- The customer's messages since the oldest open operation (minus 3 h), in
  -- order, normalized, with their position.
  SELECT min(o.created_at) - interval '3 hours' INTO v_desde FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled');

  -- 1. Reparto guard.
  IF EXISTS (SELECT 1 FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) WHERE txt ~ '(personas|a cada|repart|una de las|mexico|méxico)') THEN
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'reparto'::text; RETURN;
  END IF;

  -- 3. Anchor: the MOST RECENT message that contains the account (133); else latest image.
  --    A customer who reuses an account for a new remesa writes it again: the first time it
  --    appeared belongs to the OLD remesa (1727ef31, de846b30).
  SELECT b.i, b.t INTO v_anchor_i, v_anchor_t FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b
   WHERE (v_es_correo AND replace(b.txt, ' ', '') LIKE '%' || v_cuenta || '%')
      OR (NOT v_es_correo AND regexp_replace(b.txt, '\D', '', 'g') LIKE '%' || v_cuenta || '%')
   ORDER BY b.i DESC LIMIT 1;
  IF v_anchor_i IS NULL THEN
    SELECT b.i, b.t INTO v_anchor_i, v_anchor_t FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b WHERE b.tipo = 'image' ORDER BY b.i DESC LIMIT 1;
  END IF;
  IF v_anchor_i IS NULL THEN v_anchor_t := now(); END IF;

  -- 4. Amount written next to the account.
  IF v_anchor_i IS NOT NULL THEN
    FOR v_m IN
      SELECT b.* FROM cerebro_mensajes_cliente_normalizados(p_conversation_id, v_desde) b
       WHERE b.tipo = 'text' AND abs(b.i - v_anchor_i) <= 3
         AND abs(extract(epoch FROM b.t - v_anchor_t)) <= 180
       ORDER BY abs(b.i - v_anchor_i), b.i
    LOOP
      FOR v_num IN
        SELECT regexp_matches(v_m.txt,
          '(?:^|[^0-9.,])([0-9]{1,3}(?:[.,][0-9]{3})+|[0-9]{2,6})(?![0-9])\s*(usd|zelle|d[oó]lar(?:es)?|\$|cup|pesos)?', 'g')
      LOOP
        IF v_num[2] IS NULL AND btrim(v_m.txt) <> btrim(v_num[1])
           AND v_m.txt !~ '(zelle|usd|d[oó]lar|cup|tarjeta|\$)' THEN
          CONTINUE;
        END IF;
        v_n := replace(replace(v_num[1], '.', ''), ',', '')::numeric;
        SELECT count(*), min(o.id::text)::uuid INTO v_hits, v_hit FROM remittance_operations o
         WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
           AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
           AND (p_estados IS NULL OR o.status = ANY(p_estados))
           -- (215) A Zelle account is paired by the tiered USD of the deposit; a card (Clasica, Tropical) by the single rate.
           AND ((NOT v_es_tarjeta AND (SELECT z.usd FROM cerebro_zelle_cotizar_gyd(o.quoted_source_amount) z) = v_n)
                OR (v_es_tarjeta AND v_usd > 0 AND floor(o.quoted_source_amount / v_usd) = v_n)
                OR (v_es_tarjeta AND v_cup > 0 AND round(o.quoted_source_amount * v_cup) = v_n));
        IF v_hits = 1 THEN
          SELECT NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente')
              OR EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente'
                          AND (lower(coalesce(rb.zelle_account,'')) = v_cuenta
                               OR regexp_replace(coalesce(rb.zelle_account, rb.card_number, ''), '\D', '', 'g') IN (v_cuenta, '1' || v_cuenta)))
            INTO v_cand;
          IF v_cand THEN
            RETURN QUERY SELECT 'unica'::text, v_hit, v_total, 'monto'::text; RETURN;
          END IF;
          RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'monto_apunta_a_otra'::text; RETURN;
        END IF;
      END LOOP;
    END LOOP;
  END IF;

  -- 5. Proximity: exactly one open remesa created within 5 minutes.
  SELECT count(*), min(o.id::text)::uuid INTO v_hits, v_hit FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
     AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados))
     AND abs(extract(epoch FROM o.created_at - v_anchor_t)) <= 300;
  IF v_hits = 1 THEN
    SELECT NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente')
        OR EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_hit AND rb.status = 'vigente'
                    AND (lower(coalesce(rb.zelle_account,'')) = v_cuenta
                         OR regexp_replace(coalesce(rb.zelle_account, rb.card_number, ''), '\D', '', 'g') IN (v_cuenta, '1' || v_cuenta)))
      INTO v_cand;
    IF v_cand THEN
      RETURN QUERY SELECT 'unica'::text, v_hit, v_total, 'cercania'::text; RETURN;
    END IF;
    RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'cercania_apunta_a_otra'::text; RETURN;
  END IF;

  -- 6. Rule C.
  SELECT o.id INTO v_newest FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id AND o.service_type = 'remesa'
     AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
     AND (p_estados IS NULL OR o.status = ANY(p_estados))
   ORDER BY o.created_at DESC LIMIT 1;
  IF v_newest IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = v_newest AND rb.status = 'vigente')
     AND NOT EXISTS (
       SELECT 1 FROM remittance_operations o
        WHERE o.conversation_id = p_conversation_id AND o.id <> v_newest
          AND o.service_type NOT IN ('visa', 'combo') AND o.status NOT IN ('completed','cancelled')
          AND (p_estados IS NULL OR o.status = ANY(p_estados))
          AND o.created_at >= now() - interval '24 hours'
          AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries rb WHERE rb.operation_id = o.id AND rb.status = 'vigente'))
  THEN
    RETURN QUERY SELECT 'unica'::text, v_newest, v_total, 'regla_c'::text; RETURN;
  END IF;

  RETURN QUERY SELECT 'ambigua'::text, NULL::uuid, v_total, 'sin_evidencia'::text;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_fijar_objetivo(p_conv uuid, p_monto numeric, p_moneda text DEFAULT 'GYD'::text)
 RETURNS TABLE(objetivo_gyd numeric, pedido text, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mon        text;
  v_gyd        numeric;
  v_pedido     text;
  v_tasa       numeric;
  v_previo     numeric;
  v_cerrado    timestamptz;
  v_accion     text;
  v_compromiso boolean;
BEGIN
  v_mon := lower(COALESCE(NULLIF(trim(p_moneda), ''), 'gyd'));

  IF p_monto IS NULL OR p_monto <= 0 THEN
    RETURN QUERY SELECT NULL::numeric, NULL::text,
      'NO se fijo nada: el importe no es valido'::text; RETURN;
  END IF;

  -- (148) Sin beneficiario ni comprobante todavia, esto es solo una
  -- cotizacion: el cliente puede estar preguntando por curiosidad, sin
  -- intencion de enviar. No se fija nada — calcular_usd ya le dio el
  -- numero, que es lo unico que pidio.
  -- (152) El compromiso tiene que ser de ESTE envio, no de uno ya cerrado.
  -- La 148 contaba cualquier beneficiario vigente (tambien de remesas
  -- completadas) y cualquier comprobante que el telefono hubiera mandado
  -- nunca: un cliente recurrente siempre pasaba y una cotizacion suelta
  -- seguia fijando objetivo. Ahora: beneficiario vigente de una operacion
  -- ABIERTA, o un comprobante recibido DESPUES de su ultima remesa cerrada.
  SELECT
    EXISTS (
      SELECT 1 FROM remittance_operations o
        JOIN remittance_beneficiaries b ON b.operation_id = o.id
       WHERE o.conversation_id = p_conv AND b.status = 'vigente'
         AND o.status NOT IN ('completed', 'cancelled')
    )
    OR EXISTS (
      SELECT 1 FROM comprobantes_hashes ch
        JOIN conversations v ON v.id = p_conv
        JOIN contacts c ON c.id = v.contact_id
       WHERE ch.cliente_whatsapp = c.phone
         AND ch.fecha_recibido > COALESCE(
               (SELECT max(COALESCE(o2.completed_at, o2.cancelled_at, o2.created_at))
                  FROM remittance_operations o2
                 WHERE o2.conversation_id = p_conv
                   AND o2.status IN ('completed', 'cancelled')),
               '-infinity'::timestamptz)
    )
    INTO v_compromiso;

  IF NOT v_compromiso THEN
    RETURN QUERY SELECT NULL::numeric, NULL::text,
      'NO se fijo nada: sin beneficiario ni comprobante todavia (solo cotizacion)'::text;
    RETURN;
  END IF;

  IF v_mon = 'gyd' THEN
    v_gyd    := round(p_monto);
    v_pedido := rtrim(trim(to_char(v_gyd,'FM999,999,999,990.99')),'.') || ' GYD';
  ELSIF v_mon = 'usd' THEN
    SELECT t.tasa_cup INTO v_tasa FROM tasas t
     WHERE t.moneda = 'usd' ORDER BY t.fecha DESC, t.actualizada_at DESC LIMIT 1;
    -- (215) The USD asked for is Zelle dollars: priced at the tier its amount reaches.
    v_tasa := coalesce(cerebro_tasa_zelle(floor(p_monto)), v_tasa);
    IF v_tasa IS NULL THEN
      RETURN QUERY SELECT NULL::numeric, NULL::text,
        'NO se fijo nada: no hay tasa de USD'::text; RETURN;
    END IF;
    -- floor, igual que calcular_usd: los dolares se entregan enteros.
    v_gyd    := round(floor(p_monto) * v_tasa);
    v_pedido := rtrim(trim(to_char(floor(p_monto),'FM999,999,999,990')),'.') || ' USD';
  ELSE
    RETURN QUERY SELECT NULL::numeric, NULL::text,
      ('NO se fijo nada: moneda no soportada (' || p_moneda || '). Solo GYD o USD')::text; RETURN;
  END IF;

  SELECT o.monto, o.cerrado_en INTO v_previo, v_cerrado
    FROM cerebro_objetivo_envio o WHERE o.conversation_id = p_conv;

  IF v_previo IS NULL THEN
    v_accion := 'objetivo fijado';
  ELSIF v_cerrado IS NOT NULL THEN
    v_accion := 'envio nuevo: el anterior ya se completo';
  ELSIF v_previo = v_gyd THEN
    v_accion := 'sin cambios, ya estaba fijado';
  ELSE
    v_accion := 'objetivo sustituido (antes '
                || rtrim(trim(to_char(v_previo,'FM999,999,999,990.99')),'.') || ' GYD)';
  END IF;

  INSERT INTO cerebro_objetivo_envio AS o (conversation_id, monto, moneda, pedido)
  VALUES (p_conv, v_gyd, 'GYD', v_pedido)
  ON CONFLICT (conversation_id) DO UPDATE
     SET monto      = EXCLUDED.monto,
         moneda     = 'GYD',
         pedido     = EXCLUDED.pedido,
         fijado_en  = now(),
         deal_id    = CASE WHEN o.cerrado_en IS NOT NULL THEN NULL ELSE o.deal_id END,
         cerrado_en = NULL;

  RETURN QUERY SELECT v_gyd, v_pedido, v_accion;
END;
$function$;

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
  SELECT z.tasa INTO v_zrate FROM cerebro_zelle_cotizar_gyd(v_op.quoted_source_amount) z;

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
    -- (209) a combo whose cost the admin has not entered yet stays pending
    IF v_part.service = 'COMBO' AND v_op.combo_costo_gyd IS NULL THEN
      v_missing := v_missing || ARRAY['comboCosto'];
    END IF;
    v_currency  := CASE WHEN v_part.service = 'CUP' THEN 'CUP' WHEN v_part.service = 'RECARGA' THEN 'REC'
                        WHEN v_part.service IN ('COMBO', 'VISA') THEN 'GYD' ELSE 'USD' END;
    -- (193) The sale rate of the line: a cash dollar sells at efectivo_usd_gyd; every other USD service at
    -- usdt_sell_gyd. The cost (usdt_buy_gyd) is shared. Snapshotted in usdt_sell_gyd (= the sale rate used).
    v_sell      := CASE WHEN v_part.service = 'EFECTIVO' THEN v_rates.efectivo_usd_gyd
                        -- (199) a recharge sells at the price its deposit pays (198 cerebro_recarga_precio)
                        WHEN v_part.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis)
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
           WHEN v_part.service = 'RECARGA' THEN v_rates.usdt_buy_gyd ELSE v_rates.usdt_sell_cup END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_rates.usdt_buy_gyd END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_sell END, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp()),
      CASE WHEN v_part.service = 'RECARGA' THEN v_rates.recarga_costo_usdt
           WHEN v_part.service = 'COMBO' THEN v_op.combo_costo_gyd
           WHEN v_part.service = 'VISA' THEN 0 END,
      CASE WHEN v_part.service = 'RECARGA' THEN v_sell
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
    WHERE remittance_calculator_entries.status = 'void'
    RETURNING id INTO v_entry_id;

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_resolve_pending_entry(p_entry_id uuid, p_rates jsonb, p_reason text)
 RETURNS remittance_calculator_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry     remittance_calculator_entries;
  v_before    jsonb;
  v_basis     numeric;
  v_cup_glob  numeric;
  v_cup_rate  numeric;
  v_buy       numeric;
  v_sell      numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_missing   text[];
  v_key       text;
  v_value     numeric;
  v_zrate     numeric;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin') THEN
    RAISE EXCEPTION 'not authorized to resolve ledger entries' USING ERRCODE = '42501';
  END IF;

  IF v_entry.status <> 'verified_pending' THEN
    RAISE EXCEPTION 'only a pending entry can be resolved' USING ERRCODE = '22023';
  END IF;

  -- (209) A COMBO line is priced by the combo's cost (crm_set_combo_costo, panel), never by rates.
  IF v_entry.service = 'COMBO' THEN
    RAISE EXCEPTION 'a combo line is resolved by entering the combo cost in the panel, not with rates' USING ERRCODE = '22023';
  END IF;

  -- (213) A VISA line never needs rates (facturado = the deposit, invertido = 0): nothing to resolve with them.
  IF v_entry.service = 'VISA' THEN
    RAISE EXCEPTION 'a visa line needs no rates: it is priced by its deposit' USING ERRCODE = '22023';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'a reason of at least 5 characters is required' USING ERRCODE = '22023';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' OR p_rates = '{}'::jsonb THEN
    RAISE EXCEPTION 'no rates provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_rates) LOOP
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup', 'efectivo_usd_gyd') THEN
      RAISE EXCEPTION 'unknown rate: %', v_key USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_rates -> v_key) <> 'number' THEN
      RAISE EXCEPTION 'rate % must be a number', v_key USING ERRCODE = '22023';
    END IF;
    v_value := (p_rates ->> v_key)::numeric;
    IF v_value <= 0 OR v_value >= 1e9 THEN
      RAISE EXCEPTION 'rate % must be greater than 0 and less than 1e9', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_before := to_jsonb(v_entry);

  -- coalesce, not overwrite: what the entry already recorded wins.
  v_cup_glob := coalesce(v_entry.cup_global_rate, (p_rates ->> 'cup_global_rate')::numeric);
  v_cup_rate := coalesce(v_entry.cup_rate,        (p_rates ->> 'usdt_sell_cup')::numeric);
  v_buy      := coalesce(v_entry.usdt_buy_gyd,    (p_rates ->> 'usdt_buy_gyd')::numeric);
  -- (193) A cash line sells at the cash rate.
  v_sell     := coalesce(v_entry.usdt_sell_gyd,
                         CASE WHEN v_entry.service = 'EFECTIVO' THEN (p_rates ->> 'efectivo_usd_gyd')::numeric
                              ELSE (p_rates ->> 'usdt_sell_gyd')::numeric END);

  -- (215) A ZELLE line whose operation's deposit total reaches a tier above the base one sells at that tier, not at
  -- the rate the payload carries. A deposit in the base tier keeps the rate the admin entered, and a line still
  -- missing its sell rate keeps asking for it (the required-rate check below is unchanged).
  IF v_entry.service = 'ZELLE' AND v_sell IS NOT NULL THEN
    SELECT z.tasa INTO v_zrate
      FROM remittance_operations o, cerebro_zelle_cotizar_gyd(o.quoted_source_amount) z
     WHERE o.id = v_entry.operation_id;
    IF v_zrate IS NOT NULL AND v_zrate < cerebro_tasa_zelle(50) THEN
      v_sell := coalesce(v_entry.usdt_sell_gyd, v_zrate);
    END IF;
  END IF;

  IF v_entry.service = 'CUP' THEN
    v_missing := array_remove(ARRAY[
      CASE WHEN v_cup_glob IS NULL THEN 'cupGlobalRate' END,
      CASE WHEN v_cup_rate IS NULL THEN 'usdtSellCup'   END,
      CASE WHEN v_buy      IS NULL THEN 'usdtBuyGyd'    END
    ], NULL);
  ELSE
    v_missing := array_remove(ARRAY[
      CASE WHEN v_buy  IS NULL THEN 'usdtBuyGyd'  END,
      CASE WHEN v_sell IS NULL THEN CASE WHEN v_entry.service = 'EFECTIVO' THEN 'efectivoUsdGyd' ELSE 'usdtSellGyd' END END
    ], NULL);
  END IF;

  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'still missing required rate(s): %', array_to_string(v_missing, ', ')
      USING ERRCODE = '22023';
  END IF;

  -- The deposit is re-read from the operation rather than trusted from the
  -- pending row, whose `amount` column held the deposit as a placeholder.
  -- (142) A line of a MIXED remesa is priced on its own share of the
  -- deposit (basis_gyd), never on the whole deposit.
  IF v_entry.basis_gyd IS NOT NULL THEN
    v_basis := v_entry.basis_gyd;
  ELSIF EXISTS (SELECT 1 FROM remittance_calculator_entries o
                 WHERE o.account_id = v_entry.account_id
                   AND o.operation_id = v_entry.operation_id
                   AND o.source = 'completed_operation'
                   AND o.service <> v_entry.service
                   AND o.status <> 'void') THEN
    RAISE EXCEPTION 'this line belongs to a mixed remesa whose share is unknown: fix the beneficiary amounts and re-feed the operation'
      USING ERRCODE = '22023';
  ELSE
    SELECT quoted_source_amount INTO v_basis
      FROM remittance_operations WHERE id = v_entry.operation_id;
  END IF;

  v_amount    := calculator_amount_from_basis(v_entry.service, v_basis, v_cup_glob, v_sell);
  v_facturado := calculator_facturado(v_entry.service, v_amount, v_cup_glob, v_sell);
  v_invertido := calculator_invertido(v_entry.service, v_amount, v_cup_rate, v_buy);

  IF v_amount IS NULL OR v_facturado IS NULL OR v_invertido IS NULL THEN
    RAISE EXCEPTION 'the operation has no usable deposit amount to price' USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_calculator_entries
     SET status          = 'completed',
         amount          = v_amount,
         cup_global_rate = v_cup_glob,
         cup_rate        = v_cup_rate,
         usdt_buy_gyd    = v_buy,
         usdt_sell_gyd   = v_sell,
         facturado_gyd   = v_facturado,
         invertido_gyd   = v_invertido,
         retorno_gyd     = v_facturado - v_invertido,
         missing_inputs  = NULL
   WHERE id = p_entry_id
   RETURNING * INTO v_entry;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, action, actor, reason, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id,
          'calculator_pending_resolved', wacrm_current_actor(), btrim(p_reason),
          v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$function$;
