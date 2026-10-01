-- =====================================================================
-- ROLLBACK-164-deals-free-views-and-inert-edits
--
-- Restores the exact pre-164 state of the seven objects WU6a changed:
-- the two surviving views with their `deals` join and `d.value` fallback,
-- the dropped `cerebro_conciliacion_operaciones` view, and the four
-- functions with their `deals` references back. Bodies are the live
-- definitions from 114 / 022 / 143 / 136 / 158.
-- =====================================================================

-- 1) cerebro_historial_operaciones — deals join back, 114 verbatim.
CREATE OR REPLACE VIEW public.cerebro_historial_operaciones AS
SELECT
  ((coalesce(o.completed_at, o.updated_at)) AT TIME ZONE 'America/Guyana')::date AS dia,
  o.service_type,
  o.status,
  ct.name   AS cliente,
  ct.phone  AS telefono,
  coalesce(o.quoted_source_amount, d.value, 0) AS monto_gyd,
  o.destination_currency,
  b.beneficiary_type,
  b.name    AS beneficiario,
  CASE WHEN b.card_number IS NOT NULL
       THEN left(b.card_number,4) || '****' || right(b.card_number,4) END AS tarjeta,
  b.phone   AS celular_beneficiario,
  b.zelle_account,
  o.deal_id,
  o.id      AS operation_id,
  o.created_at,
  o.completed_at
FROM remittance_operations o
LEFT JOIN deals d          ON d.id = o.deal_id
LEFT JOIN conversations cv ON cv.id = o.conversation_id
LEFT JOIN contacts ct      ON ct.id = coalesce(o.contact_id, cv.contact_id)
LEFT JOIN remittance_beneficiaries b
       ON b.operation_id = o.id AND b.status = 'vigente';

COMMENT ON VIEW public.cerebro_historial_operaciones IS
  '053, repointed by 114: prefers remittance_operations.quoted_source_amount '
  'over deals.value now that deals.stage_id/value stop tracking a live '
  'panel-completed operation. Row shape unchanged.';

-- 2) cerebro_volumen_diario — deals join back, 114 verbatim.
CREATE OR REPLACE VIEW public.cerebro_volumen_diario AS
SELECT
  ((coalesce(o.completed_at, o.updated_at)) AT TIME ZONE 'America/Guyana')::date AS dia,
  o.service_type,
  count(*)                                                            AS operaciones,
  sum(coalesce(o.quoted_source_amount, d.value, 0))                   AS volumen_gyd,
  round(avg(coalesce(o.quoted_source_amount, d.value, 0)))            AS ticket_medio_gyd
FROM remittance_operations o
LEFT JOIN deals d ON d.id = o.deal_id
WHERE o.status = 'completed'
GROUP BY 1, 2;

COMMENT ON VIEW public.cerebro_volumen_diario IS
  '053, repointed by 114: same coalesce-order flip as '
  'cerebro_historial_operaciones, for the same reason.';

-- 3) cerebro_conciliacion_operaciones — restore the view, 114 verbatim.
CREATE OR REPLACE VIEW public.cerebro_conciliacion_operaciones AS
 SELECT 'deal sin operacion'::text AS problema, d.id AS deal_id, NULL::uuid AS operation_id
   FROM deals d
   LEFT JOIN remittance_operations o ON o.deal_id = d.id
  WHERE d.conversation_id IS NOT NULL
    AND d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'::uuid
    AND o.id IS NULL
 UNION ALL
 SELECT 'operacion sin deal', NULL::uuid, o.id
   FROM remittance_operations o
   LEFT JOIN deals d ON d.id = o.deal_id
  WHERE o.deal_id IS NOT NULL AND d.id IS NULL
    AND o.status NOT IN ('completed','cancelled')
 UNION ALL
 SELECT 'estado divergente', d.id, o.id
   FROM remittance_operations o
   JOIN deals d ON d.id = o.deal_id
  WHERE o.status <> CASE d.stage_id
      WHEN '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109'::uuid THEN 'collecting_information'
      WHEN '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid THEN 'deposit_verification'
      WHEN 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63'::uuid THEN 'ready_to_transfer'
      WHEN '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b'::uuid THEN 'completed'
      WHEN 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid THEN 'incident'
      ELSE 'collecting_information' END
    AND o.status <> 'completed';

