# Combo detector: a negated "combo" is not a combo order

## Objective
`cerebro_combo_en_curso` must not report a combo in progress when the customer only mentions
"combo" to rule it out (for example pasted Zelle instructions saying "do not write combo").

## Problem (production, 2026-10-19, conversation c2bb35c0, customer Yoandy cruz)
Two MMG deposits of 28,600 GYD for two Zelle transfers of 110 USD. At 15:40:08 the customer pasted
the Zelle payee instructions, which end with:

> ⚠️NO ESCRIBIR NADA DE CUBA REMESAS NI COMBO ECT ⚠️

`cerebro_combo_en_curso` (migration 209) matches `\mcombos?\M` against
`cerebro_textos_cliente_recientes`, so it returned TRUE. At 15:40:20 the first receipt reached
`cerebro_registrar_deposito`, which created operation `02a2d634` with `service_type = 'combo'`.
An operator later set its combo cost and closed it manually with method `saldo`, which is why the
calculator shows it as SALDO_MOVIL (`crm_cerrar_operacion_manual` overwrites `service_type`).

## Why it happens
- The rule looks for the bare word and cannot tell "quiero un combo" from "ni combo".
- `cerebro_textos_cliente_recientes` joins messages with a space, so a negation rule over the
  joined text would glue a trailing "no" of one message to the "combo" of the next. The rule
  therefore has to run per message.

## Scope
- New `cerebro_texto_pide_combo(text)`: IMMUTABLE, the text rule for ONE message. A mention
  preceded in the same clause (no `. , ; : ! ? ¡ ¿` or newline in between, up to 60 chars) by
  `no | ni | nada | sin | nunca | tampoco` is discarded before matching.
- New `cerebro_textos_cliente_desde(conv)`: the start of the recent-text window, extracted from
  `cerebro_textos_cliente_recientes`, which now uses it (same output).
- `cerebro_combo_en_curso`: the text branch tests each message in the window with the new rule.
  The open-combo branch and the pending-card guard are unchanged.

Out of scope (follow-ups, owner's decision):
- Manual close with method `saldo` silently rewriting `service_type`.
- A second Zelle payee replacing the first on the same operation instead of opening another.
- `cerebro_recarga_en_curso` has the same bare-word shape (`recarga|etecsa|cubacel`).
- `cerebro_combo_en_curso` has a default ACL (PUBLIC can execute); kept as is here.

## Constraints
- Staging first, production only with the owner's explicit go-ahead; rollback file required.
- Known accepted miss: "no se si mandar un combo" is no longer a combo order (ambiguous anyway;
  the agent can still open a combo with its recipients, which the open-combo branch catches).

## TDD
- Mode: strict, source user global CLAUDE.md.
- Runner: staging SQL assertion `supabase/staging/assertions/combo-negated-mention.sql`, docker
  `postgres:17` psql against `CRM_STAGING_DATABASE_URL` (`.env.staging`), self-reverting.

## Tasks
- [x] C1 — Assertion (Yoandy sequence end to end + rule cases + unchanged behaviours), RED on staging.
- [x] C2 — Migration 246 + ROLLBACK; apply on staging, GREEN; rollback proof; related combo assertions rerun.
- [ ] C3 — Production with the owner's go-ahead; md5 equal to staging.

## Acceptance criteria
- The Yoandy message alone: `cerebro_combo_en_curso` FALSE and the deposit opens a `remesa`.
- "quiero mandar un combo", "quiero 2 combos", "quiero mandar comida" still TRUE.
- "no", then "quiero un combo" in the next message: TRUE.
- `cerebro_textos_cliente_recientes` output unchanged.
- Existing combo assertions (combo-model, combo-deposit-calculator, combo-edit,
  combo-ignores-remesa-writers) still pass.

## Progress
- 2026-10-19: root cause verified read-only on production (messages, `cerebro_lecturas_vision`,
  `remittance_operation_receipts`, `remittance_admin_audit`, function bodies). Production md5s:
  `cerebro_combo_en_curso` 18a50de6dbc7bffb63cde956b3348d59,
  `cerebro_textos_cliente_recientes` 1172a0956f32cb06b5b32ecb0beccdf6.

- 2026-10-19 C1: staging md5s identical to production (no drift). Assertion RED for the right reason:
  `case 1: a negated "combo" in pasted Zelle instructions must not be a combo in progress`.
  The first fixture of case 7 (an operation inserted as completed) was coerced to incident by
  `remittance_operations_completion_guard`; case 7 now closes the window with a cancelled one.
- 2026-10-19 C2: dry run (246 + assertion, rolled back) `ALL PASS`. 36 related assertions run without
  and with 246 in rolled-back transactions: identical outcomes. Pre-existing failures, unchanged by
  246: deal-insert-creates-operation (case 1), n8n-repoint (fixture setup), operation-incident-reason
  (1 expectation), repeated-receipt (missing pg_temp.conv_prueba).
  246 applied on staging (committed). Assertion GREEN: `ALL PASS`. md5 after 246:
  combo_en_curso 68b6ca38dd4a254206904623d567b8bb, texto_pide_combo aa4951d64887136ec30c3d831509d3ee,
  textos_cliente_desde 4464de581b88bfa3f0b789375b25d21a, textos_cliente_recientes
  f5a8cd444b1cac3f57c2668299a629d6. ACLs: existing ones kept; new helpers service_role only.
  Rollback proof in a rolled-back transaction restored 18a50de6… and 1172a095… exactly; staging left WITH 246.

## Next step
C3: production, only with the owner's go-ahead.
