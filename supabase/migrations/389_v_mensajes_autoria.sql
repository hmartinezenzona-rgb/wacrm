-- 389_v_mensajes_autoria.sql
--
-- One read-only view that tells every audit WHO wrote each message and in
-- which conversation context. It derives the author from the fields the app
-- already writes (messages.sender_type / ai_generated / sender_id /
-- is_panel_action / content_type), joins the human name through
-- profiles.user_id, and attaches the contact tags and the bot state.
--
-- Taxonomy:
--   cliente      sender_type = 'customer'
--   sistema      content_type = 'template' or is_panel_action
--   bot          ai_generated = true (bot or public API)
--   humano       ai_generated = false and sender_id is not null
--   indeterminado anything else
--
-- Internal only: anon and authenticated keep no access; service_role reads it.
-- Guarded by supabase/staging/assertions/mensajes-autoria.sql.

CREATE OR REPLACE VIEW public.v_mensajes_autoria
WITH (security_invoker = true) AS
SELECT
  m.id,
  m.conversation_id,
  m.created_at,
  m.sender_type,
  m.content_type,
  m.ai_generated,
  m.is_panel_action,
  m.sender_id,
  p.full_name AS autor_nombre,
  CASE
    WHEN m.sender_type = 'customer' THEN 'cliente'
    WHEN m.content_type = 'template' OR m.is_panel_action THEN 'sistema'
    WHEN m.ai_generated THEN 'bot'
    WHEN m.sender_id IS NOT NULL THEN 'humano'
    ELSE 'indeterminado'
  END AS autor,
  v.account_id,
  c.id AS contact_id,
  c.name AS contacto,
  c.phone,
  COALESCE(tg.lista, '[]'::jsonb) AS etiquetas,
  v.ai_autoreply_disabled,
  v.ai_handoff_at,
  v.ai_handoff_reason,
  v.assigned_agent_id
FROM public.messages m
JOIN public.conversations v ON v.id = m.conversation_id
JOIN public.contacts c ON c.id = v.contact_id
LEFT JOIN public.profiles p ON p.user_id = m.sender_id
LEFT JOIN (
  SELECT ct.contact_id, jsonb_agg(t.name ORDER BY t.name) AS lista
    FROM public.contact_tags ct
    JOIN public.tags t ON t.id = ct.tag_id
   GROUP BY ct.contact_id
) tg ON tg.contact_id = c.id;

REVOKE ALL ON public.v_mensajes_autoria FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_mensajes_autoria TO service_role;
