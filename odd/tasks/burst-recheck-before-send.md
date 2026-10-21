# Burst: re-check before sending

## Objective

When the customer writes again while the Cerebro is still answering the previous batch, do not send the stale reply:
hand the batch back so the newest execution answers everything together.

## Problem and why

- Measured 2026-10-21 (prod, 30 days): 275 of 2,555 batches (10.8%) started while the previous batch was still being
  processed; 75% arrive 12-20 s after the previous message. The 12 s window already merges messages that arrive
  before the claim; these arrive after it.
- Mechanism (mapped 2026-10-21): batch A is claimed (`cerebro_reclamar_lote`, events -> processing); B arrives,
  waits 12 s, finds itself the newest and claims [B] alone; A's reply passes `cerebro_valla_de_propiedad` (checks
  pause/hidden/assignment/handoff/human message, never newer customer events) and is sent; then B is answered apart.
  A's gate usually runs before B's claim (median last message -> close 18.6 s), so B is still `pending` then.
- Owner chose option 2 (re-check before send) over a longer window (2026-10-21).

## Scope

- In: one migration (staging first): `cerebro_reclamar_lote` records the memory baseline; `cerebro_valla_de_propiedad`
  gets check 6 that releases the batch and drops this turn's memory rows; per-conversation advisory lock in both.
- Out: n8n node changes (none needed: "Valla de propiedad" -> "Puede enviar?" -> "Silencio por propiedad" -> "Cerrar
  lote" already exists); the race where B already claimed [B] before A's gate (A sends as today).

## Design

- `cerebro_ejecuciones.memoria_hasta integer`: max `cerebro_memoria.id` of the session when the batch is claimed.
- Check 6 runs after checks 1-5 and only drops when ALL hold, otherwise A sends as today (fail open):
  - a newer event of the conversation (id > max id of A's batch) is `pending`/`retry_wait` (unclaimed);
  - A's batch has no image/document event (deposits and receipts have side effects);
  - no tool other than pure calculation (`calcular_*`, `consultar_*`) is logged for A's execution;
  - `memoria_hasta` is known.
  Then: A's events back to `pending` (exec id and start cleared, retry_count unchanged), memory rows of the session
  with id > `memoria_hasta` deleted, return `bloquear=true, motivo='mensaje_nuevo_durante_el_turno'`.
- `pg_advisory_xact_lock` on the conversation in both functions so a release and a claim never interleave.

## Constraints

- Staging first via `infra/db/staging-migracion.sh`; production only with the owner's explicit go-ahead.
- Never execute the staging or production Cerebro workflow (staging shares production's WhatsApp token): the DB
  assertion is the test.
- TDD strict: assertion RED before the migration.

## Tasks

- [x] R1 Migration 259 + ROLLBACK + assertion `burst-recheck-before-send.sql`; staging cycle and related assertions.
- [ ] R2 Production `previa`, owner go-ahead, `aplicar`, `verificar`.
- [ ] R3 Watch production: count `mensaje_nuevo_durante_el_turno` silences and re-measure the split rate after some days.

## Acceptance criteria

- Assertion cases: drop and release on a newer unclaimed event; no drop without one, with the newer event already
  claimed, with a write tool, with an image, without a memory baseline; checks 1-5 keep precedence; calc tools do not
  prevent the drop; the next claim returns A+B; baseline recorded at claim.
- Rollback restores both function bodies byte for byte (md5) and drops the column.

## Applicable checks

- `infra/db/staging-migracion.sh aplicar ...` all OK; `relacionadas` on `cerebro_reclamar_lote|cerebro_valla`.

## Progress

- 2026-10-21 created after the mapping; staging and production bodies equal (valla a8519309, reclamar 5b66d55b).

- 2026-10-21 R1 (48dd654): assertion RED first (`column "memoria_hasta" does not exist`), then GREEN 9 cases.
  Found the gate executable by PUBLIC; 259 revokes it (it now writes) and grants service_role only; the rollback
  rebuilds the original ACL order. Staging: dry-run, apply, assertion OK; rollback restores reclamar 5b66d55b,
  valla a8519309 and ACL {=X,postgres,service_role} exactly (first run log; the second run's md5 FAIL compares
  against the already-applied state). Related: burst SAME/DIFF expected, memory-cleanup-stored-blocks and
  memory-without-context-block SAME. Production `previa`: both functions EQUAL, 18 table objects equal, SEGURO.
  Not testable end to end: the Cerebro workflow must never be executed on staging.

## Next step

R2: owner go-ahead, then `produccion-migracion.sh aplicar` + `verificar`; R3 watch.
