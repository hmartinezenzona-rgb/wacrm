# Mixed send: one deposit split across several operations

## Objective
Let one customer deposit pay for several services at once (for example a 70 USD Clasica card
remittance plus a phone top-up) and have each service carry its own share. Operators set or correct
the split in the panel, and the Cerebro bot can make the same split. Owner decision 2026-10-20:
option B, a group of operations (each keeps ONE `service_type`) sharing one deposit. The rejected
option A was one operation holding several services.

## Problem (verified 2026-10-20, conversation f8b7779c)
- The customer deposited 24,400 GYD for 18,200 GYD (70 USD Clasica) plus 6,200 GYD (recarga).
- `cerebro_registrar_deposito` (mig 232) gives a receipt ONE service and ONE operation.
- Remesa op 3fb87be2 got `quoted_source_amount` = 24,400, so `crm_calcular_monto_destino` made it
  93 USD. The cross-check saw 24,400 against the 18,200 quote, giving `verificado_de_mas` and an
  incident.
- The operator forced verification and closed it manually. The record still says 93 USD.
- Recarga op 6ebbc4d6 was left in `collecting_information` with 0 GYD.
- The panel has no way to put the two services on one deposit.
- Maps of the current model: engram #507, plus this document's Design section.

## Design
- **Grouping.** New column `remittance_operations.mixed_group_id uuid`. It is NULL for every
  existing operation. The group id is the id of the operation that holds the deposit, called the
  anchor.
- **Group money.** `cerebro_saldo_operacion(p_op)` changes for an operation inside a group:
  - `objetivo` is the sum of `quoted_source_amount` over the group's non-cancelled operations.
  - `depositado` is the sum of consumed, non-voided `depositos_mmg` linked to any group operation.
  - The result is the same for every member.
  - Operations outside a group are byte-for-byte unchanged.
  - This removes the false "de mas" incident without touching the per-conversation objective table.
- **Split RPC.** `crm_repartir_envio(p_operation_id uuid, p_partes jsonb)` is used by the panel and,
  through a wrapper, by the bot.
  - Each part is `{servicio, metodo?, monto_gyd}`, where `servicio` is a key of
    `OPERATION_SERVICES` (cuban_card, zelle, clasica, tropical, efectivo_usd, recarga, combo, visa,
    saldo).
  - The parts must add up EXACTLY to the group's current total `quoted_source_amount`. The split
    only redistributes money; it never creates or loses any.
  - The anchor keeps the part matching its own service and rail.
  - Each other part reuses an open operation of that service in the same conversation that is not
    already in another group. If there is none, a new operation is created with the same
    account, contact and conversation.
  - It writes `quoted_source_amount`. For remesa rails the existing trigger recomputes the
    destination amount (18,200 gives 70 USD).
  - It locks `quoted_source_amount` like a human correction, so automation cannot overwrite a share.
  - It writes one audit row per change.
  - If the group already has consumed deposits and the group saldo is 0, every open member in
    `incident`, `collecting_information` or `deposit_verification` goes to `ready_to_transfer`, and
    the conversation objective is closed.
- **Later verification.** `cerebro_cruzar_depositos` sets status on the anchor, and on the group
  siblings when the group saldo is 0. This covers a bank email that arrives after the split.
- **Calculator.** No change. Each operation feeds its own line from its own `quoted_source_amount`
  when it completes (unique `(account_id, operation_id, service)`).
- **Panel.** Group members render together under a "mixed send" header with the deposit total and
  the breakdown. A split editor posts to `/api/remittance-operations/[operationId]/split`.
- **Bot.** A new tool `repartir_envio` wraps the RPC per conversation. The Decisor tells the model
  about a group and stops saying "mando de mas" when the extra money is a declared second service.
  Production n8n changes go to staging first.

## Scope
- In scope: DB (column, saldo, split RPC, cross-check propagation, read model), panel display and
  split editor, the bot tool and Decisor note, staging end to end, production apply.
- Not in scope: splitting ONE operation's money into two services without a second operation;
  changing notification templates; rewriting already-closed operations (3fb87be2 stays as the
  owner left it unless asked).

## Constraints
- Money path: read the LIVE body of every function before redefining it (`pg_get_functiondef`). The
  functions have many historical versions.
