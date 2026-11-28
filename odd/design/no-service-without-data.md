# Design: no delivery without validated service, recipient, amount and funding

Status: PROPOSAL, updated 2026-10-26 after an external review by three independent models. Phases 1–3
and phase 4a–4d are implemented in production: 328 + 329 (money guards, verified 3/3), 330 (funding
case + allocation ledger, verified 6/6), 331 (deterministic reconciliation, verified 9/9), 332 (panel
case block + incident resolver, verified 2/2), 333 (resolver case key + Decisor conflict note, verified
1/1), 334 (panel assign/release, verified 3/3), the staging simulator, and panel builds
`jf2ZyAScgzIcC-uhzVcoe` → `mANIrP9JfzAIPobqpyVwn`. Remaining: refunds (owner rule pending) and the
conversational brevity work. The owner accepted the review's main correction: **the money holder is
not an operation**. The earlier title ("no service without data") stays as the business principle; the
engineering rule is the one in this heading.

## 1. Problem

Today a service can be created from two things that are not the customer's choice:

1. **A price quote.** `cerebro_cotizar` names the service and `_cerebro_declarar_implicito` records
   the quoted amount, opening one operation per quoted channel. The bot quotes the four channels to
   compare prices, so a comparison quote becomes a declared send. Yoandrys 2026-10-26: quoting Zelle
   and Clasica at 13:11 left a Clasica operation (286,000 GYD) that the owner cancelled at 13:30.
2. **A declared service applied to data that belongs to another rail.** The card arrived at 13:34
   while Clasica was declared; `cerebro_resolver_para_guardar` opened the card operation typed as
   Clasica. The split wanted `cuban_card`, did not find it, and created a second operation while the
   beneficiary stayed on the orphan.

The same family produced the false "faltan 10,000 GYD" at 13:37 (the parts note summed the holder's
own part, not the group deposit), the delivery of a 1,100 USD Zelle with 800 + 200 USD of
recipients (14:24), and the deposit of fran garcia never being split.

**The structural cause the review identified:** the system mixes three concepts that must stay
separate.

| Concept | What it is | What it must allow |
|---|---|---|
| Quote | A price simulation | No operation, no money reserved |
| Deposit | Real verified money | Existing without knowing the service |
| Delivery order | The obligation to deliver an amount to a destination | Created only with service, recipient, amount and funding |

A deposit must not belong to a delivery operation until it is allocated. Operations consume verified
funding; they never hold money waiting for a service.

## 2. Principles

1. **No delivery without validated service, recipient, amount and funding.** The business phrase
   "ningún servicio sin datos" remains, but the enforceable rule is the four-part one.
2. **The money holder is a funding case, not an operation.** `remittance_operations` only represents
   real sends, with a service and the required recipient data.
3. **A quote never declares, opens or types anything.** It is a price, with no operational effect.
4. **The customer's data or explicit choice assigns the service.** Data first; an explicit word is
   enough for a family but not for an ambiguous rail. The service minimum only **suggests**; it never
   assigns (owner decision 2026-10-26).
5. **A contradiction is a conflict, not an override.** If the card prefix says CUP and the customer
   says Clasica, the system records the conflict, blocks the delivery and asks. It never changes the
   service silently in either direction.
6. **Reconciliation is deterministic and database-owned.** A deposit, a beneficiary or an allocation
   change triggers a SQL reconciliation; the model never decides whether to run it.
7. **Money is conserved.** Verified deposits = active allocations + refunds + unassigned balance,
   enforced in SQL.
8. **Everything is auditable and idempotent.** No row is deleted; movements are released or
   compensated. WhatsApp messages, n8n runs, allocations and notifier events carry idempotency keys.

## 3. Target model

### 3.1 Funding case (the money)

`funding_case` is the expediente of one send: it groups verified deposits and the unassigned balance.

- One **active** case per conversation is the operational rule for phase 1. The data model supports
  several cases per conversation from day one (`case_id` on every row); if two cases are compatible,
  the bot asks instead of merging.
- `case_deposits` links `depositos_mmg` rows to the case. `depositos_mmg` remains the single source of
  truth for a verified deposit; the link does not duplicate it.
- Status: `open`, `allocating`, `closed`, `incident`.

