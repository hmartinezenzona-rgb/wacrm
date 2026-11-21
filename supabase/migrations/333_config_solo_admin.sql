-- ============================================================
-- 333 — La configuración del agente y la entrevista la lee cualquier
--        miembro de la cuenta, pero solo el dueño o un admin la cambia
--        (igual que negocio_config). Ahora se edita desde el CRM en
--        Configuración › Tu negocio. n8n usa la llave de servicio y no
--        cambia.
-- ============================================================

DROP POLICY IF EXISTS bot_config_miembros ON public.bot_config;
DROP POLICY IF EXISTS bot_config_leer ON public.bot_config;
DROP POLICY IF EXISTS bot_config_editar ON public.bot_config;
CREATE POLICY bot_config_leer ON public.bot_config
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT account_id FROM public.profiles WHERE user_id = auth.uid()));
CREATE POLICY bot_config_editar ON public.bot_config
  FOR ALL TO authenticated
  USING (account_id IN (SELECT account_id FROM public.profiles
                         WHERE user_id = auth.uid() AND account_role IN ('owner', 'admin')))
  WITH CHECK (account_id IN (SELECT account_id FROM public.profiles
                              WHERE user_id = auth.uid() AND account_role IN ('owner', 'admin')));

DROP POLICY IF EXISTS bot_entrevista_miembros ON public.bot_entrevista;
DROP POLICY IF EXISTS bot_entrevista_leer ON public.bot_entrevista;
DROP POLICY IF EXISTS bot_entrevista_editar ON public.bot_entrevista;
CREATE POLICY bot_entrevista_leer ON public.bot_entrevista
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT account_id FROM public.profiles WHERE user_id = auth.uid()));
CREATE POLICY bot_entrevista_editar ON public.bot_entrevista
  FOR ALL TO authenticated
  USING (account_id IN (SELECT account_id FROM public.profiles
                         WHERE user_id = auth.uid() AND account_role IN ('owner', 'admin')))
  WITH CHECK (account_id IN (SELECT account_id FROM public.profiles
                              WHERE user_id = auth.uid() AND account_role IN ('owner', 'admin')));

NOTIFY pgrst, 'reload schema';
