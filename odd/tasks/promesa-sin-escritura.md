# Promise without write: record it and make the next turn fix it

## Objective

When the bot tells a customer that something was "anotado" (or "queda registrado / así") without any write tool
having run in that turn, record the case and leave a system note in the conversation memory so the next turn
registers what is missing. The sent message is never touched.

## Problem and why

The beneficiary-draft analysis (odd/design/beneficiary-draft.md section 2) found replies like "Anotado, es Oberto"
where nothing was written, because the prompt teaches the model that confirming in words is the normal case and
nothing checks the promise. The design's monitoring query (section 9) counted 11 promise-shaped replies without a
write out of 99 in 14 days on production (2026-10-24).

Owner decision 2026-10-24: "avisar y corregir al bot" — record the case, leave a system note, never block or rewrite
the message already sent, no workflow change.

## Scope

- DB-side guard (migration 296): AFTER INSERT on `messages`, `sender_type = 'agent'`, `ai_generated`, content matches
  the promise pattern, and no `tool_execution_log` row for the conversation in [created_at − 3 min, created_at + 1 min].
- One audit row per message in `cerebro_promesas_sin_escritura` (message_id UNIQUE) with the excerpt and the note id.
- One `human`-type `cerebro_memoria` note per case, starting with `[CONTEXTO DEL SISTEMA` (251 keeps such notes
  whole) so the model reads it on the next turn.
- A guard failure never breaks the message insert (EXCEPTION → WARNING), like the calculator feed.

Out of scope: blocking/rewriting the reply, WhatsApp alerts to admins, the full beneficiary draft.

## Pattern

`(^|[^[:alpha:]])anotad[oa]([^[:alpha:]]|$)` | `queda[[:space:]]+(registrad|anotad|as[ií])` |
`qued[oó][[:space:]]+(registrad|anotad)` — the design's pattern plus the common past forms. Implemented as
`cerebro_texto_promete(text)`, IMMUTABLE.

## Tasks

- [x] D1 `cerebro_texto_promete(text)` and the trigger function `cerebro_promesa_sin_escritura_guardar()`.
- [x] D2 Table `cerebro_promesas_sin_escritura` + trigger `zzz_messages_promesa_sin_escritura`; guard function
  revoked from PUBLIC/anon/authenticated.
- [x] D3 Assertion `supabase/staging/assertions/promesa-sin-escritura.sql` (promise/no-write, write in window,
  customer, panel message, pattern forms).
- [x] D4 Staging cycle: dry-run / apply / assertion / rollback OK; related assertions SAME for `cerebro_memoria`.
- [ ] D5 Production: previa, owner go-ahead, apply, verificar.

## Acceptance criteria

- An agent AI message with a promise and no write in the window produces exactly one audit row and one memory note.
- The same promise with a write row in the window produces nothing.
- Customer messages and non-AI agent messages produce nothing.
- The message insert succeeds even if the guard fails.

## Checks

- TDD: enabled. RED before applying (function missing), GREEN through `staging-migracion.sh aplicar`.
- Related assertions: `relacionadas ... "cerebro_memoria"` and the `INSERT INTO messages` set.
- Production: `produccion-migracion.sh previa` (SEGURO) → go-ahead → `aplicar` → `verificar`.

## Progress

- 2026-10-24: migration 296 + ROLLBACK + assertion written; staging cycle green (dry-run, apply, assertion,
  rollback with md5 match). ACL of the guard function has no PUBLIC grant.
- Live rate measured before building: 99 promise-shaped AI replies in 14 days, 11 without a write.
