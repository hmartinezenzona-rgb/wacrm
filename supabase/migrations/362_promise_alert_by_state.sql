-- =====================================================================
-- 362 -- The AVISO PROMESA alert is judged by saved STATE, about two minutes after the message
--
-- Production 2026-11-10: 36 alerts since 2026-10-26, none a real "claimed saved, nothing saved" case.
--   * ~31 matched the prompt-mandated off-hours sentence ("queda registrado y se procesa a partir de ...").
--   * The evidence was only tool_execution_log in [-3 min, +1 min]: automatic writers (automatic beneficiary
--     registration, reparto_auto, notes_parse) leave no row there, any read-only tool silenced the alert, and the
--     tool rows land 22-59 s after the message insert, so the +1 min side never worked.
-- Owner decision 2026-11-10: fix at the root.
--
-- New behavior
--   (a) cerebro_texto_promete ignores the off-hours sentence; it is never a claim.
--   (b) The message trigger (same name and trigger as 296/313) only records a pending candidate in
--       cerebro_promesa_candidatas, due 2 minutes after the message. No alert, no memory note at insert.
--   (c) cerebro_promesa_evaluar(p_now), run every minute by the existing pg_cron mechanism (job
--       'evaluar-promesas', same pattern as 'recruzar-depositos-tardios'), evaluates due candidates by saved state:
--       cerebro_promesa_estado_guardado(conversation, from, to) is true when any beneficiary, operation, deposit
--       receipt, MMG deposit consumption, Zelle/partial-beneficiary row or reparto plan of the conversation was
--       created or changed in [message - 45 min, evaluation time], by any writer. The 45-minute look-back comes from
--       the 36 historical cases: recap messages ("Anotado" over data saved earlier) trail the save by up to ~38 min.
--       Saved -> candidate closed silently (status 'saved').
--   (d) Nothing saved -> exactly the same AVISO PROMESA admin alert (message outbox, idempotency key
--       'promesa-<message id>') and the same system memory note as before, once; status 'alerted'.
-- A failure in the evaluation never raises: it is a WARNING and the candidate is marked 'failed'.
--
-- Assertion: supabase/staging/assertions/promise-alert-by-state.sql. Rollback: ROLLBACK-362-promise-alert-by-state.sql.
-- =====================================================================

-- (a) off-hours sentence is not a claim
CREATE OR REPLACE FUNCTION public.cerebro_texto_promete(p_texto text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT regexp_replace(
           coalesce(p_texto, ''),
           'queda[[:space:]]+registrad[oa][[:space:]]+(y[[:space:]]+se[[:space:]]+procesa|para[[:space:]]+procesarse)',
           ' ', 'gi')
         ~* '((^|[^[:alpha:]])anotad[oa]([^[:alpha:]]|$)|queda[[:space:]]+(registrad|anotad|as[ií])|qued[oó][[:space:]]+(registrad|anotad))';
$function$;

COMMENT ON FUNCTION public.cerebro_texto_promete(text) IS
  'True when the reply promises that something was saved: Anotado/Anotada, queda registrado/anotado/así, '
  'quedó registrado/anotado. The mandated off-hours sentence ("queda registrado y se procesa a partir de ...") '
  'is removed before matching: it announces scheduling, not a save.';

-- candidates recorded at message insert, evaluated later
CREATE TABLE IF NOT EXISTS public.cerebro_promesa_candidatas (
  message_id          uuid PRIMARY KEY,
  conversation_id     uuid NOT NULL,
  message_created_at  timestamptz NOT NULL,
  content_excerpt     text NOT NULL,
  evaluate_after      timestamptz NOT NULL,
  status              text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'saved', 'alerted', 'failed')),
  evaluated_at        timestamptz,
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS cerebro_promesa_candidatas_pending_idx
  ON public.cerebro_promesa_candidatas (evaluate_after) WHERE status = 'pending';

