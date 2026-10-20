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
- [ ] S2 — Read model: `crm_operaciones_de_conversacion` returns `mixed_group_id`; panel types.
- [ ] S3 — Panel: group display and the split editor, plus the API route (vitest RED -> GREEN).
- [ ] S4 — Bot: `cerebro_repartir_envio` wrapper keyed by conversation, the n8n tool on staging
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

## Next step
S2+S3: read model returns mixed_group_id; panel group display and split editor with its API route.