### 3.2 Delivery operation (the send)

`remittance_operations` is created only when there is a service, the recipient data required by that
service, and (or before) an allocation. `service_type` and `delivery_method` are required for a real
operation; there is no "holding operation".

- Status keeps the current values (`collecting_information`, `deposit_verification`,
  `ready_to_transfer`, `incident`, `completed`, `cancelled`).
- A ticket operation belongs to a case (`case_id`) and, when it shares a send, to a mixed group.

### 3.3 Allocation ledger

`funding_allocations` records how much GYD of the case is assigned to each operation:

- `case_id`, `deposit_id`, `operation_id`, `amount_gyd`
- `status`: `proposed`, `committed`, `released`
- `evidence_type`: `data`, `explicit_choice`, `operator`, `minimum_suggestion`
- `idempotency_key` unique, `created_at`, `released_at`

`funding_movements` records releases, refunds, adjustments and operator decisions. Nothing is
deleted; a release is a movement.

### 3.4 Service evidence and conflicts

`service_evidence` records what supports the service: Zelle account, card prefix and bank, phone with
explicit recarga intent, CLABE, explicit word, minimum suggestion. Each row has a source
(`message_id`, image id, tool call), a confidence and a status (`active`, `superseded`, `conflict`).

A conflict is a first-class state: the case and the operation cannot be delivered until it is
resolved by the customer's confirmation or an operator.

### 3.5 Invariants (enforced in SQL)

- For every case: `verified_deposits = active_allocations + refunds + unassigned_balance`.
- No operation reaches `ready_to_transfer` unless its committed allocations cover its
  `quoted_source_amount` and the active recipient amounts equal its destination amount.
- No operation is `completed` with a pending conflict or with a case balance that belongs to it.
- No operation exists without a service and the recipient data its service requires.
- No case closes while the unassigned balance is non-zero without an explicit disposition (assign,
  refund, credit, authorized adjustment).
- One active case per conversation in phase 1.
- Every allocation, deposit link and movement has an idempotency key.

### 3.6 Delivery gates

The 328 gate (Zelle recipients must add up) becomes the general rule:

- Per operation: funding allocated, recipient amounts add up, no conflict, required data present.
- Per case: it may stay open with a remainder that belongs to another send; the remainder is visible
  and cannot be silently dropped.
- Hard block, with a deliberate, audited admin delete/edit as the only exit (owner decision
  2026-10-26).

## 4. Evidence and service assignment

### 4.1 Evidence hierarchy

1. **Explicit choice + compatible data**: create or update the operation.
2. **Unambiguous destination data without contradiction**: prepare the operation; confirm what is
   needed.