COMMENT ON TABLE public.cerebro_promesa_candidatas IS
  'Agent replies that claim a save, awaiting evaluation by saved state 2 minutes after the message. '
  'Written by cerebro_promesa_sin_escritura_guardar, closed by cerebro_promesa_evaluar.';

REVOKE ALL ON TABLE public.cerebro_promesa_candidatas FROM PUBLIC, anon, authenticated;

-- saved-state check
CREATE OR REPLACE FUNCTION public.cerebro_promesa_estado_guardado(p_conversation_id uuid, p_desde timestamptz, p_hasta timestamptz)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
           SELECT 1 FROM remittance_operations o
            WHERE o.conversation_id = p_conversation_id
              AND (o.created_at BETWEEN p_desde AND p_hasta OR o.updated_at BETWEEN p_desde AND p_hasta))
      OR EXISTS (
           SELECT 1 FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
            WHERE o.conversation_id = p_conversation_id
              AND (b.created_at BETWEEN p_desde AND p_hasta
                   OR b.confirmed_at BETWEEN p_desde AND p_hasta
                   OR b.replaced_at BETWEEN p_desde AND p_hasta))
      OR EXISTS (
           SELECT 1 FROM remittance_operation_receipts r
            WHERE r.conversation_id = p_conversation_id AND r.created_at BETWEEN p_desde AND p_hasta)
      OR EXISTS (
           SELECT 1 FROM depositos_mmg m JOIN remittance_operations o ON o.id = m.operation_id
            WHERE o.conversation_id = p_conversation_id AND m.consumido_en BETWEEN p_desde AND p_hasta)
      OR EXISTS (
           SELECT 1 FROM cerebro_beneficiario_parcial x
            WHERE x.conversation_id = p_conversation_id AND x.actualizado BETWEEN p_desde AND p_hasta)
      OR EXISTS (
           SELECT 1 FROM cerebro_reparto_planeado x
            WHERE x.conversation_id = p_conversation_id AND x.creado_at BETWEEN p_desde AND p_hasta);
$function$;

COMMENT ON FUNCTION public.cerebro_promesa_estado_guardado(uuid, timestamptz, timestamptz) IS
  'True when any operation, beneficiary, deposit receipt, MMG deposit consumption, partial beneficiary (Zelle) or '
  'reparto plan of the conversation was created or changed in [p_desde, p_hasta], by any writer.';

