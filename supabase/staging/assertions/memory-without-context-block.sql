\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 251 (the Cerebro memory stores what the customer said, not the context block).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- Production 2026-10-19: every customer turn was stored with the [CONTEXTO DEL SISTEMA ...] block appended (97% of the
-- stored text), and the memory replays 30 messages, so the model received up to 27 stale copies per call.
-- Rule asserted: a human message is cut at "\n\n[CONTEXTO DEL SISTEMA"; a message that STARTS with the block (a system
-- note inserted on purpose) is kept whole; the AI-turn rules of 105/107 are unchanged.
-- odd/tasks/cerebro-memory-without-context-block.md.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.put_t251(p_session text, p_type text, p_content text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO cerebro_memoria (session_id, message)
  VALUES (p_session, jsonb_build_object('type', p_type, 'content', p_content, 'additional_kwargs', '{}'::jsonb,
                                        'response_metadata', '{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.get_t251(p_id bigint) RETURNS text LANGUAGE sql AS $$
  SELECT message->>'content' FROM cerebro_memoria WHERE id = p_id;
$$;

DO $$
DECLARE
  v_id bigint; v_m jsonb;
  c_s constant text := 'test251-' || gen_random_uuid();
  c_block constant text := E'[CONTEXTO DEL SISTEMA - el cliente NO ve esto]\n- TASAS DE HOY: 1 GYD = 3 CUP\n- Al responder di: "Por *X GYD* llegan *Y CUP* a Cuba."';
BEGIN
  -- 1. A customer turn with the appended block keeps only what the customer said.
  v_id := pg_temp.put_t251(c_s, 'human', E'Amiga hice la transferencia\n\n' || c_block);
  IF pg_temp.get_t251(v_id) IS DISTINCT FROM 'Amiga hice la transferencia' THEN
    RAISE EXCEPTION 'case 1: the block must not be stored, got %', left(pg_temp.get_t251(v_id), 120); END IF;
  -- ... and the rest of the message is untouched.
  SELECT message INTO v_m FROM cerebro_memoria WHERE id = v_id;
  IF v_m ->> 'type' <> 'human' OR NOT (v_m ? 'additional_kwargs') OR NOT (v_m ? 'response_metadata') THEN
    RAISE EXCEPTION 'case 1b: the message shape must be kept, got %', v_m; END IF;

  -- 2. Multi-line customer text before the block is kept whole (trailing blank space trimmed).
  v_id := pg_temp.put_t251(c_s, 'human', E'Ok\n+53 5 8729435  \n\n' || c_block);
  IF pg_temp.get_t251(v_id) IS DISTINCT FROM E'Ok\n+53 5 8729435' THEN
    RAISE EXCEPTION 'case 2: multi-line customer text must be kept, got %', pg_temp.get_t251(v_id); END IF;

  -- 3. A system note (the message starts with the block) is kept whole.
  v_id := pg_temp.put_t251(c_s, 'human', c_block);
  IF pg_temp.get_t251(v_id) IS DISTINCT FROM c_block THEN
    RAISE EXCEPTION 'case 3: a system note must be stored unchanged'; END IF;

  -- 4. A customer turn without a block is unchanged.
  v_id := pg_temp.put_t251(c_s, 'human', 'hola, cuanto esta el cambio?');
  IF pg_temp.get_t251(v_id) IS DISTINCT FROM 'hola, cuanto esta el cambio?' THEN
    RAISE EXCEPTION 'case 4: a plain customer turn must be unchanged'; END IF;

  -- 5. AI turns keep the 105/107 rules: DSML and raw tool_calls are not stored, SKIP is.
  v_id := pg_temp.put_t251(c_s, 'ai', '<｜DSML｜function_calls> x');
  IF v_id IS NOT NULL AND EXISTS (SELECT 1 FROM cerebro_memoria WHERE id = v_id) THEN
    RAISE EXCEPTION 'case 5a: DSML must not be stored'; END IF;
  v_id := pg_temp.put_t251(c_s, 'ai', 'SKIP');
  IF pg_temp.get_t251(v_id) IS DISTINCT FROM 'SKIP' THEN RAISE EXCEPTION 'case 5b: SKIP must be stored'; END IF;
  v_id := pg_temp.put_t251(c_s, 'ai', E'Listo.\n\n[CONTEXTO DEL SISTEMA - el cliente NO ve esto] (quoted by the model)');
  IF pg_temp.get_t251(v_id) NOT LIKE 'Listo.%CONTEXTO DEL SISTEMA%' THEN
    RAISE EXCEPTION 'case 5c: an AI turn is not cut by this rule'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
