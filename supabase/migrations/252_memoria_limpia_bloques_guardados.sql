-- =====================================================================
-- 252 -- Remove the context blocks already stored in the Cerebro memory, after a full backup
--
-- 251 stops storing the "[CONTEXTO DEL SISTEMA ...]" block appended to customer turns. The 4,588 rows already stored
-- with it (production, 2026-10-19) would keep replaying stale orders until they leave the 30-message window; this cuts
-- them now, with the same rule as 251.
--
--   - respaldos.cerebro_memoria_bloques_20261019: every row this changes, with its original message, copied BEFORE the
--     change. Not readable by anon / authenticated.
--   - cerebro_memoria_quitar_bloques_guardados(): backs up, then cuts each human message that carries an appended block
--     at "\n\n[CONTEXTO DEL SISTEMA" (trailing blank space trimmed). A message that STARTS with the block (a system note)
--     is not touched; AI messages are not touched. Idempotent: a second run finds nothing. Returns the rows cut.
--   - It runs once here.
--
-- Assertion: supabase/staging/assertions/memory-cleanup-stored-blocks.sql.
-- Rollback: ROLLBACK-252-memoria-limpia-bloques-guardados.sql (restores every cut row from the backup).
-- odd/tasks/cerebro-memory-without-context-block.md
-- =====================================================================

-- Production has the schema (postgres only); staging may not.
CREATE SCHEMA IF NOT EXISTS respaldos;

CREATE TABLE IF NOT EXISTS respaldos.cerebro_memoria_bloques_20261019 (
  id            integer PRIMARY KEY,
  session_id    character varying NOT NULL,
  message       jsonb NOT NULL,
  respaldado_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON TABLE respaldos.cerebro_memoria_bloques_20261019 FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.cerebro_memoria_quitar_bloques_guardados()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n integer;
BEGIN
  -- (252) The original first: a row is never cut without its copy.
  INSERT INTO respaldos.cerebro_memoria_bloques_20261019 (id, session_id, message)
  SELECT m.id, m.session_id, m.message
    FROM cerebro_memoria m
   WHERE m.message->>'type' = 'human'
     AND position(E'\n\n[CONTEXTO DEL SISTEMA' in coalesce(m.message->>'content', '')) > 0
  ON CONFLICT (id) DO NOTHING;

  -- (252) The same cut as 251 on insert.
  UPDATE cerebro_memoria m
     SET message = jsonb_set(m.message, '{content}',
                             to_jsonb(rtrim(left(m.message->>'content',
                                                 position(E'\n\n[CONTEXTO DEL SISTEMA' in m.message->>'content') - 1),
                                            E' \t\r\n')))
   WHERE m.message->>'type' = 'human'
     AND position(E'\n\n[CONTEXTO DEL SISTEMA' in coalesce(m.message->>'content', '')) > 0
     AND EXISTS (SELECT 1 FROM respaldos.cerebro_memoria_bloques_20261019 b WHERE b.id = m.id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_memoria_quitar_bloques_guardados() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_memoria_quitar_bloques_guardados() TO service_role;

SELECT public.cerebro_memoria_quitar_bloques_guardados();
