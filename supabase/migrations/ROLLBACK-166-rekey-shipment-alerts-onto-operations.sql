-- =====================================================================
-- ROLLBACK for 166 — put the two shipment alerts back on `deals`.
--
-- Restores, byte for byte, the bodies that 136 left on staging (verified
-- with pg_get_functiondef before 166 was applied). Signatures, defaults,
-- return shape, SECURITY DEFINER, search_path and ACL are untouched:
-- CREATE OR REPLACE preserves proacl, and 166 added no GRANT/REVOKE.
--
-- Apply:
--   psql "$STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -1 -f <this file>
--
-- Note: both functions keyed their cerebro_alertas rows on the deal id
-- before 166. If 166 already ran and wrote alert rows keyed on an
-- operation id (the deal-free case), those rows are orphaned by this
-- rollback and must be cleared by hand:
--   DELETE FROM cerebro_alertas
--    WHERE clave LIKE 'envio_incompleto:%' OR clave LIKE 'sin_beneficiario:%';
-- (Re-rolling forward then re-fires the alerts once, which is harmless.)
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_avisar_envios_incompletos(p_horas integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(incompletos integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_horas int; v_repetir int; v_ahora_gy timestamp;
  v_desde time; v_hasta time;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; r record;
BEGIN
  v_horas   := COALESCE(p_horas,       NULLIF(cerebro_config_get('envio_incompleto_horas'), '')::int, 4);
  v_repetir := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('envio_incompleto_repetir_min'), '')::int, 120);
  -- La ventana sale de cerebro_config y no del codigo: asi se puede ajustar sin
  -- desplegar, y asi se puede PROBAR la funcion entera fuera de horario, que es
  -- justo cuando se despliega. Los otros vigilantes la llevan a fuego y por eso
  -- su rama de aviso solo se ve funcionar al dia siguiente.
  v_desde := COALESCE(NULLIF(cerebro_config_get('envio_incompleto_desde'), '')::time, (SELECT abre FROM cerebro_horario()));
  v_hasta := COALESCE(NULLIF(cerebro_config_get('envio_incompleto_hasta'), '')::time, (SELECT cierra FROM cerebro_horario()));

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF EXTRACT(DOW FROM v_ahora_gy) = 0
     OR v_ahora_gy::time < v_desde OR v_ahora_gy::time >= v_hasta THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  FOR r IN
    SELECT d.id, d.account_id, d.contact_id, d.conversation_id,
           s.objetivo, s.depositado, s.saldo, s.moneda, o.pedido, c.name, c.phone,
           (SELECT max(m.consumido_en) FROM depositos_mmg m
             WHERE m.deal_id = d.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) AS ultimo_deposito
      FROM deals d
      JOIN conversations v ON v.id = d.conversation_id
      JOIN contacts      c ON c.id = v.contact_id
      LEFT JOIN cerebro_objetivo_envio o ON o.conversation_id = d.conversation_id
      CROSS JOIN LATERAL cerebro_saldo_envio(d.id) s
     WHERE d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND d.status = 'open'
       AND d.stage_id = '3cf01654-cd27-47c1-ac92-62abf5435751'
       AND s.saldo > 0
       AND COALESCE(
             (SELECT max(m.consumido_en) FROM depositos_mmg m
               WHERE m.deal_id = d.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL),
             d.created_at) < now() - make_interval(hours => v_horas)
       AND NOT EXISTS (
             SELECT 1 FROM cerebro_alertas a
              WHERE a.clave = 'envio_incompleto:' || d.id::text
                AND a.ultimo > now() - make_interval(mins => v_repetir))
  LOOP
    v_n := v_n + 1;
    v_espera := CASE
      WHEN EXTRACT(EPOCH FROM (now() - COALESCE(r.ultimo_deposito, now()))) >= 86400
        THEN round(EXTRACT(EPOCH FROM (now() - r.ultimo_deposito)) / 86400)::text || ' dias'
      ELSE round(EXTRACT(EPOCH FROM (now() - COALESCE(r.ultimo_deposito, now()))) / 3600)::text || ' h' END;

    INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
    SELECT r.account_id, p.user_id, 'envio_incompleto', r.conversation_id, r.contact_id,
           COALESCE(NULLIF(r.name, ''), r.phone) || ': faltan '
             || rtrim(trim(to_char(r.saldo, 'FM999,999,999,990.99')), '.') || ' ' || r.moneda
             || ' y lleva ' || v_espera || ' sin depositar mas',
           'Dijo que iba a enviar ' || COALESCE(r.pedido,
                 rtrim(trim(to_char(r.objetivo, 'FM999,999,999,990.99')), '.') || ' ' || r.moneda)
             || ' y lleva depositados '
             || rtrim(trim(to_char(r.depositado, 'FM999,999,999,990.99')), '.') || ' ' || r.moneda
             || '. FALTAN ' || rtrim(trim(to_char(r.saldo, 'FM999,999,999,990.99')), '.')
             || '. Ese dinero YA esta verificado contra el libro y consumido, pero el envio se '
             || 'queda en Por verificar y NO se transfiere hasta que complete. '
             || 'Si ya no va a completar, hay que decidir a mano que se hace con lo depositado.'
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('envio_incompleto:' || r.id::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_avisar_envios_sin_beneficiario(p_minutos integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(sin_destino integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int; v_repetir int; v_silencio int;
  v_ahora_gy timestamp; v_desde time; v_hasta time;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; r record;
BEGIN
  v_min      := COALESCE(p_minutos,     NULLIF(cerebro_config_get('sin_beneficiario_min'), '')::int, 30);
  v_repetir  := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('sin_beneficiario_repetir_min'), '')::int, 120);
  v_silencio := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_silencio_humano_min'), '')::int, 20);
  v_desde    := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_desde'), '')::time, (SELECT abre FROM cerebro_horario()));
  v_hasta    := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_hasta'), '')::time, (SELECT cierra FROM cerebro_horario()));

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF EXTRACT(DOW FROM v_ahora_gy) = 0
     OR v_ahora_gy::time < v_desde OR v_ahora_gy::time >= v_hasta THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  FOR r IN
    SELECT d.id, d.account_id, d.contact_id, d.conversation_id,
           d.value, d.currency, s.name AS etapa, c.name, c.phone,
           dep.dinero_dentro
      FROM deals d
      JOIN pipeline_stages s ON s.id = d.stage_id
      JOIN conversations v ON v.id = d.conversation_id
      JOIN contacts      c ON c.id = v.contact_id
      JOIN remittance_operations o ON o.deal_id = d.id
      CROSS JOIN LATERAL (
        SELECT max(m.consumido_en) AS dinero_dentro
          FROM depositos_mmg m
         WHERE m.deal_id = d.id
           AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) dep
     WHERE d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND d.status = 'open'
       AND d.stage_id IN ('3cf01654-cd27-47c1-ac92-62abf5435751',
                          'f5cf87f8-b570-4d71-b6ea-a3cafd458c63')
       AND COALESCE(o.service_type, 'remesa') <> 'recarga'
       AND dep.dinero_dentro IS NOT NULL
       AND dep.dinero_dentro < now() - make_interval(mins => v_min)
       AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b
                        WHERE b.operation_id = o.id AND b.status = 'vigente')
       AND COALESCE(d.notes, '') NOT LIKE '%BENEFICIARIO%'
       AND NOT EXISTS (SELECT 1 FROM messages m
                        WHERE m.conversation_id = d.conversation_id
                          AND m.sender_type = 'agent'
                          AND NOT COALESCE(m.ai_generated, false)
                          AND m.created_at > now() - make_interval(mins => v_silencio))
       AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                        WHERE a.clave = 'sin_beneficiario:' || d.id::text
                          AND a.ultimo > now() - make_interval(mins => v_repetir))
  LOOP
    v_n := v_n + 1;
    v_espera := CASE
      WHEN EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) >= 86400
        THEN round(EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) / 86400)::text || ' dias'
      ELSE round(EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) / 3600)::text || ' h' END;

    INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
    SELECT r.account_id, p.user_id, 'envio_sin_beneficiario', r.conversation_id, r.contact_id,
           COALESCE(NULLIF(r.name, ''), r.phone) || ': '
             || rtrim(trim(to_char(r.value, 'FM999,999,999,990.99')), '.') || ' ' || r.currency
             || ' dentro y SIN DESTINATARIO, lleva ' || v_espera,
           'El deposito esta verificado y consumido, pero el envio NO tiene a quien '
             || 'transferirle: ni tarjeta, ni celular, ni cuenta Zelle. Esta en "'
             || r.etapa || '" y ahi se queda. '
             || 'OJO: el bot puede haberle dicho al cliente que sus datos quedaban '
             || 'anotados sin que se anotara nada - abra el chat y compruebe lo que se '
             || 'le prometio antes de escribirle. Si el cliente ya dio los datos, el '
             || 'arreglo NO es tocar remittance_beneficiaries a mano: se escribe el '
             || 'bloque BENEFICIARIO en las notas del deal y el trigger hace el resto.'
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('sin_beneficiario:' || r.id::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END;
$function$;

NOTIFY pgrst, 'reload schema';
