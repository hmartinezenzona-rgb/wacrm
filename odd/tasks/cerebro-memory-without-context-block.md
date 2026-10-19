# Cerebro memory stores what the customer said, not the context block

## Objective
Stop the Cerebro chat memory (`cerebro_memoria`) from storing the `[CONTEXTO DEL SISTEMA ...]`
block appended to every customer turn, and remove the copies already stored, so the model
receives each turn's block once (fresh) instead of up to 30 stale copies.

## Problem (measured on production, 2026-10-19)
- The agent's input is `{{ $json.mensaje }}` = customer text + `\n\n[CONTEXTO DEL SISTEMA - el
  cliente NO ve esto]` + the block. `memoryPostgresChat` (`contextWindowLength: 30`) saves that
  input as the human message, and replays up to 30 messages per call.
- 4,726 human messages carry the block, never twice, always at the end; the customer's text averages
  64 chars, the stored message 2,712. Measured by the prompt session (engram #489): one call had the
  block 27 times, ~60% of the input; the stale copies carry old orders (e.g. the removed CUP default).
- 140 human messages START with the block: notes inserted on purpose by `limpiar_memoria_al_liberar`
  (human attention ended) and `cerebro_rescatar_dsml` (a tool result). They are kept.

## Scope
- 251: `cerebro_memoria_sin_basura` (BEFORE INSERT on cerebro_memoria) also cuts a human message at
  `\n\n[CONTEXTO DEL SISTEMA`, keeping only the customer's text. AI-turn rules unchanged (DSML /
  tool_calls dropped, SKIP kept). A message that starts with the block is kept whole.
- 252: one-off cleanup of the rows already stored, after a full copy of every row it changes in
  `respaldos.cerebro_memoria_bloques_20261019`.
- Not changed: n8n (the current turn keeps its full block), the window of 30, any other table.

## Constraints
- Owner go-ahead for both parts: "las dos partes, dale" (2026-10-19). Production after staging.
- Owner closed memory/context work on 2026-09-26 ("no sacrificar contexto"): this keeps every
  current-turn context and every system note; it only removes stale duplicates.
- The idea comes from the parallel prompt session (engram #489); see coordination/migration-numbers.

## TDD
- Mode: strict, source user global CLAUDE.md.
- Runner: staging SQL assertion `supabase/staging/assertions/memory-without-context-block.sql`,
  docker `postgres:17` psql against `CRM_STAGING_DATABASE_URL`, self-reverting.

## Tasks
- [x] M1 — Assertion RED on staging (appended block stripped; system note kept; AI rules unchanged).
- [x] M2 — 251 + ROLLBACK on staging, GREEN, rollback proof; related memory assertions rerun.
- [x] M3 — 252 cleanup + backup + ROLLBACK on staging (count, idempotence, restore proof).
- [ ] M4 — Production: 251 then 252; verify counts, md5, and a real conversation's next stored turn.

## Acceptance criteria
- A new human message `texto\n\n[CONTEXTO DEL SISTEMA...]...` is stored as `texto`.
- A human message that starts with the block is stored unchanged.
- AI messages: DSML / tool_calls dropped, SKIP kept, as before.
- After 252: no human message keeps an appended block; the backup holds exactly the changed rows
  with their original content; 140 system notes untouched.

## Progress
- 2026-10-19: production trigger function md5 8cc5f5f8656da415b0d15be39b429977 (= staging);
  4,588 human rows with an appended block on production, 4 on staging.

- 2026-10-19 M1: `memory-without-context-block.sql` RED on staging (`case 1: the block must not be
  stored`). No earlier assertion covers cerebro_memoria. Checked by reading production: the three
  inserts of limpiar_memoria_al_liberar and cerebro_rescatar_dsml start with the block (kept by 251).
- 2026-10-19 M2: 251 dry run ALL PASS; applied on staging; GREEN; md5 154fcb6910d1d1b3effcf2f918b4046a
  (ACL unchanged); rollback proof restored 8cc5f5f8… exactly.
- 2026-10-19 M3: `memory-cleanup-stored-blocks.sql` RED without 252 (backup table missing); staging had
  no `respaldos` schema, so 252 creates it IF NOT EXISTS (production: exists, postgres-only ACL,
  unchanged). Dry run ALL PASS. Applied on staging: appended 4 -> 0, system notes untouched, memory
  text 25,086 -> 8,367 bytes, backup 4 rows, second run cuts 0, rollback proof restores 4 and 25,086
  bytes exactly; staging left WITH 252.

## Next step
M4: production, 251 then 252.
