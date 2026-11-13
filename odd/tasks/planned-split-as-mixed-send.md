# Feature: a planned split is a mixed send from the start

## Objective
When the bot plans a split across services before any deposit (repartir_envio -> _cerebro_reparto_planear), the
operations it opens are one mixed send from the start: grouped (mixed_group_id), each part with its own agreed amount,
so the panel shows one send with its parts and total waiting for the deposit, not loose operations with 0 GYD.

## Problem / why (2026-11-13, owner test conv 2ca2cf79; real case d9e9f333 2026-11-12)
- "2 recargas + 50 USD Zelle": repartir_envio "recarga 12400, zelle 13000" -> planeado. Result: op 49d88b9c recarga with
  quoted_source_amount 12400 (set by registrar_numeros_recarga) and op d9dcdddb Zelle with 0 GYD (opened by
  cerebro_guardar_zelle, which sets no amount/destination), no mixed_group_id; cerebro_reparto_planeado holds the plan
  (total 25,400) and groups/applies only when a deposit of exactly the total arrives (277/280). The panel shows two loose
  operations, one with 0 GYD. Owner: "de hecho es un envío mixto y debe salir como tal".

## Owner decisions
- 2026-11-13: a planned split must show as one mixed send (grouped, each part with its amount) before the deposit.

## Scope
In: SQL (migration 369+, ROLLBACK, staging assertions): plan path groups the part operations and sets each part's agreed
amount (not money); deposit application of a plan still works with the group already formed; panel only if it needs a
change to show a grouped send without deposit (check how the panel renders mixed_group_id groups first). Staging; production
with go-ahead.
Out: Decisor; quote parser and debounce rule (separate follow-ups below).

## Constraints
- Read LIVE production bodies first and confirm they match the repo before redefining.
- Strict TDD: SQL assertions in rolled-back transactions (RED then GREEN); vitest for any panel change.
- "Agreed amount" is not money: follow the existing convention (_cerebro_op_monto_acordado / audit 'agreed amount (not money)')
  so deposit checks, objetivo and calculator keep working.
- Existing mixed-send, reparto, repartir and deposit assertions stay green (relacionadas).
- Never touch the other session's files (pruebas/decisor/decisor.jscode, pruebas/decisor/correr.ts,
  pruebas/decisor/decisor-notas.test.ts, odd/tasks/bot-brevedad.md). No AI attribution in commits. RDD off.

## Tasks
- [x] T1 Map: how mixed sends are represented and shown (mixed_group_id = anchor id, panel rendering, crm_repartir_envio,
      _cerebro_repartir_envio_core), how a plan is applied at deposit (cerebro_registrar_deposito, _cerebro_aplicar_plan_reparto),
      and what breaks if the group exists before the deposit
- [x] T2 (option 2) Plan sets each part's agreed amount (_cerebro_fijar_monto_acordado: zelle 13,000, recarga 12,400), no
      mixed_group_id before the deposit; deposit behaviour unchanged; assertions (2 recargas + Zelle shape; planned-split-before-deposit
      updated only for the agreed amounts)
- [x] T3 Panel: read model exposes the conversation's planned split (new read RPC or route field, viewer auth) and groupOperations
      shows the plan's operations as one mixed send with parts and total; vitest RED/GREEN; tsc, eslint
- [ ] T4 Staging: apply, related assertions, owner check in the panel
- [ ] T5 Production (needs go-ahead)

## Follow-ups seen in the same test (not in this feature)
- cerebro_monto_cotizado does not record "Total a depositar: *25,400 GYD*" (no "Cotizado" line).
- Debounce extra wait fires on recarga phones (old rule "celular sin tarjeta").
- The bot capitalized a name ("torres" -> "Torres").

## Acceptance criteria
- After the plan: one mixed send in the panel, recargas 12,400 + Zelle 13,000, total 25,400, no part at 0.
- A deposit of 25,400 completes the plan as today; a different deposit gives the same facts as today.

## Progress / evidence
- T1 (2026-11-13): live prod bodies of the 20 reparto/deposit/recarga/zelle functions read-only = staging (md5 list equal); repo
  latest = 367/293/277/280/291. Findings: (a) the panel groups only by mixedGroupId and totals the members' quoted amounts
  (mixed-groups.ts), so a real group with amounts renders parts + total with no panel change; (b) a virtual group would need a
  panel/read-model change (no panel code reads cerebro_reparto_planeado); (c) `_cerebro_op_monto_acordado` is false for any grouped
  op, so an eagerly grouped part reads as "holding money" to every guard: cerebro_modificar_operacion (cancelar, unir, mover_deposito
  answer en_grupo "forma parte de un reparto con deposito"), crm_registrar_numeros_recarga (last number removed does not cancel),
  _cerebro_aplicar_servicio_base ('aparte' empty-op reuse, cancel_ids skip), _cerebro_fijar_monto_acordado ('en_grupo'),
  cerebro_repartir_envio holder choice (a member qualifies as holder, so a repeated repartir goes to the core and deletes the plan),
  cerebro_registrar_deposito movido guard (member with recipient + saldo>0 is excluded -> phantom 'creado' op) and its
  `quoted_source_amount = p_monto` overwrite of a member. STOPPED here: decision needed (see Next step).


- 2026-11-13 owner chose option 2 ("si"): agreed amounts per part in SQL + virtual mixed group in the panel from the plan; no
  mixed_group_id before the deposit, so no bot behaviour change.
- T2 (2026-11-13): RED `planned-split-agreed-amounts.sql` on the live state: "case 1 amounts: expected [recarga/12400;zelle/13000], got
  [recarga/12400;zelle/0]". GREEN: `DRY_ONLY=1 staging-migracion.sh aplicar 369 ...` dry-run OK (5 cases: shape, no double-set (1 audit row per
  part), replan writes nothing, deposit 25,400 -> one group 12,400/13,000 plan gone saldo objective 25,400, deposit 20,000 -> facts + nothing
  grouped, locked part kept). planned-split-before-deposit.sql updated only for the intended agreed amounts (case 1 expected amounts); dry-run OK.
  Live `_cerebro_reparto_planear` body read from prod 2026-11-13 equals repo 277/288.
- T3 (2026-11-13): migration 370 `crm_reparto_planeado_de_conversacion(uuid)` (viewer auth 42501, authenticated+service_role only, read-only) +
  ROLLBACK + assertion planned-split-panel-read.sql: RED "function crm_reparto_planeado_de_conversacion(uuid) does not exist", GREEN "ALL PASS".
  Panel: route returns `plannedSplit` (never fatal), read-model `mapPlannedSplitRows`, `withPlannedSplit` gives the open, ungrouped, unfunded
  operations of >=2 plan parts one panel-only group id `planned:<conv>` (plan amount shown when an op has none), MixedSendBlock `awaitingDeposit`
  line ("Esperando depósito"/"Waiting for the deposit", es+en). vitest RED (9 failed) -> GREEN (65 files / 1076 tests in the operations,
  read-model and route folders; i18n parity 18 passed); tsc exit 0; eslint clean on the 10 touched files.

## Next step
Paused 2026-11-13 ~08:30 UTC by the owner (laptop off). T2 (cd652a22) and T3 (205b5aa4) committed. The writer was stopped
mid-work right after recording a RED with 9 failures (unknown which step; nothing uncommitted left). On resume: check whether
369 is already applied on staging (cerebro_reparto_planear / _cerebro_reparto_planear body vs 369), rerun the T2/T3 checks
(SQL assertion, vitest, tsc), then T4 (staging aplicar + relacionadas, local staging panel for the owner).