REVOKE ALL ON FUNCTION public.cerebro_promesa_estado_guardado(uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

-- (b) the message trigger function only records the candidate
CREATE OR REPLACE FUNCTION public.cerebro_promesa_sin_escritura_guardar()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_at timestamptz;
BEGIN
  IF NEW.sender_type IS DISTINCT FROM 'agent' OR NOT coalesce(NEW.ai_generated, false) THEN
    RETURN NEW;
  END IF;
  IF NOT cerebro_texto_promete(NEW.content_text) THEN
    RETURN NEW;
  END IF;

  v_at := coalesce(NEW.created_at, now());
  BEGIN
    INSERT INTO cerebro_promesa_candidatas (message_id, conversation_id, message_created_at, content_excerpt, evaluate_after)
    VALUES (NEW.id, NEW.conversation_id, v_at, left(coalesce(NEW.content_text, ''), 240), v_at + interval '2 minutes')
    ON CONFLICT (message_id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] promise candidate failed for message %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$function$;

-- (c)(d) evaluation by saved state; returns the number of alerts sent
CREATE OR REPLACE FUNCTION public.cerebro_promesa_evaluar(p_now timestamptz DEFAULT clock_timestamp())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r       record;
  v_id    uuid;
  v_nota  integer;
  v_admin text;
  v_n     integer := 0;
BEGIN
  FOR r IN
    SELECT * FROM cerebro_promesa_candidatas
     WHERE status = 'pending' AND evaluate_after <= p_now
     ORDER BY evaluate_after
     FOR UPDATE SKIP LOCKED
  LOOP
    IF cerebro_promesa_estado_guardado(r.conversation_id, r.message_created_at - interval '45 minutes', p_now) THEN
      UPDATE cerebro_promesa_candidatas SET status = 'saved', evaluated_at = p_now WHERE message_id = r.message_id;
      CONTINUE;
    END IF;

    BEGIN
      v_id := NULL;
      INSERT INTO cerebro_promesas_sin_escritura (conversation_id, message_id, message_created_at, content_excerpt)
      VALUES (r.conversation_id, r.message_id, r.message_created_at, r.content_excerpt)
      ON CONFLICT (message_id) DO NOTHING
      RETURNING id INTO v_id;

      IF v_id IS NOT NULL THEN
        INSERT INTO cerebro_memoria (session_id, message)
        VALUES (r.conversation_id::text, jsonb_build_object(
          'type', 'human',
          'content', E'[CONTEXTO DEL SISTEMA - el cliente NO ve esto]\n'
            || E'- En tu ultimo mensaje dijiste que algo quedo anotado o registrado, pero en ese turno no se guardo '
            || E'ningun dato en el sistema. Si el cliente te dio un dato (tarjeta, celular, nombre, cuenta, monto, '
            || E'CLABE), registralo con la herramienta que corresponda antes de confirmarlo. Si no habia nada que '
            || E'guardar, no afirmes que quedo anotado.'))
        RETURNING id INTO v_nota;
        UPDATE cerebro_promesas_sin_escritura SET note_id = v_nota WHERE id = v_id;

        -- admin alert, best effort: a failure here never undoes the case row or the note
        BEGIN
          SELECT c.phone INTO v_admin
            FROM contacts c
            JOIN contact_tags ct ON ct.contact_id = c.id
            JOIN tags t ON t.id = ct.tag_id
           WHERE lower(t.name) = 'admin'
           ORDER BY c.created_at
           LIMIT 1;
          IF v_admin IS NOT NULL THEN
            PERFORM cerebro_outbox_encolar(
              r.conversation_id,
              v_admin,
              'AVISO PROMESA: el bot dijo que anotaba algo y no lo guardo.' || chr(10) || chr(10)
                || 'Conversacion: ' || left(r.conversation_id::text, 8) || chr(10)
                || 'Hora UTC: ' || to_char(r.message_created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || chr(10)
                || 'Revise el chat y registre el dato si falta.',
              NULL,
              'promesa-' || r.message_id::text);
            v_n := v_n + 1;
          END IF;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING '[wacrm] promise alert failed for message %: %', r.message_id, SQLERRM;
        END;
      END IF;
      UPDATE cerebro_promesa_candidatas SET status = 'alerted', evaluated_at = p_now WHERE message_id = r.message_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[wacrm] promise evaluation failed for message %: %', r.message_id, SQLERRM;
      UPDATE cerebro_promesa_candidatas SET status = 'failed', evaluated_at = p_now WHERE message_id = r.message_id;
    END;
  END LOOP;
  RETURN v_n;
END;
$function$;

COMMENT ON FUNCTION public.cerebro_promesa_evaluar(timestamptz) IS
  'Evaluates due promise candidates by saved state (cerebro_promesa_estado_guardado, 45 min look-back, up to '
  'p_now). Saved: closes silently. Nothing saved: records the case, leaves the system memory note and queues one '
  'AVISO PROMESA admin alert. Returns the number of alerts queued. Run every minute by pg_cron (evaluar-promesas).';

REVOKE ALL ON FUNCTION public.cerebro_promesa_evaluar(timestamptz) FROM PUBLIC, anon, authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'evaluar-promesas'
              AND command IS DISTINCT FROM 'SELECT public.cerebro_promesa_evaluar()') THEN
    PERFORM cron.unschedule('evaluar-promesas');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'evaluar-promesas') THEN
    PERFORM cron.schedule('evaluar-promesas', '* * * * *', 'SELECT public.cerebro_promesa_evaluar()');
  END IF;
END;
$cron$;
