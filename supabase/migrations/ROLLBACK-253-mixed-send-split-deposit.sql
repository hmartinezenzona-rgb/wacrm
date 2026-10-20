-- ROLLBACK of 253_mixed_send_split_deposit.sql: restores cerebro_saldo_operacion and cerebro_cruzar_depositos exactly as
-- staging had them on 2026-10-20 (live pg_get_functiondef text), drops crm_repartir_envio and the mixed_group_id column
-- (its index and foreign key go with it). Operations already split keep their quoted_source_amount and its lock; only the
-- grouping is lost. The ACLs of the restored functions are untouched by CREATE OR REPLACE.

DROP FUNCTION IF EXISTS public.crm_repartir_envio(uuid, jsonb);

CREATE OR REPLACE FUNCTION public.cerebro_saldo_operacion(p_op uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH dep AS (
    SELECT COALESCE(sum(m.monto), 0) AS total
      FROM depositos_mmg m
     WHERE m.operation_id = p_op
       AND m.consumido_en IS NOT NULL
       AND m.anulado_en  IS NULL
  ),
  obj AS (
    SELECT o.monto, o.moneda
      FROM cerebro_objetivo_envio o
     WHERE o.conversation_id = (SELECT ro.conversation_id
                                  FROM remittance_operations ro
                                 WHERE ro.id = p_op)
       AND o.cerrado_en IS NULL
       AND (o.operation_id IS NULL OR o.operation_id = p_op)
  )
  SELECT (SELECT monto FROM obj),
         (SELECT total FROM dep),
         (SELECT monto FROM obj) - (SELECT total FROM dep),
         COALESCE((SELECT moneda FROM obj), 'GYD');
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_cruzar_depositos(p_deal uuid, p_refs text[], p_montos numeric[], p_stage_ok uuid, p_stage_incidencia uuid, p_stage_esperado uuid, p_simular boolean DEFAULT false)
 RETURNS TABLE(resultado text, trans_id text, deal_actualizado integer, metodo text, todos_verificados boolean, total_verificado numeric, n_comprobantes integer, detalle jsonb, objetivo numeric, depositado numeric, saldo numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n int; v_i int; v_c record;
  v_det jsonb := '[]'::jsonb; v_todos boolean := true; v_total numeric := 0;
  v_trans1 text := NULL; v_fallo text := NULL; v_metodo text := 'exacto';
  v_nota text; v_tocados int := 0; v_refs_ok int;
  v_obj numeric; v_dep numeric; v_saldo numeric; v_mon text;
  v_stage_final uuid;
  v_op_id uuid;
BEGIN
  -- (160) Resolve either flavour.
  v_op_id := cerebro_resolve_op_id(p_deal);

  -- (182 <- 178) The same receipt twice in one burst (same Ref, same amount) is ONE receipt.
  IF COALESCE(array_length(p_refs, 1), 0) > 1
     AND COALESCE(array_length(p_montos, 1), 0) = array_length(p_refs, 1) THEN
    SELECT array_agg(x.r ORDER BY x.i), array_agg(x.m ORDER BY x.i)
      INTO p_refs, p_montos
      FROM (SELECT DISTINCT ON (regexp_replace(COALESCE(t.r, ''), '[^0-9]', '', 'g'), t.m) t.r, t.m, t.i
              FROM unnest(p_refs, p_montos) WITH ORDINALITY AS t(r, m, i)
             ORDER BY regexp_replace(COALESCE(t.r, ''), '[^0-9]', '', 'g'), t.m, t.i) x;
  END IF;
  v_n := COALESCE(array_length(p_refs, 1), 0);

  -- (182 <- 178) Every Ref already consumed by THIS operation (a resent receipt): report where it
  -- stands and write nothing.
  IF v_n >= 1 AND v_op_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM unnest(p_refs) AS r
        WHERE NOT EXISTS (SELECT 1 FROM depositos_mmg x
                           WHERE x.trans_id = regexp_replace(COALESCE(r, ''), '[^0-9]', '', 'g')
                             AND x.operation_id = v_op_id AND x.consumido_en IS NOT NULL)) THEN
    SELECT s.objetivo, s.depositado, s.saldo INTO v_obj, v_dep, v_saldo FROM cerebro_saldo_operacion(v_op_id) s;
    SELECT COALESCE(sum(m), 0) INTO v_total FROM unnest(p_montos) AS m;
    SELECT jsonb_agg(jsonb_build_object('ref', t.r, 'monto', t.m, 'resultado', 'verificado',
                                        'trans_id', regexp_replace(COALESCE(t.r, ''), '[^0-9]', '', 'g'),
                                        'metodo', 'repetido') ORDER BY t.i)
      INTO v_det FROM unnest(p_refs, p_montos) WITH ORDINALITY AS t(r, m, i);
    RETURN QUERY SELECT
      CASE WHEN v_saldo IS NOT NULL AND v_saldo > 0 THEN 'verificado_incompleto'
           WHEN v_saldo IS NOT NULL AND v_saldo < 0 THEN 'verificado_de_mas'
           ELSE 'verificado' END,
      regexp_replace(COALESCE(p_refs[1], ''), '[^0-9]', '', 'g'), 0, 'repetido'::text, true,
      v_total, v_n, v_det, v_obj, v_dep, v_saldo;
    RETURN;
  END IF;

  SELECT s.objetivo, s.moneda INTO v_obj, v_mon FROM cerebro_saldo_operacion(v_op_id) s;

  IF v_n <= 1 AND v_obj IS NULL THEN
    RETURN QUERY
      SELECT c.resultado, c.trans_id, c.deal_actualizado, c.metodo,
             (c.resultado = 'verificado'),
             CASE WHEN c.resultado = 'verificado' THEN COALESCE(p_montos[1], 0) ELSE 0 END,
             v_n,
             jsonb_build_array(jsonb_build_object(
               'ref', p_refs[1], 'monto', p_montos[1],
               'resultado', c.resultado, 'trans_id', c.trans_id, 'metodo', c.metodo)),
             NULL::numeric, NULL::numeric, NULL::numeric
        FROM cerebro_cruzar_deposito(v_op_id, p_refs[1], p_montos[1],
                                     p_stage_ok, p_stage_incidencia,
                                     p_stage_esperado, p_simular) c;
    RETURN;
  END IF;

  IF v_n > 1 THEN
    IF COALESCE(array_length(p_montos, 1), 0) <> v_n THEN
      v_todos := false;
      v_fallo := 'las referencias y los importes no vienen emparejados';
    END IF;
    IF v_todos THEN
      SELECT count(DISTINCT regexp_replace(COALESCE(r, ''), '[^0-9]', '', 'g'))
        INTO v_refs_ok FROM unnest(p_refs) AS r;
      IF v_refs_ok <> v_n THEN
        v_todos := false;
        v_fallo := 'la misma referencia viene repetida dentro de la rafaga';
      END IF;
    END IF;
  END IF;

  IF v_todos THEN
    FOR v_i IN 1 .. GREATEST(v_n, 1) LOOP
      SELECT * INTO v_c
        FROM cerebro_cruzar_deposito(v_op_id, p_refs[v_i], p_montos[v_i],
                                     p_stage_esperado, p_stage_esperado,
                                     p_stage_esperado, true);
      v_det := v_det || jsonb_build_object(
                 'ref', p_refs[v_i], 'monto', p_montos[v_i],
                 'resultado', v_c.resultado, 'trans_id', v_c.trans_id, 'metodo', v_c.metodo);
      IF v_c.resultado = 'verificado' THEN
        v_total := v_total + COALESCE(p_montos[v_i], 0);
        IF v_trans1 IS NULL THEN v_trans1 := v_c.trans_id; END IF;
        IF v_c.metodo = 'aproximado' THEN v_metodo := 'aproximado'; END IF;
      ELSE
        v_todos := false;
        IF v_fallo IS NULL THEN v_fallo := v_c.resultado; END IF;
      END IF;
    END LOOP;
  END IF;

  IF v_todos AND NOT p_simular THEN
    BEGIN
      v_det := '[]'::jsonb; v_total := 0; v_trans1 := NULL;
      FOR v_i IN 1 .. GREATEST(v_n, 1) LOOP
        SELECT * INTO v_c
          FROM cerebro_cruzar_deposito(v_op_id, p_refs[v_i], p_montos[v_i],
                                       p_stage_esperado, p_stage_esperado,
                                       p_stage_esperado, false);
        v_det := v_det || jsonb_build_object(
                   'ref', p_refs[v_i], 'monto', p_montos[v_i],
                   'resultado', v_c.resultado, 'trans_id', v_c.trans_id, 'metodo', v_c.metodo);
        IF v_c.resultado <> 'verificado' THEN
          RAISE EXCEPTION 'cruce parcial: % en %', v_c.resultado, p_refs[v_i]
            USING ERRCODE = 'data_exception';
        END IF;
        v_total := v_total + COALESCE(p_montos[v_i], 0);
        IF v_trans1 IS NULL THEN v_trans1 := v_c.trans_id; END IF;
        IF v_c.metodo = 'aproximado' THEN v_metodo := 'aproximado'; END IF;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      v_todos := false; v_total := 0; v_trans1 := NULL;
      v_fallo := COALESCE(v_fallo, 'cruce parcial revertido: ' || SQLERRM);
    END;
  END IF;

  SELECT s.objetivo, s.depositado, s.saldo INTO v_obj, v_dep, v_saldo
    FROM cerebro_saldo_operacion(v_op_id) s;
  IF p_simular AND v_obj IS NOT NULL THEN
    v_dep := v_dep + CASE WHEN v_todos THEN v_total ELSE 0 END;
    v_saldo := v_obj - v_dep;
  END IF;

  v_stage_final := CASE
    WHEN NOT v_todos           THEN p_stage_incidencia
    WHEN v_saldo IS NULL       THEN p_stage_ok
    WHEN v_saldo > 0           THEN p_stage_esperado
    WHEN v_saldo < 0           THEN p_stage_incidencia
    ELSE                            p_stage_ok
  END;

  IF NOT p_simular THEN
    -- (160) Write status directly on the operation; no deals touch.
    UPDATE remittance_operations
       SET status = cerebro_estado_desde_etapa(v_stage_final),
           incident_reason = CASE WHEN cerebro_estado_desde_etapa(v_stage_final) = 'incident'
                                  THEN v_fallo ELSE NULL END,
           updated_at = now()
     WHERE id = v_op_id;
    GET DIAGNOSTICS v_tocados = ROW_COUNT;
    IF v_todos AND v_saldo IS NOT NULL AND v_saldo = 0 THEN
      PERFORM cerebro_objetivo_cerrar_op(v_op_id);
    END IF;
  ELSE
    v_tocados := 1;
  END IF;

  RETURN QUERY SELECT
    CASE WHEN NOT v_todos THEN COALESCE(v_fallo, 'sin_cruce')
         WHEN v_saldo IS NOT NULL AND v_saldo > 0 THEN 'verificado_incompleto'
         WHEN v_saldo IS NOT NULL AND v_saldo < 0 THEN 'verificado_de_mas'
         ELSE 'verificado' END,
    v_trans1, v_tocados, v_metodo, v_todos, v_total, v_n, v_det,
    v_obj, v_dep, v_saldo;
END;
$function$;

DROP INDEX IF EXISTS public.remittance_operations_mixed_group_idx;
ALTER TABLE public.remittance_operations DROP COLUMN IF EXISTS mixed_group_id;
