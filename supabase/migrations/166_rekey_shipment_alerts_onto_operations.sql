-- =====================================================================
-- 166 — re-key the two shipment alerts off `deals` onto operations
--
-- WHAT
--   `cerebro_avisar_envios_incompletos` (136:160) and
--   `cerebro_avisar_envios_sin_beneficiario` (136:245) are the last two
--   read-only alerting functions still driven by `deals`. This migration
--   re-points both at `remittance_operations`. After it, neither function
--   names `deals`, `pipelines` or `pipeline_stages` — they leave the
--   positional deals-referencing set (8 -> 6 on the live catalog; see
--   the migration's assertion for the counting definition).
--
-- WHY THE OPERATION, NOT THE DEAL
--   `deals` is being dropped. The operation is already the canonical row
--   for a shipment (040) and is now written directly by the n8n nodes and
--   the panel RPCs (114 retired the deal -> operation INSERT/UPDATE
--   mirror). The two functions are called from n8n, not from cron and not
--   from other SQL: `Vigilante - envios incompletos` (O1TqpAJXgRfKCiW6)
--   and `Vigilante - envios sin beneficiario` (I2qKK76f8Tp9eo16).
--
-- SIGNATURES ARE FROZEN
--   Both keep `(integer, integer)` and their existing defaults
--   (`envio_incompleto_repetir_min` 120, `sin_beneficiario_repetir_min`
--   120). Changing either would silently break a live caller. Every
--   config-driven window (`v_horas`, `v_repetir`, `v_min`, `v_silencio`,
--   `v_desde`, `v_hasta`) and the business-hours guard are unchanged.
--
-- THE MAPPING (stage -> status is the repo's own canonical map)
--   `cerebro_estado_desde_etapa` (041:39) is the single source for the
--   deal-stage <-> operation-status translation:
--     3cf01654 -> deposit_verification
--     f5cf87f8 -> ready_to_transfer
--   Applied to the real bodies (136:186-208 and 136:269-300):
--
--     deals d (driving row)              -> remittance_operations op
--     d.pipeline_id = '<remesa>'         -> COALESCE(op.service_type,
--                                             'remesa') <> 'recarga'
--     incompletos: status 'open' +
--       stage 3cf01654                   -> op.status = 'deposit_verification'
--     sin_beneficiario: status 'open' +
--       stage IN (3cf01654, f5cf87f8)    -> op.status IN ('deposit_verification',
--                                             'ready_to_transfer')
--     d.value / d.currency               -> op.quoted_source_amount /
--                                             op.source_currency
--     cerebro_saldo_envio(d.id)          -> cerebro_saldo_operacion(op.id)
--     depositos_mmg.deal_id = d.id       -> depositos_mmg.operation_id = op.id
--     sin_beneficiario's JOIN
--       remittance_operations o
--         ON o.deal_id = d.id            -> dropped; op is already the row
--
--   Kept verbatim: the conversations/contacts joins, the
--   cerebro_objetivo_envio join (incompletos, keyed by conversation_id),
--   the deposit clock (`consumido_en IS NOT NULL AND anulado_en IS NULL`),
--   the messages silence check, the `NOT EXISTS ... b.status = 'vigente'`
--   beneficiary check, and every v_* config-driven window.
--
-- THE DEDUP KEY: coalesce(op.deal_id, op.id), NOT op.id
--   `cerebro_alertas.clave` is a PRIMARY KEY (037:133) and both functions
--   do `ON CONFLICT (clave) DO UPDATE SET ultimo = now()`. The key used
--   to be the deal id; it becomes `coalesce(op.deal_id, op.id)`. For
--   every deal-linked operation `op.deal_id` IS the deal id, so the
--   generated clave is byte-identical to today's and no already-recorded
--   alert re-fires. A deal-free operation (deal_id IS NULL, the cutover
--   path built by 161) keys on its own operation id, which is the new
--   behaviour we want. Keying on op.id alone would re-fire every open
--   alert once.
--
--   This keeps a dependency on `remittance_operations.deal_id`, which is
--   dropped in a later phase. That is a known, deferred transition: when
--   deal_id goes, the coalesce collapses to op.id by construction, and
--   the dedup keys created here stay valid.
--
-- TWO OPERATOR-VISIBLE TEXT CHANGES (deliberate, expected)
--   1. sin_beneficiario no longer claims a pipeline stage. The old body
--      rendered `Esta en "<pipeline_stages.name>"`, which has no
--      operation-keyed equivalent — status and service_type are a
--      different vocabulary and are not mapped onto stage names. The
--      clause now says the shipment stays open, without naming a stage.
--   2. The trailing instruction no longer tells the operator to write the
--      BENEFICIARIO block into the deal's notes. That trigger is retired
--      with `deals`; the true path is the structured
--      `remittance_beneficiaries` row written by the 162 functions. The
--      warning that the bot may have promised data it never recorded is
--      kept — it is still accurate and valuable.
--   The incompletos title/body and all amount formatting are unchanged.
--
-- DELIBERATE BEHAVIOUR CHANGES, NAMED (latent on staging today)
--   a. Stage/status divergence. Migration 114 dropped
--      `trg_sync_operacion_desde_deal` (114:359), so a deal's stage and
--      its operation's status are no longer kept in lock-step. Two open
--      deals sit at f5cf87f8 whose operation is `cancelled`. The
--      deal-keyed predicate included them; the operation-keyed one
--      excludes them. Intended: a cancelled shipment must not raise a
--      "money inside, no recipient" alert.
--   b. incompletos now excludes `service_type = 'recarga'`. The old body
--      scoped by pipeline only; the operation-keyed scope is the
--      service_type. Latent: no recarga operation currently matches.
--   c. sin_beneficiario drops the legacy `d.notes NOT LIKE
--      '%BENEFICIARIO%'` check, because it names `deals` and this
--      migration cannot name it. The structured beneficiary check that
--      the old body already applied alongside it remains. Latent: the
--      legacy notes marker is no longer what gates the alert.
--
-- ACL: CREATE OR REPLACE preserves `proacl`. Both functions read
--   {postgres=X/postgres,service_role=X/postgres} — no `authenticated`,
--   no `PUBLIC`. n8n calls them as service_role. This file adds no
--   REVOKE and no GRANT, on purpose.
--
-- ROLLBACK: ROLLBACK-166-rekey-shipment-alerts-onto-operations.sql
-- Guarded by supabase/staging/assertions/rekey-shipment-alerts-onto-operations.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. cerebro_avisar_envios_incompletos — operation-keyed
-- ---------------------------------------------------------------------

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
    SELECT op.id, op.deal_id, op.account_id, op.contact_id, op.conversation_id,
           s.objetivo, s.depositado, s.saldo, s.moneda, o.pedido, c.name, c.phone,
           (SELECT max(m.consumido_en) FROM depositos_mmg m
             WHERE m.operation_id = op.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) AS ultimo_deposito
      FROM remittance_operations op
      JOIN conversations v ON v.id = op.conversation_id
      JOIN contacts      c ON c.id = v.contact_id
      LEFT JOIN cerebro_objetivo_envio o ON o.conversation_id = op.conversation_id
      CROSS JOIN LATERAL cerebro_saldo_operacion(op.id) s
     WHERE COALESCE(op.service_type, 'remesa') <> 'recarga'
       AND op.status = 'deposit_verification'
       AND s.saldo > 0
       AND COALESCE(
             (SELECT max(m.consumido_en) FROM depositos_mmg m
               WHERE m.operation_id = op.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL),
             op.created_at) < now() - make_interval(hours => v_horas)
       AND NOT EXISTS (
             SELECT 1 FROM cerebro_alertas a
              WHERE a.clave = 'envio_incompleto:' || coalesce(op.deal_id, op.id)::text
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
    VALUES ('envio_incompleto:' || coalesce(r.deal_id, r.id)::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END;
$function$;

-- ---------------------------------------------------------------------
-- 2. cerebro_avisar_envios_sin_beneficiario — operation-keyed
--    (with the two operator-visible text changes described above)
-- ---------------------------------------------------------------------

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
    SELECT op.id, op.deal_id, op.account_id, op.contact_id, op.conversation_id,
           op.quoted_source_amount AS value, op.source_currency AS currency,
           c.name, c.phone, dep.dinero_dentro
      FROM remittance_operations op
      JOIN conversations v ON v.id = op.conversation_id
      JOIN contacts      c ON c.id = v.contact_id
      CROSS JOIN LATERAL (
        SELECT max(m.consumido_en) AS dinero_dentro
          FROM depositos_mmg m
         WHERE m.operation_id = op.id
           AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) dep
     WHERE COALESCE(op.service_type, 'remesa') <> 'recarga'
       AND op.status IN ('deposit_verification', 'ready_to_transfer')
       AND dep.dinero_dentro IS NOT NULL
       AND dep.dinero_dentro < now() - make_interval(mins => v_min)
       AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b
                        WHERE b.operation_id = op.id AND b.status = 'vigente')
       AND NOT EXISTS (SELECT 1 FROM messages m
                        WHERE m.conversation_id = op.conversation_id
                          AND m.sender_type = 'agent'
                          AND NOT COALESCE(m.ai_generated, false)
                          AND m.created_at > now() - make_interval(mins => v_silencio))
       AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                        WHERE a.clave = 'sin_beneficiario:' || coalesce(op.deal_id, op.id)::text
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
             || 'transferirle: ni tarjeta, ni celular, ni cuenta Zelle. El envio sigue '
             || 'abierto y ahi se queda. '
             || 'OJO: el bot puede haberle dicho al cliente que sus datos quedaban '
             || 'anotados sin que se anotara nada - abra el chat y compruebe lo que se '
             || 'le prometio antes de escribirle. Si el cliente ya dio los datos, el '
             || 'arreglo es registrar el beneficiario por la via estructurada: se '
             || 'escribe la fila de remittance_beneficiaries (las funciones de la '
             || 'migracion 162, las mismas que usa el bot y el panel), no el bloque '
             || 'BENEFICIARIO en las notas del deal.'
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('sin_beneficiario:' || coalesce(r.deal_id, r.id)::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END;
$function$;

NOTIFY pgrst, 'reload schema';
