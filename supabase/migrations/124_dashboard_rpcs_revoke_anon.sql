-- =====================================================================
-- 124 — Dashboard RPCs: no execution for anon / PUBLIC
--
-- 116, 117 and 118 (and the older cerebro_dashboard_operaciones_envejecidas)
-- only GRANT EXECUTE to authenticated and never revoke the Postgres default
-- PUBLIC grant, so anyone holding the public anon key could call them through
-- PostgREST and read aggregate business volume. The only caller is
-- /dashboard, from the browser with the signed-in user's session
-- (role authenticated); no n8n workflow uses them. Same posture as 064.
--
-- Applied to production on 2026-09-27 right after the cutover.
-- ROLLBACK: GRANT EXECUTE ON FUNCTION <the four below> TO PUBLIC;
-- =====================================================================
REVOKE EXECUTE ON FUNCTION
  cerebro_dashboard_embudo_operaciones(),
  cerebro_dashboard_operaciones_en_curso(),
  cerebro_dashboard_volumen_por_servicio(),
  cerebro_dashboard_operaciones_envejecidas()
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
  cerebro_dashboard_embudo_operaciones(),
  cerebro_dashboard_operaciones_en_curso(),
  cerebro_dashboard_volumen_por_servicio(),
  cerebro_dashboard_operaciones_envejecidas()
TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
