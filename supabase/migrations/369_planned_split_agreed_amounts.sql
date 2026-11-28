-- 369 -- A split planned before the deposit gives each part its agreed amount.
--
-- Owner test 2026-11-13 (conversation 2ca2cf79; real case d9e9f333): "2 recargas + 50 USD Zelle" -> repartir_envio "recarga 12400, zelle 13000" planned
-- the split, but the Zelle operation stayed at 0 GYD (opened earlier by cerebro_guardar_zelle, which sets no amount) and the panel showed a loose
-- operation at 0. _cerebro_reparto_planear (the plan path of cerebro_repartir_envio) now sets every part operation's amount with
-- _cerebro_fijar_monto_acordado (293): an AGREED amount, audited 'agreed amount (not money)', which _cerebro_op_monto_acordado reads as "no money", so
-- deposit verification, the objetivo and the calculator still treat the operation as unfunded. No mixed_group_id is set before the deposit (the group
-- forms when a deposit of exactly the total arrives, as before): every bot guard that reads grouping is untouched. An amount already agreed and equal
-- (the recarga numbers) is not written twice; an amount a person locked, or an operation holding money, keeps its value (the writer refuses).
-- Body redefined from the live production body (read 2026-11-13, equal to 277/288). Rollback: ROLLBACK-369-planned-split-agreed-amounts.sql.

CREATE OR REPLACE FUNCTION public._cerebro_reparto_planear(p_conv uuid, p_partes jsonb, p_abrir boolean, p_actor text DEFAULT 'agent:repartir_envio'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n int; v_d int; v_total numeric; v_e jsonb; v_op uuid;
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
      v_op := _cerebro_op_parte(p_conv, v_e ->> 'servicio', p_actor, 'planned split part');
      -- (369) the part's amount is AGREED, not money (293): the panel shows the planned send with its amounts and every deposit check keeps
      -- treating the operation as unfunded. An amount already agreed (the recarga numbers) is not written twice; a locked or funded one is kept.
      IF v_op IS NOT NULL THEN
        PERFORM _cerebro_fijar_monto_acordado(v_op, (v_e ->> 'monto_gyd')::numeric, p_actor);
      END IF;
    END LOOP;
  END IF;
  RETURN jsonb_build_object('ok', true, 'total', v_total, 'texto',
    'Reparto planeado (todavia sin deposito, nada aplicado): ' || _cerebro_texto_partes(p_partes) || '. Total ' || _cerebro_fmt_monto(v_total)
    || ' GYD. Cada parte tiene ya su operacion vacia donde guardar sus datos; cuando llegue un deposito de exactamente '
    || _cerebro_fmt_monto(v_total) || ' GYD se reparte solo. Si el deposito es otro, repartir_envio dara los hechos para preguntarle al cliente.');
END $function$;
