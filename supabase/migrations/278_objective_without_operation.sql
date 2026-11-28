-- 278 (the send objective without an operation). Gap 4 of the S5b measurement (odd/notes/db-tools-progress.md): calcular_usd calls
-- cerebro_fijar_objetivo at quote time, but 148 refused to fix anything before a recipient or a receipt existed, so the pre-deposit
-- flow (quote, declare, collect data, pay) lost the objective and an under-deposit was taken as complete.
--   * cerebro_fijar_objetivo(conv, monto, moneda) -> (objetivo_gyd, pedido, accion): signature and return unchanged. The commitment
--     test also accepts a declared service, a planned split or any open operation; the objective is stored at conversation level
--     (operation_id NULL) and the deposit consumes it (cerebro_objetivo_atar_op). A bare quote still fixes nothing.
--   * cerebro_declarar_servicio(conv, servicio, actor) -> jsonb {ok, servicio[, objetivo_gyd]}: the agent quotes first and declares
--     after, so declaring promotes the standing quote (cerebro_ultima_cotizacion, quote window, newer than the last closed
--     operation) to the objective when none is open. An objective already there is never overwritten.
-- Rollback restores both previous bodies (objectives already stored stay).
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
    -- (278) The agent's own act is a commitment too: a service declared for the conversation, a split planned, or an open
    -- operation (even empty). The objective is then kept at conversation level (no operation yet) and the next deposit consumes it
    -- (cerebro_objetivo_atar_op in cerebro_registrar_deposito).
    OR EXISTS (SELECT 1 FROM cerebro_servicio_declarado d WHERE d.conversation_id = p_conv)
    OR EXISTS (SELECT 1 FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = p_conv)
    OR EXISTS (SELECT 1 FROM remittance_operations o3 WHERE o3.conversation_id = p_conv AND o3.status NOT IN ('completed', 'cancelled'))
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

CREATE OR REPLACE FUNCTION public.cerebro_declarar_servicio(p_conv uuid, p_servicio text, p_actor text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_servicio text := lower(btrim(coalesce(p_servicio, '')));
  v_q        numeric;
  v_obj      numeric;
BEGIN
  IF v_servicio NOT IN ('remesa', 'cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd', 'recarga', 'saldo', 'combo', 'visa', 'mexico') THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'servicio_invalido');
  END IF;
  INSERT INTO public.cerebro_servicio_declarado (conversation_id, servicio, declarado_at, actor)
  VALUES (p_conv, v_servicio, now(), p_actor)
  ON CONFLICT (conversation_id) DO UPDATE
    SET servicio = EXCLUDED.servicio, declarado_at = EXCLUDED.declarado_at, actor = EXCLUDED.actor;
  -- (278) The agent usually quotes BEFORE it declares: declaring is the commitment, so the standing quote (this conversation, inside the
  -- quote window, newer than the last closed operation) becomes the send objective when there is none. Never breaks the declaration.
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM cerebro_objetivo_envio o WHERE o.conversation_id = p_conv AND o.cerrado_en IS NULL) THEN
      SELECT q.origen_gyd INTO v_q
        FROM cerebro_ultima_cotizacion q
       WHERE q.conversation_id = p_conv
         AND q.cotizado_en > now() - make_interval(hours => COALESCE(NULLIF(cerebro_config_get('cotizacion_ventana_horas'), '')::int, 6))
         AND q.cotizado_en > COALESCE((SELECT max(COALESCE(o.completed_at, o.cancelled_at)) FROM remittance_operations o
                                        WHERE o.conversation_id = p_conv AND o.status IN ('completed', 'cancelled')), '-infinity'::timestamptz)
       ORDER BY q.cotizado_en DESC LIMIT 1;
      IF v_q IS NOT NULL AND v_q > 0 THEN
        SELECT f.objetivo_gyd INTO v_obj FROM cerebro_fijar_objetivo(p_conv, v_q, 'GYD') f;
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] cerebro_declarar_servicio could not promote the quote for %: %', p_conv, SQLERRM;
  END;
  RETURN jsonb_build_object('ok', true, 'servicio', v_servicio) || CASE WHEN v_obj IS NOT NULL THEN jsonb_build_object('objetivo_gyd', v_obj) ELSE '{}'::jsonb END;
END $function$;
