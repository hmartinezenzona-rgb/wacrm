# Design: one beneficiary draft per remesa (replace the three capture paths)

Status: PROPOSAL, not implemented. Written 2026-10-01 after the Yeny case (op 99a4065d).
Owner decisions recorded in section 3. Nothing here is deployed.

## 1. Problem

Beneficiary data (cards, phones, Zelle accounts, amounts per person) reaches an operation through
three independent paths, and each one re-reads the chat its own way:

| Path | What it does | Where it fails |
|---|---|---|
| Deterministic nodes (`Registrar beneficiario auto`, `Registrar zelle auto`, `Merge beneficiario`) | Register the FIRST card + FIRST phone of a burst, or a complete Zelle | Partial data (a card without a phone, a phone alone, a correction) is dropped. `cerebro_beneficiario_parcial` keeps ONE card/phone per conversation, so it cannot hold a reparto |
| LLM tools (`gestionar_beneficiario`, `registrar_reparto_multiple`, `registrar_beneficiario_zelle`, `marcar_destino_usd`) | The model writes what it understood | The model almost never calls them (section 2) |
| Cron detector (`Cerebro - Repartos automaticos`, every 2 min) | Regex over customer text + vision reads to find repartos | Breaks on wording ("cada una", "guyane", amount 3 messages later, phone confirmed with "sí" to the bot's question). Each fix is a new patch |

None of them keeps what has arrived so far, and none of them knows what the others understood.
What the bot clarifies by asking (the most valuable information) is written by nobody.

Yeny, 2026-09-28: two card photos (one with phone, one without), "5 mil guyane cada una",
bot asked "¿El celular 53960583 es para las dos tarjetas?", customer "Sii". Result: one card with
30,000 CUP. The bot understood everything; an admin paused the bot right after the question; the
detector returned null on the real messages (replayed locally); the node had registered card 1 only.

## 2. Evidence: why the bot does not write what it understands

Measured on production, last 14 days (2026-09-17 .. 2026-10-01):

- 863 turns reached the model; 29 (3.4%) made more than one model call, i.e. any tool call at all.
- Tool calls by the model: `registrar_reparto_multiple` 3, `registrar_beneficiario_zelle` 30,
  `marcar_destino_usd` 2, `gestionar_beneficiario` 1. Deterministic twins: `Registrar zelle auto` 200,
  `Registrar beneficiario auto` 52.
- The bot said "Anotado" / "queda registrado / anotado / así" 114 times; 32 of them (28%) had NO write
  of any kind in the 3 minutes before or 1 minute after. Examples: Katalella 2026-10-01 14:33
  ("Anotado. La cuenta Zelle queda así: Rodolfo valiente ..."), a name correction "No es Roberto es
  Oberto" -> "Anotado, es Oberto" (never written), "Anotado el celular 59499176" (no card yet, nowhere
  to store it).
- The DSML failure (the model writes the tool call as text) is now rare: 1 rescue notice in memory.

Why it happens (the causes are in the design, not in one bad prompt line):

1. The prompt and the Decisor teach the model NOT to call tools. Repeated rules: "NO hay ninguna tool
   que llamar, solo confirmalo con palabras", "Si el [CONTEXTO] dice 'Beneficiario YA REGISTRADO', NO
   la llames", "Usala UNICAMENTE para lo que el sistema no cubre". The model cannot tell what the system
   covered this turn, so it learned that confirming in words is the normal case.
2. Tools are all-or-nothing. `registrar_reparto_multiple` needs 9 arguments "con TODO completo y
   emparejado". There is no tool for a partial fact (one phone, one correction, "the same phone for
   both"), so partial facts have nowhere to go.
3. Tool calling is optional (`tool_choice=auto`) on `deepseek-flash` without reasoning, with a 43.6k-char
   system prompt and 13 tools. Optional + discouraged = rarely called.
4. Nothing checks the promise. A reply that says "Anotado" is sent whether or not anything was written.

How to check it at any time (no new tooling needed):
- `cerebro_telemetria_turno.model_calls > 1` = the turn called at least one tool.
- `tool_execution_log` = every write tool and every deterministic twin (read tools are not logged).
- Promise-without-write rate: bot messages matching `(anotado|queda (registrad|anotad|as[ií]))` with no
  `tool_execution_log` row for the conversation in [-3 min, +1 min]. Query kept in section 9.

## 3. Owner decisions (2026-10-01)

- D1. Pairing by arrival order: a card without a phone takes the next phone that arrives; a phone
  without a card attaches to the next card without a phone. Same for Zelle holder/account.
