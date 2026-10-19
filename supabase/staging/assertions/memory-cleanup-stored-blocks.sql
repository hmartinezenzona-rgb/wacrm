\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 252 (the context blocks already stored in the Cerebro memory are cut, after a backup).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- Fixture rows are written with the insert trigger disabled, the way rows stored before 251 look.
-- Rule asserted: cerebro_memoria_quitar_bloques_guardados() cuts every human message with an APPENDED block, copies each
-- one to the backup first, leaves system notes and AI messages alone, is idempotent, and 252's rollback restores them.
-- odd/tasks/cerebro-memory-without-context-block.md.
-- =====================================================================
ALTER TABLE cerebro_memoria DISABLE TRIGGER trg_cerebro_memoria_sin_basura;
CREATE TEMP TABLE t252 (k text PRIMARY KEY, id integer);
DO $$
DECLARE
  c_s constant text := 'test252-' || gen_random_uuid();
  c_block constant text := E'[CONTEXTO DEL SISTEMA - el cliente NO ve esto]\n- TASAS DE HOY: 1 GYD = 3 CUP';
BEGIN
  INSERT INTO cerebro_memoria (session_id, message) VALUES
    (c_s, jsonb_build_object('type', 'human', 'content', E'Amiga hice la transferencia\n\n' || c_block, 'additional_kwargs', '{}'::jsonb)),
    (c_s, jsonb_build_object('type', 'human', 'content', c_block, 'additional_kwargs', '{}'::jsonb)),
    (c_s, jsonb_build_object('type', 'ai', 'content', E'Listo.\n\n' || c_block, 'additional_kwargs', '{}'::jsonb)),
    (c_s, jsonb_build_object('type', 'human', 'content', 'hola', 'additional_kwargs', '{}'::jsonb));
  INSERT INTO t252 SELECT CASE WHEN m.message->>'type' = 'ai' THEN 'ai'
                               WHEN m.message->>'content' LIKE '[CONTEXTO%' THEN 'note'
                               WHEN m.message->>'content' = 'hola' THEN 'plain' ELSE 'appended' END, m.id
                      FROM cerebro_memoria m WHERE m.session_id = c_s;
END $$;
ALTER TABLE cerebro_memoria ENABLE TRIGGER trg_cerebro_memoria_sin_basura;

DO $$
DECLARE v_n integer; v_b integer; v_before jsonb;
BEGIN
  SELECT count(*) INTO v_b FROM respaldos.cerebro_memoria_bloques_20261019;
  SELECT message INTO v_before FROM cerebro_memoria WHERE id = (SELECT id FROM t252 WHERE k = 'appended');
  v_n := cerebro_memoria_quitar_bloques_guardados();

  -- 1. The appended block is cut; the copy holds the original.
  IF (SELECT message->>'content' FROM cerebro_memoria WHERE id = (SELECT id FROM t252 WHERE k = 'appended')) IS DISTINCT FROM 'Amiga hice la transferencia' THEN
    RAISE EXCEPTION 'case 1: the appended block must be cut'; END IF;
  IF (SELECT message FROM respaldos.cerebro_memoria_bloques_20261019 WHERE id = (SELECT id FROM t252 WHERE k = 'appended')) IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'case 1b: the backup must hold the original message'; END IF;

  -- 2. System note, AI message and plain customer text are untouched and not backed up.
  IF (SELECT message->>'content' FROM cerebro_memoria WHERE id = (SELECT id FROM t252 WHERE k = 'note')) NOT LIKE '[CONTEXTO DEL SISTEMA%' THEN
    RAISE EXCEPTION 'case 2a: a system note must be untouched'; END IF;
  IF (SELECT message->>'content' FROM cerebro_memoria WHERE id = (SELECT id FROM t252 WHERE k = 'ai')) NOT LIKE E'Listo.\n\n[CONTEXTO%' THEN
    RAISE EXCEPTION 'case 2b: an AI message must be untouched'; END IF;
  IF EXISTS (SELECT 1 FROM respaldos.cerebro_memoria_bloques_20261019 b JOIN t252 t ON t.id = b.id WHERE t.k <> 'appended') THEN
    RAISE EXCEPTION 'case 2c: only cut rows are backed up'; END IF;

  -- 3. Nothing with an appended block is left anywhere, and the backup grew by exactly the rows cut.
  IF EXISTS (SELECT 1 FROM cerebro_memoria WHERE message->>'type' = 'human'
              AND position(E'\n\n[CONTEXTO DEL SISTEMA' in coalesce(message->>'content', '')) > 0) THEN
    RAISE EXCEPTION 'case 3a: an appended block is left'; END IF;
  IF (SELECT count(*) FROM respaldos.cerebro_memoria_bloques_20261019) - v_b <> v_n THEN
    RAISE EXCEPTION 'case 3b: backup rows (%) must equal rows cut (%)', (SELECT count(*) FROM respaldos.cerebro_memoria_bloques_20261019) - v_b, v_n; END IF;

  -- 4. Idempotent.
  IF cerebro_memoria_quitar_bloques_guardados() <> 0 THEN RAISE EXCEPTION 'case 4: a second run must cut nothing'; END IF;

  -- 5. The rollback statement restores the original.
  UPDATE cerebro_memoria m SET message = b.message FROM respaldos.cerebro_memoria_bloques_20261019 b
   WHERE b.id = m.id AND m.message IS DISTINCT FROM b.message;
  IF (SELECT message FROM cerebro_memoria WHERE id = (SELECT id FROM t252 WHERE k = 'appended')) IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'case 5: the rollback must restore the original message'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