COMMENT ON VIEW public.cerebro_conciliacion_operaciones IS
  '041/063, repointed by 114: the estado-divergente branch excludes '
  'o.status = ''completed'', since a panel-delivered operation''s deal no '
  'longer moves to Entregada (crm_entregar_operacion, section 5) — that '
  'is now the expected shape, not drift.';

-- 4) merge_duplicate_contacts — restore the UPDATE deals line (022 verbatim).
CREATE OR REPLACE FUNCTION public.merge_duplicate_contacts()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group   RECORD;
  v_survivor UUID;
  v_losers   UUID[];
  v_merged   INTEGER := 0;
BEGIN
  FOR v_group IN
    SELECT account_id,
           phone_normalized,
           array_agg(id ORDER BY created_at ASC, id ASC) AS ids
    FROM contacts
    WHERE phone_normalized <> ''
    GROUP BY account_id, phone_normalized
    HAVING count(*) > 1
  LOOP
    v_survivor := v_group.ids[1];
    v_losers   := v_group.ids[2:array_length(v_group.ids, 1)];

    UPDATE conversations                 SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE contact_notes                 SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE deals                         SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE broadcast_recipients          SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE automation_logs               SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE automation_pending_executions SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);

    UPDATE contact_tags ct SET contact_id = v_survivor
      WHERE ct.contact_id = ANY(v_losers)
        AND NOT EXISTS (
          SELECT 1 FROM contact_tags s
          WHERE s.contact_id = v_survivor AND s.tag_id = ct.tag_id
        );
    DELETE FROM contact_tags WHERE contact_id = ANY(v_losers);

    UPDATE contact_custom_values cv SET contact_id = v_survivor
      WHERE cv.contact_id = ANY(v_losers)
        AND NOT EXISTS (
          SELECT 1 FROM contact_custom_values s
          WHERE s.contact_id = v_survivor AND s.custom_field_id = cv.custom_field_id
        );
    DELETE FROM contact_custom_values WHERE contact_id = ANY(v_losers);

    UPDATE flow_runs SET contact_id = v_survivor
      WHERE contact_id = ANY(v_losers) AND status <> 'active';

    DELETE FROM contacts WHERE id = ANY(v_losers);

    v_merged := v_merged + COALESCE(array_length(v_losers, 1), 0);
  END LOOP;

  RETURN v_merged;
END;
$$;

ALTER FUNCTION public.merge_duplicate_contacts() OWNER TO postgres;
REVOKE EXECUTE ON FUNCTION public.merge_duplicate_contacts() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merge_duplicate_contacts() TO service_role;

-- 5) crm_entregar_operacion — restore the deal-lock block (143 verbatim).
CREATE OR REPLACE FUNCTION public.crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id    uuid;
  v_deal_id       uuid;

  v_status_before text;
  v_status_after  text;
  v_completed_at  timestamptz;

  v_mode          text;
  v_wamid         text;
  v_path          text;
