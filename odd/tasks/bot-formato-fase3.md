# Bot conversation format, phase 3: one reply as several WhatsApp messages, in order

## Objective

Send a bot reply as several short WhatsApp messages (one per idea) instead of one block, without
the customer ever seeing them out of order, on the live production Cerebro (versionId 0922ab9f).

## Problem and why

- Phases 1 and 2 made each reply cleaner, but a reply with several ideas (data block, deposit
  account, status, question) is still one long bubble.
- Research (pasted by the owner on 2026-10-28): one message per idea, the question alone at the
  end, data to copy (the deposit account) in its own message. Meta's Cloud API does not guarantee
  the delivery order of back-to-back sends; the safe way is to wait for the `delivered` status of
  each message before the next one, or at least about 1 s between sends (reduces, does not remove,
  the risk). Optional "typing..." indicator.
- Today the `Renderer conversacional` node never splits (V1, max one delivery unit) and the reply
  leaves as one POST to WaCRM.

## Facts (2026-10-28)

- Path: Agente Remesas -> Renderer (shadow) -> Presentation Compiler V2 -> Normalizar formato
  (fail-closed boundary) -> Respuesta valida? -> Valla de propiedad -> Puede enviar? -> Encolar en
  outbox (`cerebro_outbox_encolar`, ONE row per turn, key `conv:<last wamid>`) -> Enviar directo?
  -> Despertar al enviador -> Cerrar lote -> telemetry.
- `outbox_activo = si` since 2026-08-11 (212 rows `sent` in 3 days): the real sender is the n8n
  workflow "Cerebro - Enviador del outbox" `K4ijL3NzmY1VX7XI` (every 30 s or woken by the Cerebro;
  claims up to 10 rows `ORDER BY created_at ... FOR UPDATE SKIP LOCKED`, POSTs each to WaCRM
  `/api/v1/messages`, records `cerebro_outbox_resultado`). First backup ever:
  `/home/onlinefreedom/cerebro-fase1/respaldos-n8n/enviador-K4ijL3NzmY1VX7XI-e3d2e4b4-...-20261028-125233.json`.
- Splitting today would break order: concurrent sender runs can claim parts of one reply in
  parallel; a failed part retries after 10/30/120 s while later parts go out; no pause.
- WaCRM stores per-message status from the webhook (`messages.status` by wamid); no typing
  indicator support.
- Production outbox function bodies (067 missing from the repo):
  `odd/backups/outbox-prod-defs-20261028.sql`.

## Design (owner approved 2026-10-28: "si, adelante con ese diseño siempre y cuando no se lleguen ideas a medias")

1. Cut in the Cerebro with code, not with the model, after the guards (`Puede enviar?` true),
   on the blank lines between blocks that phase 2 already asks for. No idea may be cut:
   - never split inside a block;
   - a block ending with ":" always goes with the next block;
   - a list (lines starting with "-", "*" or "1.") stays whole;
   - a very short loose sentence joins its neighbour;
   - at most 4 messages: extra blocks are merged with neighbours, text is never dropped;
   - any doubt (one block, unbalanced bold, parse issue) -> one message, exactly as today.
2. Enqueue all parts atomically (all or none), each with its order number; idempotency key per
   part.
3. The outbox guarantees order per conversation: part N+1 can only be claimed after part N is
   `sent`; two concurrent sender runs can never send two parts of one reply.
4. The sender pauses about 1.5 s between parts and re-claims at once instead of waiting 30 s.
5. If a part fails for good, the remaining parts are not sent and the admin is notified.
6. Flag in `cerebro_config` (`opt_partir_respuesta`): off = exactly today's single message.
   No typing indicator (not supported by WaCRM).

## Constraints

- Never execute the workflows. Backup before writes; owner go-ahead before every production write.
- A financial reply must never be delivered half: if a later part fails, the customer must not be
  left with a partial instruction.
- Keep phases 1 and 2 behaviour; customers keep sending data in any order.

## TDD

- Strict, on. Runners: `npx vitest run` for WaCRM code and `pruebas/decisor/produccion` for the
  Decisor; node code tested offline the same way as the Decisor where possible.

## Tasks

- [x] F3.0 Map the outbound path (see Facts).
- [x] F3.1 Design and owner decisions (see Design).
- [x] F3.2 Splitter `pruebas/partir/` (partir.jscode, correr.ts md5 pin, fixtures.ts, partir.test.ts).
  RED 63 failing (stub) -> GREEN 96/96; `npx vitest run pruebas/decisor pruebas/partir` 253/253.
  Fail-closed to one part (flag not 'si', one block, < 160 chars, odd '*', SKIP, ends with ':',
  exception). Real examples: ex1 2, ex2 4, ex3 2, ex4 3, ex5 2, ex6 4, ex7 4, ex8 4, ex9 2, ex10 1.
- [x] F3.3 Migration 348 `supabase/migrations/348_outbox_partes.sql` + ROLLBACK + assertion
  `supabase/staging/assertions/outbox-partes.sql`. STAGING ONLY: dry-run OK, apply OK, assertion
  OK, rollback OK (md5 equal); `relacionadas` 15/15 SAME. Staging now HAS 348 applied (production
  does not); the next production migration must not assume 348 is there. Number 348 not yet
  checked against production `schema_migrations`.
  Found bug (also fixed by 348): `outbox_status_chk` forbids `failed_direct`, which
  `cerebro_outbox_resultado` writes when a direct send fails. Harmless today (`outbox_activo=si`,
  no direct sends).
  Open points if phase 3 is ever resumed: shadow mode joins parts into one message; who feeds
  `opt_partir_respuesta` to the node; grant of the new function (service_role only); notification
  wording; the 40-character join threshold (ex10 collapses to one part); concurrent-claim test is
  sequential.
- [ ] F3.4 Cerebro workflow: "Partir respuesta" node + enqueue call behind the flag; telemetry.
- [ ] F3.5 Sender workflow: pause and immediate re-claim between parts.
- [ ] F3.6 Production with go-ahead (migration, both workflows, flag on), verification, snapshot.

## Owner decision 2026-10-28 (after the design)

- "no me molesta que envie un solo mensaje pero bien estructurado y que se lea bien" / "si podemos
  dejar en produccion respuestas bien estructuradas a los clientes x mi perfecto".
- Production stays with ONE well-structured message (phase 2). Phase 3 is PARKED: finish only up
  to staging (splitter + tests + migration validated on staging), never production unless the
  owner asks after watching phase 2 replies. Flag `opt_partir_respuesta` stays 'no'.

## Progress

- 2026-10-28 created. RDD off.

## Next step

Finish F3.2 + F3.3 on staging only; F3.4-F3.6 parked by the owner.
