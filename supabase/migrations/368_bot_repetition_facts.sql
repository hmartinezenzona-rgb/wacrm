-- =====================================================================
-- 368 — Facts the Decisor needs so the bot stops repeating itself
--
-- PROBLEM (audit 2026-10-30..11-13, production): the out-of-hours line was repeated in 42 conversations the same day, and a
--   pending data request was re-asked after a bare "ok" or within minutes of the previous ask. The Decisor is stateless about
--   the bot's own earlier messages: `Historial contacto.primer_del_dia` only says whether the bot spoke today.
--
-- WHAT: cerebro_repeticion_turno(conv) returns
--   horario_ya_dicho_hoy — an agent message of this conversation, dated today in America/Guyana, already carried the hours
--                          line ("fuera de horario" or "a partir de las 9");
--   ultimo_pedido_bot    — {texto, hace_min} of the newest ai_generated agent message of the last 6 hours that contains a
--                          question mark (the last ask), or NULL.
--   `Historial contacto` surfaces it as one json field `repeticion`; the Decisor decides what to do with it.
--
-- ROLLBACK: ROLLBACK-368-bot-repetition-facts.sql
-- Guarded by supabase/staging/assertions/bot-repetition-facts.sql
-- =====================================================================
CREATE OR REPLACE FUNCTION cerebro_repeticion_turno(p_conv uuid)
RETURNS TABLE (horario_ya_dicho_hoy boolean, ultimo_pedido_bot jsonb)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    EXISTS (SELECT 1 FROM messages m
             WHERE m.conversation_id = p_conv
               AND m.sender_type = 'agent'
               AND (m.created_at AT TIME ZONE 'America/Guyana')::date = (now() AT TIME ZONE 'America/Guyana')::date
               AND m.content_text ~* '(fuera de horario|a partir de las 9)'),
    (SELECT jsonb_build_object('texto', left(m.content_text, 500),
                               'hace_min', floor(extract(epoch FROM now() - m.created_at) / 60)::int)
       FROM messages m
      WHERE m.conversation_id = p_conv
        AND m.sender_type = 'agent'
        AND COALESCE(m.ai_generated, false)
        AND m.created_at > now() - interval '6 hours'
        AND btrim(COALESCE(m.content_text, '')) LIKE '%?%'
      ORDER BY m.created_at DESC
      LIMIT 1);
$$;

REVOKE EXECUTE ON FUNCTION cerebro_repeticion_turno(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_repeticion_turno(uuid) TO service_role;
