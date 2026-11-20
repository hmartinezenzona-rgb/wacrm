-- ============================================================
-- 329 — Seguimiento del PDF: antes se cancelaba si el cliente escribía
--        cualquier cosa después del PDF (ej. «gracias, luego lo reviso»).
--        Ahora se manda si a los 2 días no ha contestado ninguna pregunta
--        de la entrevista y no ha escrito en las últimas 24 horas.
-- ============================================================
CREATE OR REPLACE FUNCTION public.bot_seguimientos_pdf(p_account UUID, p_horas INT DEFAULT 48)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH pdf AS (
    SELECT v.id, c.phone,
           CASE WHEN c.name_source = 'manual' THEN split_part(c.name, ' ', 1) ELSE '' END AS nombre,
           (SELECT max(m.created_at) FROM messages m
             WHERE m.conversation_id = v.id AND m.sender_type <> 'customer' AND m.content_type = 'document') AS pdf_en,
           (SELECT max(m.created_at) FROM messages m
             WHERE m.conversation_id = v.id AND m.sender_type = 'customer') AS cliente_en
      FROM conversations v
      JOIN contacts c ON c.id = v.contact_id
     WHERE v.account_id = p_account
       AND v.seguimiento_pdf_en IS NULL
       AND NOT COALESCE(v.ai_autoreply_disabled, false) AND v.deleted_at IS NULL
       AND EXISTS (SELECT 1 FROM deals d
                    WHERE d.account_id = p_account AND d.contact_id = c.id AND d.status = 'open'
                      AND d.notes ~* '(^|\n)Entrevista:\s*pdf')
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('conversation_id', id, 'telefono', phone,
                                               'nombre', COALESCE(NULLIF(nombre, ''), 'qué tal'))), '[]'::jsonb)
    FROM pdf
   WHERE pdf_en IS NOT NULL
     AND pdf_en < now() - make_interval(hours => p_horas)
     -- Que todavía no haya mandado respuestas de la entrevista (un «gracias, luego lo reviso» no cuenta)
     -- y que no esté platicando ahorita.
     AND jsonb_array_length(COALESCE(bot_entrevista(p_account, id)->'ya_contesto', '[]'::jsonb)) = 0
     AND (cliente_en IS NULL OR cliente_en < now() - interval '24 hours')
     -- Solo en horario de atención (lun–sáb, 9:00–19:00 hora de Saltillo).
     AND extract(isodow FROM now() AT TIME ZONE 'America/Monterrey') < 7
     AND extract(hour FROM now() AT TIME ZONE 'America/Monterrey') BETWEEN 9 AND 18;
$$;
REVOKE ALL ON FUNCTION public.bot_seguimientos_pdf(UUID, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_seguimientos_pdf(UUID, INT) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
