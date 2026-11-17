# Fix: silent capture never opens a send

## Objective
`cerebro_capturar_en_silencio` (migration 374) stores a Zelle account in an EXISTING open send while a person attends the chat. It must
never open a send.

## Problem / why
Production conversation 78e3540b (customer Elisvan, 2026-11-17): chat paused for a person, previous send 66ab11eb already completed, the
customer sent holder + account so the money could be re-sent after a bounced transfer. 374 delegated to `cerebro_guardar_zelle_auto`,
whose "no open send + holder + account" branch opens a send: it opened 73a89429 (0 GYD, waiting for deposit; audit
`agent_service_change` by `automation:recipient_writer`, exec 767058). The bot then asked a customer who had already paid for a new
13,000 GYD deposit and a new receipt. It also bypassed the Decisor rule of 2026-11-06 (no open send and no new request -> ask first).
Only this conversation was affected (checked: the other 3 sends opened by the writer since 2026-11-15 are normal, with deposit).

## Owner decisions
- 2026-11-17: "si" to fixing the capture function first. Production needs its own go-ahead.

## Scope
In: migration 376 (replaces the function body), ROLLBACK-376, the assertion `silent-capture.sql`. Out: the derivation expiry (5 min),
the "re-send of a completed remittance" question for the bot, the panel work, the phantom operation (deleted from the panel by an admin).

## Constraints
Strict TDD (user CLAUDE.md). Staging first. No AI attribution in commits. Never touch the other session's files.

## Tasks
- [x] T1 Assertion first (8a/8b no open send, 8c Elisvan shape, 10 two open sends) RED, then migration 376 GREEN on staging
- [ ] T2 Production migration 376 (needs go-ahead)
- [ ] T3 Phantom operation 73a89429: an admin deletes it from the panel (not verified, 0 GYD) or I do it audited on request

## Acceptance criteria
- No open send: nothing written and no send opened (account alone, holder + account). Only a completed send: same. Two open sends and no
  evidence: nothing written. One open send: the account is stored there as before.

## Progress / evidence
- T1 (2026-11-17): assertion on the 374 body: 4 of the new expectations FAIL (8b and 8c reproduce the bug: "SE ABRIO UN ENVIO NUEVO";
  8a and 10 fail on the returned text). Migration 376: `staging-migracion.sh aplicar` dry-run/apply/assertion/rollback OK, md5 equal;
  staging function md5 af0a162a, resolves with `cerebro_resolver_operacion_beneficiario` and no longer calls
  `cerebro_guardar_zelle_auto`. Related assertions (pattern capturar_en_silencio|silent-capture|zelle_auto|guardar_zelle,
  --ya-aplicada): TOTAL 22, SAME 21, DIFF 1 (silent-capture RED->GREEN). The SAME failures (grants-mirror-production, implicit-declaration,
  zelle-payee-resave, deal-free-beneficiary-writers) fail identically on the base. Production dry run: previa SEGURO, live function is
  still the 374 body (md5 ea5bd647).

## Next step
T2: owner go-ahead for production migration 376.