- D2. When in doubt, ASK. One phone and several cards (no other phone arrived): the bot asks
  "¿el celular X es para todas?"; only the customer's "sí" completes it (option B). Never auto-fill.
- D3. After the answer, the bot fixes what it already did, creates what is missing and replaces what
  changed. Ambiguity in pairing or amounts always becomes a question, never a guess.

## 4. Design

### 4.1 One store: the draft

New table `beneficiary_draft_facts` (append-only ledger), keyed by `operation_id` (not `deal_id`: the
eliminate-deals work removes deals) and `conversation_id`:

```
id, operation_id, conversation_id, created_at,
kind        -- card | cu_phone | zelle_account | zelle_holder | usd_rail | amount | split_rule
             -- | pairing | correction | confirmation | retraction
value       -- normalized value (16-digit card, 8-digit phone, 10-digit US phone or email, ...)
target      -- optional: which slot it applies to (slot id, "all", ordinal)
source      -- text | vision | bot_extract | admin | deterministic_node
source_ref  -- message wamid / execution id
confidence  -- read | confirmed (customer said yes) | admin
superseded_by
```

And a derived view/function `beneficiary_draft(operation_id)` that folds the ledger into slots:

```
slots: [{ slot, type (cuban_card|zelle|clasica|tropical|cash), card, phone, holder, account,
          amount, currency, amount_origin (stated|split_equal|remainder|whole_deposit), complete }]
pending: [{ code, slot, question_key, proposal }]   -- what is missing or ambiguous
status:  collecting | needs_answer | complete | conflict
```

Facts are never edited: a correction is a new fact that supersedes the old one, so the history of
what the customer said is kept and replayable.

### 4.2 Writers: everything lands in the draft, always

- Snapshot/vision: every card, phone, Zelle account/holder read from text or photos becomes a fact,
  before routing, so it is written even when the bot is paused or an admin owns the chat (same rule
  that already makes deposits register while the bot is silent).
- The model: see 4.4. It writes facts, not finished beneficiaries.
- The panel: an admin edit is a fact with `source=admin, confidence=admin`.
- The three current paths keep running in shadow mode during migration (section 6) and are removed at
  the end.

### 4.3 The assembler (deterministic, one place)

`beneficiary_draft(op)` applies, in order:

1. Destinations in arrival order of their identifying fact (card / Zelle account).
2. D1 pairing: each card without a phone takes the next unpaired phone that arrived after it; a phone
   that arrived before any card waits for the next card without a phone. A phone read on the card's
   own photo belongs to that card.
3. Explicit pairing facts (`pairing`: "phone X for all", "phone X for card 2") override D1.
4. Amounts: stated per slot; `split_rule=equal` ("cada una") divides the deposit or quote; when all but
   one slot have amounts, the last gets the remainder; one slot gets the whole deposit. USD rails use
   the existing largest-remainder rule (migration 174) and whole dollars.
5. Validation: every card has a phone; amounts add up to the deposit (or the quote before the deposit)
   within the rounding rules; no two slots share a card/account.
6. Anything that does not resolve becomes a `pending` entry instead of a guess (D2/D3): one phone for
   several cards -> `confirm_shared_phone(proposal=X)`; amounts that do not add up -> `confirm_split`;
   two readings possible -> `choose`.

### 4.4 The model's contract: mandatory structured output, not optional tools

Every model turn returns, besides the reply text, a JSON block (structured output parser, required):

```json
{ "facts": [ { "kind": "pairing", "value": "53960583", "target": "all", "evidence": "Sii" } ],
  "answers": [ { "pending": "confirm_shared_phone", "answer": "yes" } ],
  "reply": "..." }
```

- It is not a tool the model may skip: the node always reads it. Empty `facts` is a valid answer.
- The model only reports what the customer said or confirmed, with the customer's words as evidence;
  the assembler decides what it means for the draft.
- The prompt section about registering shrinks to: "report the facts you heard; ask about the first
  `pending` item". The rules that forbid calling tools go away with the tools.
- Guard: a reply that claims "anotado/registrado" while the draft did not change and has pending items
  is blocked and regenerated (fixes cause 4).
