-- =====================================================================
-- 300 -- Ingestion watchdog: a customer message that never reached the bot is recorded and alerted
--
-- 2026-10-24: the owner's "Hola" (conv 765a524f) was stored and the CRM processed the webhook, but the CRM->n8n
-- delivery timed out and the event was dropped in-process (no session_event, no Cerebro execution). The same
-- failure class also occurs when n8n answers 404 during a workflow update. There is no retry after the delivery
-- gives up, so the message disappears from the bot's view.
--
-- This watchdog closes that gap without re-sending blindly (a late original could duplicate the turn):
--   * finds customer messages older than 5 minutes (the delivery window is ~26 s) and younger than 24 hours with
--     no session_events row for their wamid;
--   * records each one once in cerebro_ingesta_perdida;
--   * queues one admin alert through the existing outbox (text only, so it may need the admin's 24 h window; the
--     record remains either way).
-- A cron runs it every 5 minutes. Assertion: supabase/staging/assertions/vigilante-ingesta.sql.
-- Rollback: ROLLBACK-300-vigilante-ingesta.sql.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.cerebro_ingesta_perdida (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id         text NOT NULL UNIQUE,
  conversation_id    uuid NOT NULL,
  message_created_at timestamptz NOT NULL,
  detected_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  alerta             boolean NOT NULL DEFAULT false,
  outbox_id          uuid
);

CREATE INDEX IF NOT EXISTS cerebro_ingesta_perdida_conv_idx
  ON public.cerebro_ingesta_perdida (conversation_id, message_created_at DESC);

COMMENT ON TABLE public.cerebro_ingesta_perdida IS
  'Customer messages stored by the CRM with no session_event for their wamid after the delivery window: the bot '
  'never saw them. Written by cerebro_vigilar_ingesta; alerts are queued through message_outbox when an admin '
  'contact exists.';

REVOKE ALL ON TABLE public.cerebro_ingesta_perdida FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.cerebro_vigilar_ingesta()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_admin text;
  v_n     integer := 0;
  v_id    uuid;
  v_res   record;
  r       record;
BEGIN
  SELECT c.phone INTO v_admin
    FROM contacts c
    JOIN contact_tags ct ON ct.contact_id = c.id
    JOIN tags t ON t.id = ct.tag_id
   WHERE lower(t.name) = 'admin'
   ORDER BY c.created_at
   LIMIT 1;

  FOR r IN
    SELECT m.message_id, m.conversation_id, m.created_at
      FROM messages m
     WHERE m.sender_type = 'customer'
       AND m.message_id IS NOT NULL
       AND m.created_at BETWEEN now() - interval '24 hours' AND now() - interval '5 minutes'
       AND NOT EXISTS (SELECT 1 FROM session_events se WHERE se.whatsapp_message_id = m.message_id)
       AND NOT EXISTS (SELECT 1 FROM cerebro_ingesta_perdida p WHERE p.message_id = m.message_id)
     ORDER BY m.created_at
     LIMIT 50
  LOOP
    INSERT INTO cerebro_ingesta_perdida (message_id, conversation_id, message_created_at)
    VALUES (r.message_id, r.conversation_id, r.created_at)
    ON CONFLICT (message_id) DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      CONTINUE;
    END IF;

    v_n := v_n + 1;

    IF v_admin IS NOT NULL THEN
      SELECT * INTO v_res FROM cerebro_outbox_encolar(
        r.conversation_id,
        v_admin,
        'AVISO INGESTA: un mensaje de cliente no llego al bot.' || chr(10) || chr(10)
          || 'Conversacion: ' || left(r.conversation_id::text, 8) || chr(10)
          || 'Mensaje: ' || right(r.message_id, 8) || chr(10)
          || 'Hora UTC: ' || to_char(r.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || chr(10)
          || 'Revise el chat en el CRM.',
        NULL,
        'ingesta-' || r.message_id);

      UPDATE cerebro_ingesta_perdida
         SET alerta = coalesce(v_res.encolado, false), outbox_id = v_res.outbox_id
       WHERE id = v_id;
    END IF;
  END LOOP;

  RETURN v_n;
END;
$function$;

COMMENT ON FUNCTION public.cerebro_vigilar_ingesta() IS
  'Records customer messages that never reached the bot (no session_event for their wamid) and queues one admin '
  'alert each through the outbox. Idempotent per wamid.';

REVOKE ALL ON FUNCTION public.cerebro_vigilar_ingesta() FROM PUBLIC, anon, authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vigilar-ingesta'
              AND command IS DISTINCT FROM 'SELECT public.cerebro_vigilar_ingesta()') THEN
    PERFORM cron.unschedule('vigilar-ingesta');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vigilar-ingesta') THEN
    PERFORM cron.schedule('vigilar-ingesta', '*/5 * * * *', 'SELECT public.cerebro_vigilar_ingesta()');
  END IF;
END;
$cron$;