BEGIN
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to deliver this operation' USING ERRCODE = '42501';
  END IF;

  IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'evidence must be a JSON object' USING ERRCODE = '22023';
  END IF;

  v_mode := p_evidence ->> 'mode';
  IF v_mode IS NULL OR v_mode NOT IN ('proof_sent', 'no_proof', 'skip_proof') THEN
    RAISE EXCEPTION 'evidence mode must be proof_sent, no_proof or skip_proof' USING ERRCODE = '22023';
  END IF;

  IF p_evidence ? 'wamid' AND (p_evidence -> 'wamid') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'wamid') <> 'string' THEN
      RAISE EXCEPTION 'evidence wamid must be a string' USING ERRCODE = '22023';
    END IF;
    v_wamid := p_evidence ->> 'wamid';
    IF v_wamid = '' OR length(v_wamid) > 500 THEN
      RAISE EXCEPTION 'evidence wamid must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_evidence ? 'path' AND (p_evidence -> 'path') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'path') <> 'string' THEN
      RAISE EXCEPTION 'evidence path must be a string' USING ERRCODE = '22023';
    END IF;
    v_path := p_evidence ->> 'path';
    IF v_path = '' OR length(v_path) > 500 THEN
      RAISE EXCEPTION 'evidence path must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Lock the deal too (when there is one) to preserve ordering against
  -- concurrent n8n deals.notes/value writes — deal_id is no longer a
  -- hard requirement for delivery (item 1: remittance_operations is the
  -- sole write target), only a historical linkage.
  IF v_deal_id IS NOT NULL THEN
    PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;
  END IF;

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  IF NOT crm_beneficiarios_completos(p_operation_id) THEN
    RAISE EXCEPTION 'beneficiary data is incomplete' USING ERRCODE = '22023';
  END IF;

  IF v_mode = 'proof_sent' AND crm_pruebas_faltantes(p_operation_id) > 0 THEN
    RAISE EXCEPTION 'every beneficiary needs its delivery proof before delivering (% missing)',
      crm_pruebas_faltantes(p_operation_id)
      USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_operations
     SET status = 'completed',
         delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid()
   WHERE id = p_operation_id
     AND status = 'ready_to_transfer'
  RETURNING status, completed_at INTO v_status_after, v_completed_at;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer'),
          jsonb_build_object('status', 'completed', 'evidence', p_evidence));

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $$;

REVOKE ALL ON FUNCTION public.crm_entregar_operacion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_entregar_operacion(uuid, jsonb) TO authenticated, service_role;

