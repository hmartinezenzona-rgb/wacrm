-- =====================================================================
-- 134 — Daily alert: remesas left open for more than 48 h
--
-- A remesa that was paid but never closed in the panel stays "open" for days.
-- Every "operacion_ambigua" handoff of Sep 2026 (5 of 5) came from such
-- remesas, and two of them would still have gone wrong with the 126 matcher
-- (fixed in 133). Closing them in the panel is the real cure: this watcher
-- tells the team which ones are left, once a day.
--
-- cerebro_avisar_remesas_abiertas_viejas() follows the pattern of the other
-- watchers (090): one panel notification per member of the account, a
-- throttle in cerebro_alertas, business hours from cerebro_config:
--   remesas_viejas_horas ........ 48    (age of an open remesa to be listed)
--   remesas_viejas_repetir_min .. 1200  (at most once a day)
--   remesas_viejas_desde ........ 09:00 (Guyana time, not on Sundays)
-- p_ignorar_horario is for tests only.
--
-- ROLLBACK: ROLLBACK-134-stale-operations-alert.sql
-- Guarded by supabase/staging/assertions/stale-operations-alert.sql
-- =====================================================================

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check CHECK (type = ANY (ARRAY[
  'conversation_assigned', 'deal_incidencia', 'mensaje_fallido', 'promo_etecsa', 'chat_atascado',
  'ingesta_caida', 'deposito_sin_cruzar', 'mensaje_perdido', 'envio_incompleto', 'pide_mlc',
  'envio_sin_beneficiario', 'remesa_abierta_vieja']::text[]));

CREATE OR REPLACE FUNCTION cerebro_avisar_remesas_abiertas_viejas(p_horas integer DEFAULT NULL, p_ignorar_horario boolean DEFAULT false)
RETURNS TABLE(viejas integer, avisos_creados integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  v_desde   := COALESCE(NULLIF(cerebro_config_get('remesas_viejas_desde'), '')::time, '09:00'::time);

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF NOT p_ignorar_horario AND (EXTRACT(DOW FROM v_ahora_gy) = 0 OR v_ahora_gy::time < v_desde) THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  -- One summary per account.
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
END $$;

COMMENT ON FUNCTION cerebro_avisar_remesas_abiertas_viejas(integer, boolean) IS
  '134. Once a day, tells the team which remesas are still open after N hours (default 48).';

REVOKE EXECUTE ON FUNCTION cerebro_avisar_remesas_abiertas_viejas(integer, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_avisar_remesas_abiertas_viejas(integer, boolean) TO service_role;

NOTIFY pgrst, 'reload schema';
