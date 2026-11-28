-- ROLLBACK for 365: stops the digest and gives pending items back as plain per-run notifications.
-- Digest rows already emitted (type resumen_diario) are deleted because the old type check does not allow them.

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'resumen-diario-notificaciones') THEN
    PERFORM cron.unschedule('resumen-diario-notificaciones');
  END IF;
END;
$cron$;

DROP TRIGGER IF EXISTS zzz_notifications_to_digest ON public.notifications;

INSERT INTO public.notifications (account_id, user_id, type, title, body, created_at)
SELECT i.account_id, i.user_id, i.type, i.title, i.body, i.created_at
  FROM public.notification_digest_items i
 WHERE i.digested_at IS NULL
   AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = i.user_id);

DELETE FROM public.notifications WHERE type = 'resumen_diario';

ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (type = ANY (ARRAY[
  'conversation_assigned', 'deal_incidencia', 'mensaje_fallido', 'promo_etecsa', 'chat_atascado', 'ingesta_caida',
  'deposito_sin_cruzar', 'mensaje_perdido', 'envio_incompleto', 'pide_mlc', 'envio_sin_beneficiario',
  'remesa_abierta_vieja', 'entrega_efectivo_lista', 'coherencia_servicio', 'inventario_cup']::text[]));

DROP FUNCTION IF EXISTS public.cerebro_resumen_diario();
DROP FUNCTION IF EXISTS public.cerebro_desviar_aviso_tecnico();
DROP TABLE IF EXISTS public.notification_digest_items;