-- 6) cerebro_avisar_remesas_abiertas_viejas — restore both LEFT JOINs (136 verbatim).
CREATE OR REPLACE FUNCTION public.cerebro_avisar_remesas_abiertas_viejas(p_horas integer DEFAULT NULL::integer, p_ignorar_horario boolean DEFAULT false)
 RETURNS TABLE(viejas integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_horas    int;
  v_repetir  int;
  v_desde    time;
  v_ahora_gy timestamp;
  v_n        int := 0;
  v_avisos   int := 0;
  v_creados  int;
  r          record;
BEGIN
  v_horas   := COALESCE(p_horas, NULLIF(cerebro_config_get('remesas_viejas_horas'), '')::int, 48);
  v_repetir := COALESCE(NULLIF(cerebro_config_get('remesas_viejas_repetir_min'), '')::int, 1200);
  v_desde   := COALESCE(NULLIF(cerebro_config_get('remesas_viejas_desde'), '')::time, (SELECT abre FROM cerebro_horario()));

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF NOT p_ignorar_horario AND (EXTRACT(DOW FROM v_ahora_gy) = 0 OR v_ahora_gy::time < v_desde) THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  FOR r IN
    SELECT o.account_id, count(*)::int AS n,
           string_agg('- ' || COALESCE(NULLIF(c.name, ''), c.phone, 'cliente') || ': '
                      || CASE WHEN COALESCE(NULLIF(o.quoted_source_amount, 0), d.value, 0) > 0
                              THEN rtrim(trim(to_char(COALESCE(NULLIF(o.quoted_source_amount, 0), d.value), 'FM999,999,999,990.99')), '.') || ' GYD'
                              ELSE 'sin deposito' END
                      || ', abierta hace ' || floor(EXTRACT(EPOCH FROM (now() - o.created_at)) / 86400)::int || ' dias'
                      || COALESCE(' (' || s.name || ')', ''),
                      E'\n' ORDER BY o.created_at) AS lista
      FROM remittance_operations o
      LEFT JOIN deals d ON d.id = o.deal_id
      LEFT JOIN pipeline_stages s ON s.id = d.stage_id
      LEFT JOIN conversations v ON v.id = o.conversation_id
      LEFT JOIN contacts c ON c.id = v.contact_id
     WHERE o.status NOT IN ('completed', 'cancelled')
       AND COALESCE(o.service_type, 'remesa') <> 'recarga'
       AND o.created_at < now() - make_interval(hours => v_horas)
     GROUP BY o.account_id
  LOOP
    v_n := v_n + r.n;
    CONTINUE WHEN EXISTS (SELECT 1 FROM cerebro_alertas a
                           WHERE a.clave = 'remesas_viejas:' || r.account_id::text
                             AND a.ultimo > now() - make_interval(mins => v_repetir));

    INSERT INTO notifications (account_id, user_id, type, title, body)
    SELECT r.account_id, p.user_id, 'remesa_abierta_vieja',
           r.n || CASE WHEN r.n = 1 THEN ' remesa abierta' ELSE ' remesas abiertas' END
             || ' hace mas de ' || v_horas || ' h',
           'Si ya se pagaron, marquelas como Entregadas en el panel; si no van, cancelelas. '
             || 'Una remesa vieja abierta puede hacer que los datos de una remesa nueva del mismo '
             || 'cliente se asignen a la vieja.' || E'\n\n' || r.lista
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);
    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('remesas_viejas:' || r.account_id::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END $function$;

REVOKE EXECUTE ON FUNCTION public.cerebro_avisar_remesas_abiertas_viejas(integer, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_avisar_remesas_abiertas_viejas(integer, boolean) TO service_role;

-- 7) cerebro_saldo_envio — restore the 158 two-branch body.
CREATE OR REPLACE FUNCTION public.cerebro_saldo_envio(p_deal uuid)
 RETURNS TABLE(objetivo numeric, depositado numeric, saldo numeric, moneda text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH op AS (
    SELECT (SELECT ro.id
              FROM remittance_operations ro
             WHERE ro.deal_id = p_deal) AS id
  ),
  nuevo AS (
    SELECT s.objetivo, s.depositado, s.saldo, s.moneda
      FROM op
      CROSS JOIN LATERAL cerebro_saldo_operacion(op.id) s
     WHERE op.id IS NOT NULL
  ),
  dep AS (
    SELECT COALESCE(sum(m.monto), 0) AS total
      FROM depositos_mmg m
     WHERE m.deal_id = p_deal
       AND m.consumido_en IS NOT NULL
       AND m.anulado_en  IS NULL
  ),
  obj AS (
    SELECT o.monto, o.moneda
      FROM cerebro_objetivo_envio o
      JOIN deals d ON d.conversation_id = o.conversation_id
     WHERE d.id = p_deal
       AND o.cerrado_en IS NULL
       AND (o.deal_id IS NULL OR o.deal_id = p_deal)
  ),
  viejo AS (
    SELECT (SELECT monto FROM obj) AS objetivo,
           (SELECT total FROM dep) AS depositado,
           (SELECT monto FROM obj) - (SELECT total FROM dep) AS saldo,
           COALESCE((SELECT moneda FROM obj), 'GYD') AS moneda
     WHERE NOT EXISTS (SELECT 1 FROM op WHERE op.id IS NOT NULL)
  )
  SELECT nuevo.objetivo, nuevo.depositado, nuevo.saldo, nuevo.moneda
    FROM nuevo
  UNION ALL
  SELECT viejo.objetivo, viejo.depositado, viejo.saldo, viejo.moneda
    FROM viejo;
$function$;

COMMENT ON FUNCTION public.cerebro_saldo_envio(uuid) IS
  '158. Deals-keyed balance, delegating to cerebro_saldo_operacion when the '
  'deal already has an operation and falling back to the deal-only logic in '
  'the window before that operation exists.';

REVOKE EXECUTE ON FUNCTION public.cerebro_saldo_envio(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_saldo_envio(uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
