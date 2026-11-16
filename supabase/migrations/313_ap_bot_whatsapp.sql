-- ============================================================
-- 313 — Bot de WhatsApp de AP Suministros (n8n). Va después de 310–312.
--
-- El bot vive en n8n: recibe "message.received" del CRM, contesta con la
-- API v1 y usa catalogo_publico / cotizacion_solicitar. Aquí va lo que le
-- falta:
--   * bot_pasar_a_humano(cuenta, conversación, motivo): pausa el bot en ese
--     chat (ai_autoreply_disabled), deja el motivo como nota del bot y
--     manda el aviso "Un cliente quiere hablar contigo" al celular.
--   * conversations.humano_pedido_en / humano_avisado_en: para que el
--     aviso salga una sola vez.
-- Para reanudar el bot en un chat: botón "Reanudar bot" en Mensajes.
-- ============================================================

ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS humano_pedido_en  timestamptz,
  ADD COLUMN IF NOT EXISTS humano_avisado_en timestamptz;

CREATE OR REPLACE FUNCTION public.bot_pasar_a_humano(
  p_account uuid,
  p_conversation uuid,
  p_motivo text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_motivo text := left(btrim(COALESCE(p_motivo, '')), 300);
  v_id uuid;
BEGIN
  UPDATE conversations
     SET ai_autoreply_disabled = true,
         ai_handoff_summary    = NULLIF(v_motivo, ''),
         humano_pedido_en      = now(),
         humano_avisado_en     = NULL
   WHERE id = p_conversation
     AND account_id = p_account
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'conversacion_no_encontrada');
  END IF;

  BEGIN
    PERFORM net.http_post(
      url := 'https://crm-ap-suministros.vercel.app/api/avisos/evento',
      body := jsonb_build_object('tipo', 'humano', 'conversation_id', v_id),
      headers := '{"Content-Type": "application/json"}'::jsonb
    );
  EXCEPTION WHEN others THEN
    NULL; -- el aviso es extra; el chat ya quedó pausado
  END;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.bot_pasar_a_humano(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_pasar_a_humano(uuid, uuid, text) TO anon, authenticated;
