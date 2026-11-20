-- ============================================================
-- 326 — Seguimiento a quien se llevó el PDF de la entrevista.
--        A los 2 días de mandarle el PDF, si el cliente no ha escrito
--        nada desde entonces, se le manda UNA vez la plantilla
--        aprobada por Meta (fuera de la ventana de 24 h solo se puede
--        con plantilla). Si contesta, ya no se le manda.
-- ============================================================

ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS seguimiento_pdf_en TIMESTAMPTZ;

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
     AND (cliente_en IS NULL OR cliente_en < pdf_en);
$$;
REVOKE ALL ON FUNCTION public.bot_seguimientos_pdf(UUID, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_seguimientos_pdf(UUID, INT) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.bot_seguimiento_pdf_hecho(p_account UUID, p_conversation UUID)
RETURNS JSONB
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  UPDATE conversations SET seguimiento_pdf_en = now()
   WHERE id = p_conversation AND account_id = p_account
  RETURNING jsonb_build_object('ok', true);
$$;
REVOKE ALL ON FUNCTION public.bot_seguimiento_pdf_hecho(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_seguimiento_pdf_hecho(UUID, UUID) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