3. **Explicit choice with incomplete data**: store the intent; ask for the data.
4. **Only an amount match**: **suggest**, never assign. The bot asks ("veo 5,000 GYD; ¿es para una
   tarjeta CUP?").
5. **Contradictory evidence**: conflict; block and ask.

### 4.2 Service evidence table

| Evidence | Service | Notes |
|---|---|---|
| Zelle account (email or US phone) | `zelle` | The account is the evidence |
| Card prefix `9760` (`976003`/`976004`) | `clasica` | Tarjeta Clásica (FINCIMEX), USD |
| Card prefix `9240` | `tropical` | Tarjeta Tropical (BANDEC), USD prepaid |
| Card prefix `9234` or another 92xx CUP prefix | `cuban_card` | CUP card; the prefix decides, not the word |
| Card prefix `9225`/`9235`/other MLC-backed | none | MLC is human-handled (084): no quote, a colleague confirms |
| Card prefix unknown | none | Ask; never default |
| Card + phone, customer said Clasica/Tropical | the prefix decides | If the number contradicts the word → conflict |
| CLABE + bank | `mexico` | Complete data is enough; no word required |
| Phone + explicit top-up words | `recarga` | A phone alone is never a recarga |
| Address + carnet + explicit cash words | `efectivo_usd` | Explicit intent required |
| Combo / visa / saldo movil | the service | Explicit intent only |
| Exact service minimum, unique | suggestion only | 5,000 GYD suggests CUP; 5,200 GYD is ambiguous (Clasica 20 USD or recarga) |

**Precedence:** data > explicit word > minimum suggestion. A contradiction between data and word is a
conflict, not a precedence win.

## 5. Deterministic reconciliation

Every change to a deposit, a recipient, an allocation, a conflict or a case runs one SQL
reconciliation, idempotent and locked with `SELECT ... FOR UPDATE` (or an advisory lock per case):

1. Load the case: verified deposits, evidence, instructed parts, allocations, conflicts.
2. If a conflict exists → return a blocked result; the bot asks.
3. Build the proposed parts from the evidence and the customer's explicit allocations.
4. Validate each part: service, minimum, recipient data, amount.
5. Validate the sum: parts ≤ available. More → reject the whole proposal; less → the remainder stays
   unassigned.
6. Apply committed allocations FIFO against the case deposits; create the operations already typed;
   reuse an open operation of the same service and recipient when it exists.
7. Set `mixed_group_id` when several operations share the send.
8. Update deposit and case statuses; write movements.
9. Return the result: operations, remainder, pending parts, conflicts.

The agent only interprets messages and calls tools. It never decides whether to reconcile and never
computes the split.

## 6. Worked flows

### 6.1 Deposit, then nothing

Receipt verified → case with balance → bot confirms the deposit and asks where it goes. No operation.
The notifier only confirms the deposit.

### 6.2 Deposit + parts in any order

Deposit 285,000 GYD. Zelle account "800 USD to this one"; second Zelle "200"; card + phone "10,000
GYD to this card, CUP". Each piece of data adds evidence; each amount is the customer's word. When
the parts are complete, reconciliation creates the Zelle and card operations, allocates 275,000 +
10,000 and leaves 0. If the 100 USD account arrives later, it is added to the open Zelle operation
(not a new empty operation); if the sum exceeds the deposit, the proposal is rejected and the bot
asks.

### 6.3 Deposit and one Zelle account

The Zelle account is unambiguous evidence; the operation is created when the amount is known. If the
deposit covers it, it is ready. If the deposit exceeds it, the remainder stays unassigned and the bot
asks.

### 6.4 Card prefix contradicts the word

Card `9234…`, customer says Clasica. Evidence: prefix + bank = CUP. Conflict state; the bot says the
card is CUP and asks; no transfer until confirmed. If the customer confirms CUP, the conflict closes
with the customer's word; if not, an operator reviews.

### 6.5 Minimum suggestion

Deposit 5,000 GYD, no other evidence. The bot suggests CUP ("el mínimo de CUP son 5,000 GYD") and
waits. It does not create the operation. 5,200 GYD is ambiguous and only produces a question.

## 7. Panel UX (case-centric)

- The case shows **verified**, **assigned**, **available** and the deposits that back it.
- Actions: assign service, split, refund/cancel, view evidence, resolve conflict.
- Evidence panel with badges: "cuenta Zelle detectada", "tarjeta 9240 → Tropical", "cliente dijo
  Clásica → conflicto".
- Assignment modal validates minimum, sum and conflicts; an override requires a reason.
- "Complete delivery" is disabled with the reason visible ("falta asignar 100 USD entre
  beneficiarios").
- Audit timeline: evidence, allocations, releases, operator, source message. Nothing is deleted.

## 8. Migration and compatibility

- Keep `depositos_mmg` as the source of truth; link it to the case. Do not duplicate it.
- Existing open operations keep working; new deposits create cases. No backfill of completed
  history (owner decision 2026-10-26).
- The already-applied fixes remain useful but operate on operations: 325 (split fact), 326 (unfunded
  part guard), 327 (group deposit and comparison quotes), 328 (Zelle delivery gate). The case model
  needs equivalents anchored on the case.
- `_repartir_envio_core` anchors on an operation today. A case-based split needs a new function (or
  an adapter) that receives `case_id` and parts and creates/links operations.
- `cerebro_resolver_servicio` must expose the case state; the Decisor and the notifier must stop
  treating an operation as the money.
- The panel and the notifier are operation-centric; the case view and messages are a real UI/API
  change.

## 9. Testing and rollout

| Layer | What it validates | Tool |
|---|---|---|
| Message interpretation | Intent, amounts, recipients, conflicts | promptfoo with tool-call assertions |
| Decisor | Context and rule selection | vitest harness |
| Reconciliation engine | Splits, balances, transitions | deterministic SQL tests |
| PostgreSQL | Atomicity, constraints, concurrency, idempotency | SQL/pgTAP with fixtures |
| Integration | Full flow without real external effects | webhook simulator; never the shared WhatsApp token |
| Panel | Actions, permissions, blocks, audit | UI tests |
| Production | No regressions, no financial anomalies | monitoring and reconciliation |

- **Staging contradiction:** the staging Cerebro shares the production WhatsApp token and must not be
  executed. A manual staging conversation is not safe. Build a webhook simulator (post the same
  payloads to n8n with mocked tools and notify disabled) or a dedicated test number/credential before
  the end-to-end test.
- **Rollback is not enough:** a schema rollback does not undo allocations, refunds or messages. Add
  backups, post-deploy reconciliation and a reversible data plan, not only migration rollbacks.
- **Property tests:** generate deposits, parts, cancellations and refunds randomly and assert
  conservation (never lose or duplicate GYD).
- **Metrics:** phantom operations per quote (target 0), double-counted deposits (0), deliveries with
  incomplete recipient amounts (0), allocations above verified deposits (0), manual split
  corrections, repetitive messages. Keep the 502-turn/69-conversation baseline.

## 10. Phases

1. **Money guards:** centralize the delivery gates, deduplication and balance checks in SQL. Every
   financial mutation goes through authorized functions. **Applied in production 2026-10-26**
   (migrations 328 + 329): verified funding, group-aware balance and recipient sums on every rail.
2. **Case + allocations:** introduce `funding_case`, `case_deposits`, `funding_allocations` and
   `funding_movements`, compatible with the existing operations. **Applied in production 2026-10-26**
   (migration 330): the four tables, `remittance_operations.case_id` and six service_role functions;
   no bot or panel wiring yet.
3. **Deterministic reconciliation:** run the engine on every relevant change; remove the model's
   responsibility to call the split. **Applied in production 2026-10-26** (migration 331): verified
   deposits enter the case, allocations follow operation data, confirmed prefix conflicts set the case
   incident and block delivery. Allocations are append-only in this increment; bot wording and the
   panel are phase 4.
4. **Panel, simulator, tests and brevity:** the case UX, the webhook simulator, the test matrix, and
   only then the conversational brevity work. **Applied**: the panel case block and incident resolver
   (332), the bot conflict note (333), the no-send staging simulator and the assign/release actions
   (334, panel build `mANIrP9JfzAIPobqpyVwn`). Remaining: refunds (owner rule pending) and brevity.

## 11. Decisions (2026-10-26)

- The money holder is a case, not an operation (review, accepted).
- Service/currency empty until the data or the customer decides; no quote declares.
- A deposit never types a service from the amount or the words, except that an exact **unique**
  minimum may **suggest** and the bot asks (owner accepted 2026-10-26; no automatic assignment).
- One active case per conversation in phase 1; multiple cases supported by the model.
- Data > word > minimum suggestion; a contradiction is a conflict, never a silent override.
- Deterministic reconciliation in SQL; the model does not decide it.
- Hard delivery gate with an audited admin delete/edit.
- MLC is a human handoff (084).
- The panel gets assign/cancel on day one; complete UX follows.
- No feature flag: deployments use migration rollbacks plus a data rollback plan.
- Legacy cases (`f9b6ec33`, `e4c2a15b`, Suri) stay as history.

## 12. Open questions

- **Staging:** build the webhook simulator vs a dedicated WhatsApp test number. The simulator is
  cheaper; the test number is more faithful. This decides O14.
- **Prefix table:** confirm the list with Osmany; where it lives (config with a code-managed seed) and
  who updates it (the team).
- **Case per conversation:** keep one active case per conversation in phase 1, or allow several from
  the start?
- **Order of implementation:** phase 1 (money guards) first, or the case + allocation schema first.

## 13. Non-goals

- Rebuilding the 131 nodes or changing the 21 tools at once.
- Backfilling historical operations.
- Teaching the model to compute splits or balances.
- Making the bot ask about every field; the deposit confirmation stays immediate.
