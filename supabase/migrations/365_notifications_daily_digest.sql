-- 365: one daily digest for the four technical notification types.
--
-- Audit 2026-11-10: mensaje_fallido (130 rows), mensaje_perdido (59), remesa_abierta_vieja (37) and promo_etecsa (17) were
-- 42% of all panel notifications and almost never read (2%, 3%, 8%, 0%); every row plays the alert sound.
--
-- Mechanism (the detection functions are NOT touched, nor are their cerebro_alertas dedupe keys):
--   * BEFORE INSERT trigger on notifications for those four types diverts the row into notification_digest_items (same
--     user, type, title, body) and returns NULL, so no per-run row, no realtime INSERT and no sound. Emitters keep
--     running unchanged (cerebro_avisar_mensajes_fallidos / _perdidos / _remesas_abiertas_viejas, cerebro_outbox_resultado,
--     cerebro_promo_revision); only their reported ROW_COUNT is 0 now (the n8n watchers just SELECT it, nothing reads it).
--   * Exemption: promo_etecsa "Nueva promocion de Etecsa detectada" is actionable (the owner confirms the price) and rare,
--     so it keeps notifying immediately. Only the failed-read notice of the promo watcher is digested.
--   * cerebro_resumen_diario(): one new notification 'resumen_diario' per profile with pending items: title with the total,
--     one section per type with events (zero types omitted), identical lines collapsed "(xN)", at most 5 lines per section
--     then "y N mas". Pending items are consumed (digested_at). Nothing pending, nothing emitted. Items older than 30 days
--     are purged.
--   * pg_cron job 'resumen-diario-notificaciones' at 12:30 UTC Mon-Sat = 08:30 Guyana (UTC-4, no DST), the same mechanism
--     as the other sweepers of this database. Sunday's items go out Monday.
-- Guard: new table (RLS on, no policy), the type check gains 'resumen_diario', one trigger, one cron job.
-- Rollback: ROLLBACK-365-notifications-daily-digest.sql (pending items are re-emitted as plain notifications first).

CREATE TABLE IF NOT EXISTS public.notification_digest_items (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id   uuid,
  user_id      uuid NOT NULL,
  type         text NOT NULL,
  title        text NOT NULL,
  body         text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  digested_at  timestamptz
);
CREATE INDEX IF NOT EXISTS notification_digest_items_pending_idx
  ON public.notification_digest_items (user_id) WHERE digested_at IS NULL;
ALTER TABLE public.notification_digest_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.notification_digest_items FROM PUBLIC, anon, authenticated;

ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (type = ANY (ARRAY[
  'conversation_assigned', 'deal_incidencia', 'mensaje_fallido', 'promo_etecsa', 'chat_atascado', 'ingesta_caida',
  'deposito_sin_cruzar', 'mensaje_perdido', 'envio_incompleto', 'pide_mlc', 'envio_sin_beneficiario',
  'remesa_abierta_vieja', 'entrega_efectivo_lista', 'coherencia_servicio', 'inventario_cup', 'resumen_diario']::text[]));

CREATE OR REPLACE FUNCTION public.cerebro_desviar_aviso_tecnico()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO notification_digest_items (account_id, user_id, type, title, body, created_at)
  VALUES (NEW.account_id, NEW.user_id, NEW.type, NEW.title, NEW.body, COALESCE(NEW.created_at, now()));
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_desviar_aviso_tecnico() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zzz_notifications_to_digest ON public.notifications;
CREATE TRIGGER zzz_notifications_to_digest
  BEFORE INSERT ON public.notifications
  FOR EACH ROW
  WHEN (NEW.type IN ('mensaje_fallido', 'mensaje_perdido', 'remesa_abierta_vieja', 'promo_etecsa')
        AND NOT (NEW.type = 'promo_etecsa' AND NEW.title = 'Nueva promocion de Etecsa detectada'))
  EXECUTE FUNCTION public.cerebro_desviar_aviso_tecnico();

CREATE OR REPLACE FUNCTION public.cerebro_resumen_diario()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_creados int;
BEGIN
  DELETE FROM notification_digest_items WHERE created_at < now() - interval '30 days';

  WITH tomadas AS (
    UPDATE notification_digest_items i
       SET digested_at = now()
     WHERE i.digested_at IS NULL
       AND EXISTS (SELECT 1 FROM profiles p JOIN auth.users au ON au.id = p.user_id WHERE p.user_id = i.user_id)
    RETURNING i.user_id, i.type, i.title, i.created_at
  ), lineas AS (
    SELECT user_id, type, title, count(*)::int AS n, max(created_at) AS ult
      FROM tomadas GROUP BY user_id, type, title
  ), ordenadas AS (
    SELECT l.*, row_number() OVER (PARTITION BY user_id, type ORDER BY ult DESC, title) AS rn
      FROM lineas l
  ), secciones AS (
    SELECT o.user_id, o.type,
           sum(o.n)::int AS total,
           string_agg(CASE WHEN o.n > 1 THEN '- ' || o.title || ' (x' || o.n || ')' ELSE '- ' || o.title END,
                      E'\n' ORDER BY o.rn) FILTER (WHERE o.rn <= 5) AS lineas,
           count(*) FILTER (WHERE o.rn > 5)::int AS extra
      FROM ordenadas o GROUP BY o.user_id, o.type
  ), usuarios AS (
    SELECT s.user_id,
           sum(s.total)::int AS total,
           string_agg(t.nombre || ': ' || s.total || E'\n' || s.lineas
                        || CASE WHEN s.extra > 0 THEN E'\n- y ' || s.extra || ' mas' ELSE '' END,
                      E'\n\n' ORDER BY t.orden) AS cuerpo
      FROM secciones s
      JOIN (VALUES (1, 'mensaje_perdido', 'Mensajes que no llegaron'),
                   (2, 'mensaje_fallido', 'Mensajes rechazados por WhatsApp'),
                   (3, 'remesa_abierta_vieja', 'Remesas abiertas hace mucho'),
                   (4, 'promo_etecsa', 'Revision de promociones de Etecsa')) AS t(orden, tipo, nombre)
        ON t.tipo = s.type
     GROUP BY s.user_id
  )
  INSERT INTO notifications (account_id, user_id, type, title, body)
  SELECT p.account_id, u.user_id, 'resumen_diario',
         'Resumen tecnico del dia: ' || u.total || CASE WHEN u.total = 1 THEN ' aviso' ELSE ' avisos' END,
         u.cuerpo
    FROM usuarios u
    JOIN profiles p ON p.user_id = u.user_id;

  GET DIAGNOSTICS v_creados = ROW_COUNT;
  RETURN v_creados;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_resumen_diario() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_resumen_diario() TO service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'resumen-diario-notificaciones'
              AND (schedule IS DISTINCT FROM '30 12 * * 1-6' OR command IS DISTINCT FROM 'SELECT public.cerebro_resumen_diario()')) THEN
    PERFORM cron.unschedule('resumen-diario-notificaciones');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'resumen-diario-notificaciones') THEN
    PERFORM cron.schedule('resumen-diario-notificaciones', '30 12 * * 1-6', 'SELECT public.cerebro_resumen_diario()');
  END IF;
END;
$cron$;