- Next migration number is 253. Another Claude session also adds migrations: re-check the number
  before each apply and note any collision in engram.
- Each migration ships a `ROLLBACK-NNN-*.sql` and a self-reverting staging assertion. Apply to
  staging first, production only after it is green.
- Never push `origin`, never merge to master; push to `privado` only when the owner asks.

## TDD
- Mode: strict (source: user global CLAUDE.md).
- Runners: DB behaviour by staging assertions in `supabase/staging/assertions/*.sql`, run with
  `docker run --rm -i --env-file .env.staging postgres:17 sh -c 'psql -X -q "$CRM_STAGING_DATABASE_URL" ...'`.
  An assertion ends in `RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'`. Panel and API by
  `npm test` (vitest).

## Tasks
- [x] S1 — DB core (migration 253): `mixed_group_id`, group-aware `cerebro_saldo_operacion`,
  `crm_repartir_envio`, sibling status in `cerebro_cruzar_depositos`. Assertion replays f8b7779c:
  24,400 split into 18,200 Clasica (70 USD) and 6,200 recarga leaves both ready, with no incident;
  a wrong sum is refused; ungrouped operations behave exactly as before.
- [x] S2 — Read model: `crm_operaciones_de_conversacion` returns `mixed_group_id`; panel types.
- [x] S3 — Panel: group display and the split editor, plus the API route (vitest RED -> GREEN).
- [x] S4 — Bot (S4a 119e710, S4b d74fd5b; on staging): `cerebro_repartir_envio` wrapper keyed by conversation, the n8n tool on staging
  Cerebro, and the Decisor note. Staging run of the f8b7779c conversation.
- [ ] S5 — Production: apply 253+ to production, deploy the panel, n8n tool to production
  (owner confirms first).

## Acceptance criteria
- The f8b7779c sequence ends with a Clasica operation of 18,200 GYD -> 70 USD and a recarga
  operation of 6,200 GYD, both verified, grouped, with no "de mas" incident.
- Every existing staging assertion still passes.
- An operator can split and re-split from the panel; the bot can split by tool.

## Delivery
Forecast is about 900 authored lines (SQL about 450, panel about 350, bot about 100), over the 400
heuristic. The repository has no pull-request flow here (work-unit commits on
`feat/port-chat-operations-calculator`, pushed to `privado` on request), so slices are commits:
S1, S2+S3, S4, S5.

