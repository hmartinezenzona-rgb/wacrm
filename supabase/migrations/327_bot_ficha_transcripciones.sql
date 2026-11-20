-- ============================================================
-- 327 — «ultimos» incluye lo que dijeron las notas de voz y fotos.
--        Antes salían como [audio], y el extractor de datos solo veía
--        lo que el asesor repetía: los datos se guardaban un turno tarde
--        o nunca (ej. el reto), y el agente improvisaba preguntas.
-- ============================================================
CREATE OR REPLACE FUNCTION public.bot_ficha(p_account UUID, p_conversation UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'nombre', CASE WHEN c.name_source = 'manual' THEN c.name ELSE '' END,
    'nombre_perfil', c.name,
    'negocio', COALESCE(c.company, ''),
    'correo', COALESCE(c.email, ''),
    'columna', COALESCE((SELECT s.name FROM pipeline_stages s WHERE s.id = d.stage_id), ''),
    'datos', COALESCE(d.notes, ''),
    'tiene_ficha', d.id IS NOT NULL,
    'humano', COALESCE(v.ai_autoreply_disabled, false),
    'sesion', COALESCE(floor(extract(epoch FROM v.cerrada_en))::bigint::text, ''),
    'ultimos', COALESCE((
      SELECT string_agg(CASE WHEN x.sender_type = 'customer' THEN 'Cliente: ' ELSE 'Asesor: ' END
                        || left(COALESCE(NULLIF(x.content_text, ''), x.transcrito, '[' || x.content_type || ']'), 600),
                        E'\n' ORDER BY x.created_at)
        FROM (SELECT m.sender_type, m.content_text, m.content_type, m.created_at,
                     -- Notas de voz y fotos: lo que el flujo ya pasó a texto (bot_eventos).
                     (SELECT regexp_replace(e.texto, '^\(El cliente mandó una nota de voz\. Esto es lo que dice:\)\s*', '(nota de voz) ')
                        FROM bot_eventos e
                       WHERE m.sender_type = 'customer' AND COALESCE(m.content_text, '') = ''
                         AND e.conversation_id = m.conversation_id
                         AND e.recibido_en BETWEEN m.created_at - interval '5 seconds'
                                               AND m.created_at + interval '2 minutes'
                       ORDER BY e.recibido_en LIMIT 1) AS transcrito
                FROM messages m WHERE m.conversation_id = v.id
                 AND m.created_at > COALESCE(v.cerrada_en, '-infinity'::timestamptz)
               ORDER BY m.created_at DESC LIMIT 12) x), ''))
    FROM conversations v
    JOIN contacts c ON c.id = v.contact_id
    LEFT JOIN LATERAL (
      SELECT d.* FROM deals d
       WHERE d.account_id = p_account AND d.contact_id = c.id AND d.status <> 'lost'
       ORDER BY (d.status = 'open') DESC, d.created_at DESC LIMIT 1) d ON true
   WHERE v.id = p_conversation AND v.account_id = p_account;
$$;
REVOKE ALL ON FUNCTION public.bot_ficha(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_ficha(UUID, UUID) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
