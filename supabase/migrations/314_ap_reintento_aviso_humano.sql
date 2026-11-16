-- ============================================================
-- 314 — Reintento del aviso "Un cliente quiere hablar contigo" (AP)
--
-- bot_pasar_a_humano (313) manda el aviso con net.http_post. A veces esa
-- llamada falla (p. ej. "Error in the HTTP2 framing layer" de pg_net) y el
-- aviso se pierde aunque el chat sí quedó pausado. Este cron revisa cada
-- minuto los chats pasados a humano en los últimos 15 minutos que aún no
-- se avisaron y vuelve a llamar al aviso. La ruta /api/avisos/evento marca
-- humano_avisado_en de forma atómica, así que nunca sale dos veces.
-- ============================================================

CREATE OR REPLACE FUNCTION public._ap_reintentar_avisos_humano()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT id FROM conversations
     WHERE humano_avisado_en IS NULL
       AND humano_pedido_en >= now() - interval '15 minutes'
       AND humano_pedido_en <= now() - interval '20 seconds'
  LOOP
    PERFORM net.http_post(
      url := 'https://crm-ap-suministros.vercel.app/api/avisos/evento',
      body := jsonb_build_object('tipo', 'humano', 'conversation_id', r.id),
      headers := '{"Content-Type": "application/json"}'::jsonb
    );
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public._ap_reintentar_avisos_humano() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  PERFORM cron.unschedule('ap-reintento-aviso-humano')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ap-reintento-aviso-humano');
  PERFORM cron.schedule('ap-reintento-aviso-humano', '* * * * *',
    'SELECT public._ap_reintentar_avisos_humano()');
END $$;