## Progress
- 2026-10-20: designed from two read-only maps (engram #507) and the live production bodies of
  `cerebro_saldo_operacion`, `cerebro_cruzar_depositos`, `crm_corregir_operacion` and
  `cerebro_estado_desde_etapa`.

- 2026-10-20 S1 DONE on STAGING (not production): commits cabcd65 + fix (reuse guard). Migration 253 +
  ROLLBACK-253 + assertion `mixed-send-split-deposit.sql` (cases: f8b7779c replay, refusals, creation of a missing
  operation, re-split through a member, ungrouped saldo unchanged, 42501 for non-members, late cross-check readies the
  siblings and a partial payment does not, an operation with its own deposit/receipt is never reused). RED observed
  (function missing; then case 7 RED before the reuse guard), GREEN after; rollback proven inside a rolled-back
  transaction. Staging md5: cerebro_saldo_operacion 1d55e05a, cerebro_cruzar_depositos 435289d4, crm_repartir_envio
  be970c57. Related assertions (86, with/without 253): no regression; several fail identically on staging with or
  without it (pre-existing). Audit uses action human_correction, field_name mixed_split.
  Open for S4: the bot path must run with a human/admin context or the 096 guard will not lock the shares.

- 2026-10-20 S2 DONE (260b1c2): migration 254 (crm_operaciones_de_conversacion returns mixed_group_id) + ROLLBACK +
  assertion `operaciones-mixed-group-id.sql`, applied on STAGING (md5 720398ef); read-model `mixedGroupId`.
- 2026-10-20 S3 DONE (5957c86): POST /api/remittance-operations/[operationId]/split -> crm_repartir_envio
  (22023->400, 42501->403, 404); command `repartirEnvio`; mixed-send block (header with total + shares); split form
  (rows of service + GYD, live assigned/total, submit only when exact and >=2 rows; "20.000" read as 20000); "Split"
  action on every open editable card. A first writer was stopped by accident mid-task; the second resumed its files.
  RED seen for the block, card-split and container-grouping tests (route/command/helpers/form tests were already
  written by the first writer). Checks: npm test 211 files / 2848 tests pass; tsc --noEmit clean; eslint clean on the
  touched dirs; parent spot check 55 files / 911 tests pass. Not verified: the UI in a browser; Cancel/Escape of the
  form in the card tests.

- 2026-10-20 S4a DONE on STAGING (119e710, migration 255): `cerebro_repartir_envio(p_conv, p_partes text,
  p_execution)` parses "clasica 18200, recarga 6200" (also "18.200 clasica y 6,200 recarga", saldo movil -> saldo),
  finds the anchor (grouped / with deposit / newest with amount), and answers in Spanish (summary with destination
  amounts and group state; refusals with the server reason; "no entendi"; no deposit). Reuses the 230/231 pattern:
  body moved to internal `_repartir_envio_core` (all API roles revoked); `crm_repartir_envio` keeps signature/grants
  and its membership check; the wrapper sets wacrm.origin=admin + wacrm.actor=automation:cerebro_repartir_envio for the
  call only, so shares are locked by the bot and audited as `automation_mixed_split` (added to the audit CHECK). One
  tool_execution_log row per call. RED seen (function missing); GREEN; related 11 SAME. Parent spot check: the 253, 254
  and 255 assertions all ALL PASS on staging. Staging md5: cerebro_repartir_envio 7ca841b8, _repartir_envio_core
  9dd93c98, crm_repartir_envio 5f70660f. Limits: amounts up to 999,999 with separators.
- 2026-10-20 owner authorized testing the panel on staging; run locally (localhost:3100) against staging Supabase,
  fixture conversation "PRUEBA envio mixto" (763c248e: remesa 32faf8f9 24,400 incident / 93 USD, recarga cf76cdee) —
  delete after the test.

- 2026-10-20 BROWSER TEST on staging (local next dev :3100, owner logged in): the owner split the fixture from the
  panel (audit 22:11:07, his user): remesa 24,400/93 USD/incident -> 18,200 GYD -> 70 USD ready; recarga -> 6,200
  ready; grouped; group saldo 0; objective closed; both shares locked. Then the parent drove the form: a sum of
  23,200/24,400 keeps "Repartir" disabled; a re-split 19,200 + 5,200 saved, the panel refreshed, DB 19,200 -> 73 USD,
  5,200, saldo 0. Fixture deleted afterwards (0 rows left). UX note for later: the mixed-send header shows GYD only,
  not the destination amount (70/73 USD).

- 2026-10-20 S4b DONE on STAGING (d74fd5b): staging Cerebro U52y1kSNvhgxvWeb 127 -> 128 nodes, new postgresTool
  `repartir_envio` (clone of cambiar_servicio, credential Supabase STAGING, query
  `SELECT cerebro_repartir_envio($1::uuid, $2::text, $3::text)`, $fromAI 'partes'), ai_tool to Agente Remesas. Decisor:
  in the verificado_de_mas branch, when the customer's recent texts or the *_en_curso flags show a second service
  (reused detectors; a small new one for saldo movil), the "mando de mas" note becomes "the extra is probably for that
  service: confirm the split and call repartir_envio; do not say they sent too much". Otherwise unchanged. 2b (ENVIO
  MIXTO note) skipped: the Decisor gets no mixed_group_id (would need the "Contexto conversacion" SQL). Decisor tests
  RED 4/6 new -> GREEN 20/20 (parent rerun 20/20); md5 pin c8044de0. Post-PUT: only Decisor changed + new node;
  versionId = activeVersionId f1b55fb3 (parent check). Backup: scratchpad staging-cerebro-before-S4b.json (version
  08ae4ef7). Not verified: a real model turn calling the tool.

## Next step
S5 production, after the owner confirms: apply 253, 254, 255 to production (md5 must equal staging), deploy the panel,
then the n8n tool + Decisor on the production Cerebro. Optional before: a real chat turn on staging. bot wrapper keyed by conversation (must run with a human/admin context so the 096 guard locks the shares), n8n
tool on staging Cerebro, Decisor note. Coordinate with the prompt session before editing the staging workflow.
