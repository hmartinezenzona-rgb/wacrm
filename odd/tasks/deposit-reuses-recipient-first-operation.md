# A deposit reuses the recipient-first operation

## Objective
When the customer gave the recipient (and a rail) before paying, the deposit lands on THAT operation. It never opens a second one.

## Incident (production, 2026-10-08, "Edel", conversation 54d6444d)
14:01 UTC the customer gave name + phone: `cerebro_crear_operacion(p_amount=0)` opened operation A (0 GYD) with the recipient; later
`marcar_destino_usd('efectivo')` set A to `efectivo_usd`. 16:35 the receipt arrived: `cerebro_registrar_deposito` did NOT reuse A and created B
(29,000 GYD, no rail). The cash rail and recipient stayed on A; the notifier asked a cash customer for Zelle/card data; the owner fixed it by hand.

## Root cause (verified, staging and production definitions are identical)
`cerebro_registrar_deposito` md5 e14bc02d28a6eb6f67c1f0831492ceac on both; same for `cerebro_saldo_operacion` d47a1000..., `cerebro_objetivo_atar_op`
70ba3cb9..., `cerebro_crear_operacion` 58b31f00... (no drift).
The reuse lookup ("movido") excludes an open remesa that has a vigente recipient AND `cerebro_saldo_operacion(op).saldo > 0`. The saldo reads the
conversation's open quote (`cerebro_objetivo_envio` row with `operation_id IS NULL` counts for any operation): 26,000 - 0 deposited > 0, so A was excluded.

## Guard intent (reconstructed, not written down anywhere)
156 (deals world): `NOT (d.value > 0 AND notes LIKE '%BENEFICIARIO%')`. `value` is money ALREADY on the deal. A deal with money AND a recipient is a
complete remittance; a new deposit is a different remittance and must not be poured into it. 160 translated "money already there" to
`saldo > 0` (money still OWED): the opposite meaning for a recipient-first operation, where nothing is deposited and the whole quote is owed.
Evidence for the intent: 156/160 comments, 160 case 3 of `deposit-path-without-deals.sql` (an open op without a receipt is the movido target).

## Rule
Before: skip an open remesa without a comp receipt when `vigente recipient AND saldo > 0`.
After: skip it only when `vigente recipient AND saldo > 0 AND holds money`. "Holds money" = `quoted_source_amount > 0` OR any receipt row OR
`depositado > 0` (depositos_mmg consumed). Plus, only for the widened case (no money), the op must not be in `incident` and must not have
`quoted_source_amount` in `admin_locked_fields` (a locked amount would swallow the deposit amount). Everything else is unchanged:
ordering (latest first), service filter, ambiguous cases (latest wins, as today).

## TDD
Mode strict, source user global CLAUDE.md. Runner: staging SQL assertion `supabase/staging/assertions/deposit-reuses-recipient-first-operation.sql`,
docker postgres:17 psql against CRM_STAGING_DATABASE_URL, wrapped `BEGIN; <assertion minus its BEGIN/ROLLBACK>; ROLLBACK;`.

## Tasks
- [x] D1 - Assertion (Edel sequence + guards + unchanged behaviours), RED on staging.
- [x] D2 - Migration 232 + ROLLBACK, apply on staging, GREEN, rollback proof (rolled-back transaction).
- [x] D3 - Related assertions rerun; production open zero-amount report.
- [ ] D4 - Commits.

## Out of scope / findings to report
Stale objective (quote 26,000 Zelle vs cash 29,000): reported, not fixed.

## Evidence (staging, 2026-10-08)
- D1 RED: case E failed `got creado` on the pre-232 function (fixture valid, wrong reason excluded).
- D2: 232 applied (`BEGIN; 232; COMMIT;`), assertion GREEN (E, G1-G5, U1-U4; I1 informational). Fingerprint after:
  `cerebro_registrar_deposito` md5 70f46bfffab31d1c00543db3529119ad, ACL `{postgres, service_role}`. Rollback proof: ROLLBACK-232 inside a rolled-back
  transaction restored md5 e14bc02d28a6eb6f67c1f0831492ceac with the same ACL. Staging left WITH 232; no fixture rows.
- D3 related assertions on staging with 232: add-beneficiary, deposit-review, clasica-card-from-delivery-method, deal-free-money-rules, combo-deposit-calculator,
  recarga-before-deposit, deposit-path-without-deals, operation-receipts, recarga-needs-promo, recarga-by-audio, visa-model, recarga-numbers,
  registrar-deposito-creado, split-deposit-minimums, repeated-receipt (with split-deposit-minimums helpers), verify-deposit-status-drift: all PASS.
  Failing identically WITHOUT 232 (rollback applied in the same transaction), so not caused by it: deal-insert-creates-operation, operation-incident-reason [1],
  n8n-repoint (deal-era fixtures); live-baseline-parity is a capture-mode file.
- Production (SELECT only): function md5s identical to staging (no drift). Open zero-amount operations today: 7a9ac5b6 (conv 4098601d) and 9e8e7acf
  (conv 0949c5a9), both remesa, collecting_information, 1 vigente recipient, no receipt, no rail, saldo NULL (no open quote), no other open operation.
  Today the next deposit already lands on them (saldo NULL -> 0); the moment a quote exists they would hit the Edel bug. With 232 they land correctly in both cases.
- Amount mismatch (Edel data: quote 26,000, rail cash, deposit 29,000), staging probe in a rolled-back transaction: registrar -> `movido` on A; the objective is
  re-set to the deposit by `cerebro_objetivo_minimo` (objetivo 29,000, saldo 29,000 before the cross); `cerebro_cruzar_depositos` -> verificado,
  A ready_to_transfer, 29,000 deposited, one open operation. The stale 26,000 quote does NOT block this path. Separate defect NOT found here; the
  "envio mas de lo hablado" text lives in the bot/n8n, not in these functions (not inspected, out of scope).
- Non-remesa: the function picks the service from the OPEN operation (recarga > combo > visa), not from the deposit; a zero-amount open visa with a recipient
  now absorbs the deposit as visa (before: a second operation was created as visa). Not changed.
