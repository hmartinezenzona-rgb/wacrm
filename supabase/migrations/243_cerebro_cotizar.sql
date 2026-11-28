-- =====================================================================
-- 243 -- cerebro_cotizar: one quote function behind the four calculator tools
--
-- odd/tasks/cerebro-tool-consolidation.md (T3). Owner 2026-10-17 ("si confimo", then "si
-- intentalo"): merge the four calculator tools the agent sees (calcular_envio, calcular_inverso,
-- calcular_usd, calcular_usd_desde_gyd) into one, so the model picks a DIRECTION and a DESTINATION
-- CURRENCY as parameters instead of picking one of four tool names, and the prompt lines that teach
-- that routing (101-117 of the system message) can go.
--
-- MEASURED REASON (T2 baseline of record, gold battery, two runs, 97% stability, 2026-10-17): the
-- ONLY two stable reds in the whole battery are calculator cases -- reg-27486 (the model did not
-- call calcular_usd) and reg-30178 (wrong figure). Every other stable case is green. The four-way
-- split by tool NAME is where the agent actually fails.
--
-- PURELY ADDITIVE. This migration creates ONE function and changes NOTHING that already exists.
-- The four tools live in the n8n workflow, not in the database, so until that workflow is edited
-- (a separate step, reversible by PUTting the saved JSON back) the Cerebro behaves exactly as
-- today. The rollback is a DROP.
--
-- Each branch is the body of its tool VERBATIM: the same rate row, the same rounding (round for
-- GYD->CUP, ceil-to-20 for CUP->GYD, floor for both USD directions), the same Zelle tier helpers
-- (cerebro_tasa_zelle for a USD amount, cerebro_zelle_cotizar_gyd for a GYD amount), and
-- cerebro_fijar_objetivo ONLY on the USD-send direction, exactly where calcular_usd had it.
--
-- The per-direction HERRAMIENTA LABEL is preserved when calling cerebro_registrar_cotizacion and
-- cerebro_registrar_via_cotizada ('calcular_envio', 'calcular_inverso', 'calcular_usd',
-- 'calcular_usd_desde_gyd'), so cerebro_ultima_cotizacion, the tool_execution_log rows and the
-- coherence net cerebro_verificar_coherencia_servicio keep exactly the meaning they have today.
-- Merging the tools must not rename the evidence they leave behind.
--
-- TWO DELIBERATE DIVERGENCES from today's behaviour, both asserted in
-- supabase/staging/assertions/cerebro-cotizar.sql:
--
--  1. EFECTIVO IS REFUSED. Today via='efectivo' does NOT match the single-rate regex
--     '^(cl[aá]sica|tropical|m[eé]xico|usdt)', so calcular_usd and calcular_usd_desde_gyd quote it
--     SILENTLY AS ZELLE, by tiers -- the wrong rate, with no sign that anything went wrong. The
--     prompt tries to prevent that in three separate places (lines 106, 163 and 179). A prompt
--     instruction is not a control: the comment inside calcular_usd says exactly that, after
--     fijar_objetivo was measured 0 of 2 as a prompt instruction. So the function refuses and names
--     consultar_servicio('efectivo_usd'), which owns the cash rate.
--
--  2. THE DEPOSIT CURRENCY IS NO LONGER A MODEL PARAMETER. The two CUP tools took a `moneda`
--     argument described to the model as "siempre gyd. NUNCA usd". Its non-gyd path was dead in
--     practice and, if ever taken, would have silently changed the rounding of calcular_inverso
--     (plain ceil instead of ceil-to-20). The customer always deposits guyanese dollars, so it is a
--     constant here and cannot be got wrong.
--
-- Grants: service_role only, like cerebro_cambiar_servicio and cerebro_marcar_destino_usd.
-- No BEGIN/COMMIT in this file.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_cotizar(
  p_conv            uuid,
  p_monto           numeric,
  p_direccion       text,
  p_moneda_destino  text,
  p_via             text DEFAULT NULL,
  p_execution_id    text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  -- El cliente SIEMPRE deposita guyaneses: ver la divergencia 2 de la cabecera.
  c_origen  constant text := 'gyd';
  v_dir     text := lower(btrim(coalesce(p_direccion, '')));
  v_dest    text := lower(btrim(coalesce(p_moneda_destino, '')));
  v_via     text := lower(btrim(coalesce(p_via, '')));
  v_unica   boolean;
  v_tasa_u  numeric;   -- la tasa unica de usd (Clasica, Tropical, Mexico, USDT)
  v_tasa    numeric;   -- la tasa que se aplica de verdad a esta cotizacion
  v_gyd     numeric;   -- lo que deposita el cliente
  v_destino numeric;   -- lo que recibe el beneficiario
  v_usd     numeric;
  v_exacto  numeric;   -- solo gyd->usd: los GYD exactos de esos dolares enteros
  v_aplica  text;
  v_herr    text;      -- la etiqueta por direccion, preservada para la auditoria
BEGIN
  IF p_conv IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'sin_conversacion');
  END IF;
  IF p_monto IS NULL OR p_monto <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'monto_invalido');
  END IF;

  -- Direccion. 'desde_deposito' = el cliente dice lo que DEPOSITA y quiere saber que llega;
  -- 'hacia_destino' = dice lo que quiere que LLEGUE y quiere saber cuanto depositar.
  IF v_dir IN ('desde_deposito', 'deposito', 'desde') THEN
    v_dir := 'desde_deposito';
  ELSIF v_dir IN ('hacia_destino', 'destino', 'hacia') THEN
    v_dir := 'hacia_destino';
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'direccion_desconocida',
                              'direccion', p_direccion,
                              'validas', jsonb_build_array('desde_deposito', 'hacia_destino'));
  END IF;

  IF v_dest IN ('cup', 'pesos', 'pesos_cubanos') THEN
    v_dest := 'cup';
  ELSIF v_dest IN ('usd', 'dolares', 'dolar') THEN
    v_dest := 'usd';
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'moneda_destino_desconocida',
                              'moneda_destino', p_moneda_destino,
                              'validas', jsonb_build_array('cup', 'usd'));
  END IF;

  -- Divergencia 1: el efectivo tiene su propia tasa y su propia tool. Antes se colaba como Zelle.
  IF v_via ~ '^efectivo' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'efectivo_tiene_tasa_propia',
                              'usa', 'consultar_servicio(''efectivo_usd'')');
  END IF;

  IF v_dest = 'cup' THEN
    -- ---------------------------------------------------------------- CUP
    SELECT t.tasa_cup INTO v_tasa
      FROM tasas t
     WHERE t.moneda = c_origen
     ORDER BY t.fecha DESC, t.actualizada_at DESC
     LIMIT 1;
    IF v_tasa IS NULL OR v_tasa <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', c_origen);
    END IF;

    IF v_dir = 'desde_deposito' THEN           -- era calcular_envio
      v_herr    := 'calcular_envio';
      v_gyd     := p_monto;
      v_destino := round(p_monto * v_tasa);
    ELSE                                        -- era calcular_inverso
      v_herr    := 'calcular_inverso';
      v_destino := p_monto;
      -- ceil al multiplo de 20 superior, igual que calcular_inverso con moneda='gyd'
      v_gyd     := ceil((p_monto / v_tasa) / 20) * 20;
    END IF;
    v_aplica := 'Tarjeta en CUP';

    PERFORM cerebro_registrar_cotizacion(p_conv, v_gyd, v_destino, 'CUP', v_herr);
    PERFORM cerebro_registrar_via_cotizada(p_conv, v_herr, 'cuban_card', p_execution_id, NULL);

    RETURN jsonb_build_object(
      'ok', true, 'herramienta', v_herr, 'direccion', v_dir,
      'deposita_gyd', v_gyd, 'recibe_monto', v_destino, 'recibe_moneda', 'CUP',
      'tasa', v_tasa, 'aplica_a', v_aplica);
  END IF;

  -- ------------------------------------------------------------------ USD
  -- Zelle va por TRAMOS de USD; Clasica, Tropical, Mexico y USDT tienen tasa unica. Vacio = Zelle,
  -- igual que hoy.
  v_unica := (coalesce(nullif(v_via, ''), 'zelle') ~ '^(cl[aá]sica|tropical|m[eé]xico|usdt)');
  SELECT t.tasa_cup INTO v_tasa_u
    FROM tasas t
   WHERE t.moneda = 'usd'
   ORDER BY t.fecha DESC, t.actualizada_at DESC
   LIMIT 1;
  v_aplica := CASE WHEN v_unica THEN 'Clasica/Tropical/Mexico (tasa unica)'
                   ELSE 'Zelle (por tramos)' END;

  IF v_dir = 'hacia_destino' THEN               -- era calcular_usd
    v_herr := 'calcular_usd';
    -- floor y no round: los dolares SIEMPRE se entregan enteros, y redondear hacia arriba
    -- prometeria un dolar mas de lo que cubre el deposito.
    v_usd  := floor(p_monto);
    IF v_usd <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'monto_invalido');
    END IF;
    v_tasa := CASE WHEN v_unica THEN v_tasa_u
                   ELSE coalesce(cerebro_tasa_zelle(v_usd), v_tasa_u) END;
    IF v_tasa IS NULL OR v_tasa <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', 'usd');
    END IF;
    v_gyd     := round(v_usd * v_tasa);
    v_destino := v_usd;
    -- Apunta el objetivo del envio (072/075) para que un deposito que no lo cubra no se de por
    -- bueno. Va aqui y no en una tool aparte porque el modelo no llama a la tool aparte: se monto
    -- `fijar_objetivo`, se le ordeno en dos sitios del prompt, y fue 0 de 2 con mensajes reales.
    PERFORM * FROM cerebro_fijar_objetivo(p_conv, v_usd, 'USD');
  ELSE                                           -- era calcular_usd_desde_gyd
    v_herr := 'calcular_usd_desde_gyd';
    v_gyd  := p_monto;
    IF v_unica THEN
      IF v_tasa_u IS NULL OR v_tasa_u <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', 'usd');
      END IF;
      v_tasa := v_tasa_u;
      v_usd  := floor(p_monto / v_tasa_u);
    ELSE
      SELECT z.usd, z.tasa INTO v_usd, v_tasa
        FROM cerebro_zelle_cotizar_gyd(p_monto) z;
      -- el COALESCE a la tasa unica es el de calcular_usd_desde_gyd, no una invencion
      IF v_tasa IS NULL OR v_tasa <= 0 THEN
        IF v_tasa_u IS NULL OR v_tasa_u <= 0 THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', 'usd');
        END IF;
        v_tasa := v_tasa_u;
      END IF;
      v_usd := coalesce(v_usd, floor(p_monto / v_tasa_u));
    END IF;
    v_destino := v_usd;
    v_exacto  := round(v_usd * v_tasa);
  END IF;

  PERFORM cerebro_registrar_cotizacion(p_conv, v_gyd, v_destino, 'USD', v_herr);
  PERFORM cerebro_registrar_via_cotizada(p_conv, v_herr, nullif(v_via, ''), p_execution_id, v_gyd);

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'ok', true, 'herramienta', v_herr, 'direccion', v_dir,
    'deposita_gyd', v_gyd, 'recibe_monto', v_destino, 'recibe_moneda', 'USD',
    'tasa', v_tasa, 'aplica_a', v_aplica,
    'via', nullif(v_via, ''),
    'deposita_gyd_exacto', v_exacto));
END;
$function$;

COMMENT ON FUNCTION public.cerebro_cotizar(uuid, numeric, text, text, text, text) IS
  'Una sola cotizacion para las cuatro direcciones que antes eran calcular_envio, calcular_inverso, '
  'calcular_usd y calcular_usd_desde_gyd (243). Preserva el redondeo y la etiqueta de herramienta de '
  'cada una, para que la auditoria y la red de coherencia no cambien de significado. Rechaza el '
  'efectivo, que antes se colaba como Zelle por tramos.';

REVOKE ALL ON FUNCTION public.cerebro_cotizar(uuid, numeric, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_cotizar(uuid, numeric, text, text, text, text)
  TO service_role;
