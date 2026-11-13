-- Rollback of 369: restores _cerebro_reparto_planear to its 277 body (live production body read 2026-11-13). The agreed amounts written by
-- plans already made stay (they are audited agreed amounts, not money).

CREATE OR REPLACE FUNCTION public._cerebro_reparto_planear(p_conv uuid, p_partes jsonb, p_abrir boolean, p_actor text DEFAULT 'agent:repartir_envio'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n int; v_d int; v_total numeric; v_e jsonb;
BEGIN
  SELECT count(*), count(DISTINCT e ->> 'servicio'), sum((e ->> 'monto_gyd')::numeric)
    INTO v_n, v_d, v_total FROM jsonb_array_elements(p_partes) e;
  IF coalesce(v_n, 0) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'texto', 'No se pudo repartir: hacen falta al menos dos servicios (detalle: at least two parts are required). No cambie nada.');
  END IF;
  IF v_d <> v_n THEN
    RETURN jsonb_build_object('ok', false, 'texto', 'No se pudo repartir: hay un servicio repetido. No cambie nada.');
  END IF;
  INSERT INTO cerebro_reparto_planeado (conversation_id, partes, total_gyd, actor, creado_at)
  VALUES (p_conv, p_partes, v_total, p_actor, now())
  ON CONFLICT (conversation_id) DO UPDATE SET partes = EXCLUDED.partes, total_gyd = EXCLUDED.total_gyd, actor = EXCLUDED.actor, creado_at = now();
  IF p_abrir THEN
    FOR v_e IN SELECT e FROM jsonb_array_elements(p_partes) e LOOP
      PERFORM _cerebro_op_parte(p_conv, v_e ->> 'servicio', p_actor, 'planned split part');
    END LOOP;
  END IF;
  RETURN jsonb_build_object('ok', true, 'total', v_total, 'texto',
    'Reparto planeado (todavia sin deposito, nada aplicado): ' || _cerebro_texto_partes(p_partes) || '. Total ' || _cerebro_fmt_monto(v_total)
    || ' GYD. Cada parte tiene ya su operacion vacia donde guardar sus datos; cuando llegue un deposito de exactamente '
    || _cerebro_fmt_monto(v_total) || ' GYD se reparte solo. Si el deposito es otro, repartir_envio dara los hechos para preguntarle al cliente.');
END $function$;
