-- 324 rollback: restore the version that flagged deliberately deleted lines.

CREATE OR REPLACE FUNCTION public.hermes_cuadre_finanzas(
  p_desde date DEFAULT NULL,
  p_hasta date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_desde date := coalesce(p_desde, (now() AT TIME ZONE 'America/Guyana')::date);
  v_hasta date := coalesce(p_hasta, coalesce(p_desde, (now() AT TIME ZONE 'America/Guyana')::date));
BEGIN
  IF v_desde > v_hasta THEN
    RAISE EXCEPTION 'hermes_cuadre_finanzas: p_desde (%) must not be after p_hasta (%)', v_desde, v_hasta
      USING ERRCODE = '22023';
  END IF;

  IF (v_hasta - v_desde) > 92 THEN
    RAISE EXCEPTION 'hermes_cuadre_finanzas: range must not exceed 93 days (requested % days)', (v_hasta - v_desde) + 1
      USING ERRCODE = '22023';
  END IF;

  RETURN (
    WITH linea AS (
      -- Same day rule as crm_cierre_financiero: the Guyana day of completion,
      -- falling back to the ledger date for manual lines.
      SELECT e.id,
             e.source,
             e.status,
             e.operation_id,
             e.service,
             e.customer_name,
             e.amount,
             e.amount_currency,
             coalesce(e.facturado_gyd, 0) AS facturado_gyd,
             coalesce(e.invertido_gyd, 0) AS invertido_gyd,
             coalesce(e.retorno_gyd, 0)   AS retorno_gyd,
             coalesce((e.completed_at AT TIME ZONE 'America/Guyana')::date, e.entry_date) AS dia,
             EXISTS (
               SELECT 1 FROM remittance_calculator_week_entries we WHERE we.entry_id = e.id
             ) AS archivada
        FROM remittance_calculator_entries e
       WHERE e.source IN ('completed_operation', 'manual')
         AND coalesce((e.completed_at AT TIME ZONE 'America/Guyana')::date, e.entry_date) BETWEEN v_desde AND v_hasta
    ),
    hechas AS (SELECT * FROM linea WHERE status = 'completed'),
    excluidas AS (SELECT * FROM linea WHERE status IN ('void', 'verified_pending')),
    ops AS (
      SELECT left(o.id::text, 8) AS op8,
             o.id,
             o.service_type,
             coalesce(nullif(c.name, ''), c.phone) AS cliente,
             c.phone,
             to_char(o.completed_at AT TIME ZONE 'America/Guyana', 'YYYY-MM-DD HH24:MI') AS completado
        FROM remittance_operations o
        LEFT JOIN contacts c ON c.id = o.contact_id
       WHERE o.status = 'completed'
         AND o.completed_at IS NOT NULL
         AND (o.completed_at AT TIME ZONE 'America/Guyana')::date BETWEEN v_desde AND v_hasta
    ),
    semanas AS (
      SELECT coalesce(
               jsonb_agg(
                 jsonb_build_object(
                   'corte', to_char(w.cut_at AT TIME ZONE 'America/Guyana', 'YYYY-MM-DD HH24:MI'),
                   'periodo', w.period_label,
                   'lineas', jsonb_array_length(w.entries),
                   'manual', w.manual_totals,
                   'bot', w.chat_totals
                 ) ORDER BY w.cut_at DESC
               ),
               '[]'::jsonb
             ) AS lista
        FROM (SELECT * FROM remittance_calculator_weeks ORDER BY cut_at DESC LIMIT 6) w
    )
    SELECT jsonb_build_object(
      'desde', v_desde,
      'hasta', v_hasta,
      'zona', 'America/Guyana',
      'crm', jsonb_build_object(
        'completadas', (SELECT count(*) FROM ops),
        'sin_linea_en_finanzas', coalesce((
          SELECT jsonb_agg(
                   jsonb_build_object(
                     'operacion', o.op8,
                     'cliente', o.cliente,
                     'telefono', o.phone,
                     'servicio', o.service_type,
                     'completado', o.completado
                   ) ORDER BY o.completado
                 )
            FROM ops o
           WHERE o.id NOT IN (SELECT operation_id FROM hechas WHERE operation_id IS NOT NULL)
        ), '[]'::jsonb)
      ),
      'finanzas', jsonb_build_object(
        'lineas', (SELECT count(*) FROM hechas),
        'del_bot', (SELECT count(*) FROM hechas WHERE source = 'completed_operation'),
        'manuales', (SELECT count(*) FROM hechas WHERE source = 'manual'),
        'facturado_gyd', (SELECT coalesce(sum(facturado_gyd), 0) FROM hechas),
        'invertido_gyd', (SELECT coalesce(sum(invertido_gyd), 0) FROM hechas),
        'retorno_gyd', (SELECT coalesce(sum(retorno_gyd), 0) FROM hechas),
        'por_servicio', coalesce((
          SELECT jsonb_agg(
                   jsonb_build_object(
                     'servicio', service,
                     'lineas', lineas,
                     'facturado_gyd', facturado,
                     'invertido_gyd', invertido,
                     'retorno_gyd', retorno
                   ) ORDER BY facturado DESC
                 )
            FROM (
              SELECT service,
                     count(*) AS lineas,
                     sum(facturado_gyd) AS facturado,
                     sum(invertido_gyd) AS invertido,
                     sum(retorno_gyd) AS retorno
                FROM hechas
               GROUP BY service
            ) s
        ), '[]'::jsonb),
        'lineas_sin_operacion', coalesce((
          -- Bot lines whose operation is not completed inside the window:
          -- the classic "the ledger has it, the CRM says another day".
          SELECT jsonb_agg(
                   jsonb_build_object(
                     'linea', left(h.id::text, 8),
                     'dia', h.dia,
                     'cliente', h.customer_name,
                     'servicio', h.service,
                     'monto', h.amount,
                     'moneda', h.amount_currency,
                     'facturado_gyd', h.facturado_gyd
                   ) ORDER BY h.dia
                 )
            FROM hechas h
           WHERE h.source = 'completed_operation'
             AND h.operation_id IS NOT NULL
             AND h.operation_id NOT IN (SELECT id FROM ops)
        ), '[]'::jsonb),
        'excluidas', jsonb_build_object(
          'anuladas', (SELECT count(*) FROM excluidas WHERE status = 'void'),
          'pendientes_tasa', (SELECT count(*) FROM excluidas WHERE status = 'verified_pending')
        )
      ),
      'control_semanal', jsonb_build_object(
        'borrador', jsonb_build_object(
          'lineas', (SELECT count(*) FROM hechas WHERE NOT archivada),
          'facturado_gyd', (SELECT coalesce(sum(facturado_gyd), 0) FROM hechas WHERE NOT archivada),
          'invertido_gyd', (SELECT coalesce(sum(invertido_gyd), 0) FROM hechas WHERE NOT archivada),
          'retorno_gyd', (SELECT coalesce(sum(retorno_gyd), 0) FROM hechas WHERE NOT archivada)
        ),
        'archivadas', jsonb_build_object(
          'lineas', (SELECT count(*) FROM hechas WHERE archivada),
          'facturado_gyd', (SELECT coalesce(sum(facturado_gyd), 0) FROM hechas WHERE archivada),
          'invertido_gyd', (SELECT coalesce(sum(invertido_gyd), 0) FROM hechas WHERE archivada),
          'retorno_gyd', (SELECT coalesce(sum(retorno_gyd), 0) FROM hechas WHERE archivada)
        ),
        'semanas', (SELECT lista FROM semanas)
      )
    )
  );
END;
$function$;

COMMENT ON FUNCTION public.hermes_cuadre_finanzas(date, date) IS
  'Hermes MCP: reconcile completed operations with Finanzas (ledger) and Control Semanal (open vs archived weeks) for a Guyana business-day window. Read-only.';

REVOKE ALL ON FUNCTION public.hermes_cuadre_finanzas(date, date) FROM PUBLIC, anon, authenticated;;

REVOKE ALL ON FUNCTION public.hermes_cuadre_finanzas(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hermes_cuadre_finanzas(date, date) TO service_role;