- `answers` close the pending question the bot itself asked (the question is generated from the
  draft's `pending`, so "sí" has an unambiguous target). This is exactly Yeny's "Sii".

### 4.5 Projection to the operation

When `status = complete`, the draft is projected into `remittance_beneficiaries` (vigente rows,
`source='draft'`) and `quoted_destination_amount`. Projection is idempotent and re-runs on every new
fact; a later correction re-projects (old rows -> reemplazado), so D3 ("fix what it already did") is a
re-projection, not a special case. `admin_locked_fields ? 'beneficiaries'` still wins.

### 4.6 Panel

The operation view shows the draft: slots, what is missing, the pending question, and the facts with
their source message. The admin can confirm a proposal with one click (writes a fact). Completing an
operation whose draft is not complete asks the admin to confirm the slots first, so a delivery can
no longer happen with the system holding one card out of two.

## 5. Replays that must pass before any switch (real cases)

| Case | Input | Expected draft |
|---|---|---|
| Yeny 99a4065d | 2 card photos (one with phone), "5 mil guyane cada una", bot asks shared phone, "Sii" | 2 x 15,000 CUP, phone 53960583 on both, complete only after "Sii" |
| Yeny without the "Sii" | same, no answer | needs_answer: confirm_shared_phone(53960583); nothing projected as complete |
| Kenia 10f159be | Zelle + 2 Clasica cards in USD | 100 USD Zelle + 30/20 USD Clasica |
| Yosvany a29ef5e8 | 15 mil GYD to MN card + 50 mil to Clasica | 45,000 CUP + 192 USD Clasica |
| Katalella | "rvalienter@outlook.com" / "Rodolfo valiente" | Zelle holder + email, complete |
| Name correction | "No es Roberto es oberto" | holder superseded, re-projected |
| Phone first, card later | "+53 5 9499176" then card photo | phone paired to that card (D1) |
| Two phones, two cards, order swapped | card A, card B, phone 1, phone 2 | A-1, B-2 by arrival; any explicit "la segunda ..." overrides |
| Repeated receipt / reparto | same data sent twice | no duplicate slots |

Plus the current regression banks: `banco-repartos.js` (81 deposits) and the bot evals in
`cerebro-fase1/pruebas` must not regress.

## 6. Migration plan (each step shippable and reversible)

1. Ledger + assembler + replay harness (SQL only, no writer yet). Replays of section 5 green.
2. Shadow writers: snapshot/vision and the model's structured block write facts; nothing projects.
   Compare the shadow draft with what the three current paths registered, daily, for one week.
3. Model contract: structured output on, promise guard on, prompt section replaced. Tools for
   beneficiaries stay as fallback but are no longer recommended in the prompt.
4. Projection on: the draft becomes the source of `remittance_beneficiaries`; the cron detector and
   `cerebro_beneficiario_parcial` stop writing (kept readable).
5. Panel view + one-click confirmation; completion checks the draft.
6. Remove the cron detector, the beneficiary tools and the deterministic twins once step 4 has run
   clean for an agreed period.

Coordination: the eliminate-deals session must know that the draft is keyed by operation, and that
`Registrar beneficiario auto` / `Registrar zelle auto` / `registrar_reparto_multiple` are retired by
step 6 (no need to port them to deal-free versions beyond what step 2 needs).

## 7. Risks

- The model reports a wrong fact: facts carry the customer's words as evidence and the assembler only
  turns ambiguous facts into questions; nothing financial is inferred from the model alone.
- Structured output support on `deepseek-flash`: must be verified in step 3 on staging; if unreliable,
  a second, cheap extraction call over the last customer messages produces the same block.
- Two writers racing on one operation: the ledger is append-only and the assembler is a pure function
  of it, so order is by `created_at`, not by who wrote last.

## 8. Open questions for the owner

- Q1. When an admin pauses the bot in the middle of a pending question (Yeny), should the panel show
  the pending question to the admin, or should the bot still be allowed to ask it? (Proposal: show it
  to the admin; the bot stays silent while paused.)
- Q2. Cash delivery (efectivo_usd) and recargas: same draft, or out of scope for the first version?

## 9. Monitoring query (promise without write)

```sql
SELECT count(*) FILTER (WHERE NOT EXISTS (
         SELECT 1 FROM tool_execution_log l
          WHERE l.conversation_id = m.conversation_id
            AND l.created_at BETWEEN m.created_at - interval '3 minutes' AND m.created_at + interval '1 minute'))
       AS promised_without_write,
       count(*) AS promised
  FROM messages m
 WHERE m.sender_type = 'agent' AND m.ai_generated
   AND m.created_at > now() - interval '14 days'
   AND m.content_text ~* '(anotado|queda (registrad|anotad|as[ií]))';
```

After step 4 the same query runs against draft facts instead of `tool_execution_log`; the target is 0.
