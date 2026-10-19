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
- [x] C2 — Migration 247 + ROLLBACK; apply on staging, GREEN; rollback proof; related combo assertions rerun.
- [x] C4 — 248: shared negation rule; cerebro_recarga_en_curso per message
      (`supabase/staging/assertions/recarga-negated-mention.sql`).
- [x] C5 — 249: crm_cerrar_operacion_manual maps the chosen service like _cambiar_servicio_core
      (remesa rail -> service_type 'remesa'; combo_costo_gyd cleared unless combo; service change audited).
      Today choosing Zelle on a misfiled combo keeps service_type 'combo'.
- [x] C6 — 250: a re-save of the payee an operation already holds stays on it
      (`cerebro_resolver_operacion_beneficiario`, 'misma_cuenta'); assertion `zelle-payee-resave.sql`.
- [ ] C3 — Production (247-250) with the owner's go-ahead; md5 equal to staging.

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
- 2026-10-19 C2: dry run (247 + assertion, rolled back) `ALL PASS`. 36 related assertions run without
  and with 247 in rolled-back transactions: identical outcomes. Pre-existing failures, unchanged by
  247: deal-insert-creates-operation (case 1), n8n-repoint (fixture setup), operation-incident-reason
  (1 expectation), repeated-receipt (missing pg_temp.conv_prueba).
  247 applied on staging (committed). Assertion GREEN: `ALL PASS`. md5 after 247:
  combo_en_curso 68b6ca38dd4a254206904623d567b8bb, texto_pide_combo aa4951d64887136ec30c3d831509d3ee,
  textos_cliente_desde 4464de581b88bfa3f0b789375b25d21a, textos_cliente_recientes
  f5a8cd444b1cac3f57c2668299a629d6. ACLs: existing ones kept; new helpers service_role only.
  Rollback proof in a rolled-back transaction restored 18a50de6… and 1172a095… exactly; staging left WITH 247.

- 2026-10-19 C1/C2 commit: 5534565.
- 2026-10-19 C4: assertion RED on staging (`case 1: "no quiero recarga" must not be a recharge in
  progress`). Dry run ALL PASS. 28 related assertions (combo, recarga, promo, deposit, textos) without
  and with 248: identical outcomes (pre-existing failures as in C2, plus deals-free-views-and-inert-edits,
  rekey-shipment-alerts-onto-operations and saldo-model case 11, all unchanged by 248). Applied on
  staging; assertion GREEN. md5 after 248: quitar_menciones_negadas fe9ca0ba5f3741a6baaa2dd23cefba87,
  recarga_en_curso e90f049870e260fd8581d0a8f919444c, texto_pide_combo 2cd8e5b8806e78ab86d0d06476e95afb,
  texto_pide_recarga 3afcf006e5f55ed7e1ef8c9811b5e3c1. Rollback proof restored 4146aaff… and aa4951d6….

- 2026-10-19 C4 commit: 594ff34.
- 2026-10-19 C5: assertion `manual-close-service-type.sql` RED on staging (`case 1 ... got
  completed/combo/zelle/28600`). Dry run ALL PASS. 22 related assertions (manual close, combo cost,
  calculator feed) without and with 249: identical outcomes (delivery-feed-evidence fixture failure is
  pre-existing, only its random uuid differs; saldo-model case 11 pre-existing). Applied on staging;
  assertion GREEN; md5 7cefd4e763141b51c90019b34c614b28, ACL unchanged. Rollback proof restored
  00e19f83… exactly. App: close-manual route tests 30/30 (API unchanged).

- 2026-10-19 C5 commit: 1be1e66.
- 2026-10-19 C6: replay of the production sequence on staging with 247-249 (rolled back): Santialv no
  longer replaced, but the auto node's re-save of Santialv after receipt 2 went to the newest, empty
  operation by rule C (amount ties at equal deposits, proximity sees both), so Santialv sat on both
  operations and Orlansys went to a person ('operacion_ambigua'). Fix 250: an account that is already
  the vigente payee of exactly one open remesa, not typed since that row was written, is a re-save of
  it. Assertion RED (`case 1a ... got Santialv LLC|Santialv LLC`), dry run ALL PASS. Related run (77
  assertions: beneficiaries, Zelle, reparto, calculator) with and without 250: one real DIFF,
  beneficiary-matcher case 9, a fixture artifact: its old payee row was dated now() although the case
  models a payee written 4 days earlier, before the account was typed again. Fixture row now dated
  `t0 - 4 days`; beneficiary-matcher 9/9 with and without 250. Applied on staging; GREEN; md5
  fac21833a4dfc2b054cec390aeca8e91; rollback proof restored 80597ea9490b4d87fa93694f3000350c.
  Full replay with 247-250: two remesas, one receipt and one Zelle payee each (Santialv | Orlansys).

- 2026-10-19 RENUMBERED 246-249 -> 247-250: another session in this worktree shipped its own
  `246_telemetria_acepta_uso_tardio` to production at 19:27 (commit 087d006). Content tags and file names
  shifted by one; the md5s recorded above for 246-249 are history. Staging re-applied 247-250 in order;
  assertions combo-negated-mention, recarga-negated-mention, manual-close-service-type,
  zelle-payee-resave ALL PASS; beneficiary-matcher 9/9; full replay: Santialv | Orlansys. Staging md5
  (reference for production): combo_en_curso cc9c50e4ff8104ffc59c4c6cc20be041, quitar_menciones_negadas
  bd0aae0aa3b4668c90ab7b3ef4719cc6, recarga_en_curso 71efb1003fd54b9626a8b180583f0f6c,
  resolver_operacion_beneficiario ff0559595339daf73dfbe65df3a44833, texto_pide_combo
  86cdb85b0d81c249188a622057acf4d8, texto_pide_recarga e1c26ec6b2cea8607184d781f5fe4f85,
  textos_cliente_desde 044b883518205fde1585d2d213ddd0a7, textos_cliente_recientes
  472fa8993639e76cd92231174315dde3, crm_cerrar_operacion_manual de2656032e562e264b020ce223f5812a.

- 2026-10-19 C3 PRODUCTION (owner: "si dale, aplícalo en producción"): renumber commit a7e6859.
  Pre-check: the 5 target functions still at the pre-change md5s; helpers absent. Applied with Supabase
  apply_migration on hqztotshnlzaiziwjyzh, in order: 247_combo_ignores_negated_mention,
  248_recarga_ignores_negated_mention, 249_manual_close_names_the_service, 250_zelle_payee_resave
  (all success). After: all 9 functions byte-equal (md5) to staging, listed above; ACLs unchanged
  (combo_en_curso keeps its default ACL; crm_cerrar_operacion_manual keeps authenticated; new helpers
  service_role only). Read-only checks on production: the Yoandy text is not a combo, "quiero mandar un
  combo" and "No, quiero un combo" are, "no quiero recarga" is not a recharge; conversation c2bb35c0
  no longer reports a combo in progress. Postgres logs: no error mentioning these functions.
  Not done (owner's decision): operation 02a2d634 keeps its saldo/combo-cost data; the commits are
  not pushed.

## Next step
None for this feature. Optional: correct operation 02a2d634 (owner's decision); push the branch (owner's decision).
