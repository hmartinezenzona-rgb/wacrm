# Cerebro: assign each beneficiary to its deposit when a chat has several open operations

## Objective
Stop losing beneficiaries when a customer has more than one open remesa. Read the conversation to
decide which operation a beneficiary belongs to. Assign only when the evidence is unambiguous;
otherwise assign nothing, as today.

## Why (user, 2026-09-27)
- Capture fell from 76% to 44%. In 78% of the missed remesas the chat had another open operation at
  the same time.
- `Registrar zelle auto` / `Registrar beneficiario auto` then answer "NO SE REGISTRO NADA. Hay
  varios envios abiertos". Proven on execution 248563: vision had read a complete Zelle from a
  photo, and it was refused anyway.
- The user asked to pair each beneficiary with its deposit by reading what the customer sends, and
  to keep that way of working if it proves right.
- The user approved rule C as the fallback.

## Evidence the approach is right (step 1)
- Prototype `~/cerebro-fase1/pruebas/prototipo-emparejador-beneficiarios.js`, run on 23 real groups
  of simultaneous deposits since August.
- Result: 11 correct, 0 wrong, 11 undecided.
  - 7 checked against DB beneficiaries.
  - 4 checked against the team's delivery proofs (Jose Carlos $100, Liudis $215, Daniuska $50,
    Yadamy $65).

## Design
New function `cerebro_resolver_operacion_beneficiario(conversation, states, account)`. It behaves
exactly like `cerebro_resolver_operacion` when there are 0 or 1 open operations. With several:
1. Reparto guard: recent customer text speaks of several people, "a cada", Mexico, … → ambiguous.
2. Candidates: open remesa operations that have no beneficiary yet, or whose beneficiary is this
   same account. A beneficiary is never moved over another operation's different beneficiary.
3. Anchor: the customer message that contains the account. For a photo, the latest customer image.
4. Amount: a number written near the anchor (3 messages / 3 min) with "usd/zelle/dólar/$/cup", or
   alone, that equals floor(GYD/usd rate) or round(GYD×cup rate) of exactly one candidate.
5. Proximity: exactly one candidate created within 5 minutes of the anchor.
6. Rule C: the newest open operation, if it is a candidate and every other open operation has a
   beneficiary or is older than 24 h.
7. Otherwise ambiguous.

Only the two deterministic nodes call it: `Registrar zelle auto` and `Registrar beneficiario auto`.
The LLM tools and `marcar_destino_usd` keep the old resolver.

## Out of scope (queued)
- "Single account for every deposit": its trigger is the deposit, not the beneficiary.
- Storing vision readings in the DB, so photo cases can be measured.
- Extractor Zelle name formats.

## Constraints
- Zero wrong assignments on the real cases; any widening needs its safeguard.
- TDD: Strict TDD enabled. SQL runner: the assertion file (RED before, GREEN after). n8n: a bench on
  the node SQL.
- Path: `wacrm-ensayo` → staging (DB + staging Cerebro `U52y1kSNvhgxvWeb`) → production.

## Tasks
- [ ] M1 — Assertion with real-shaped fixtures, RED.
- [ ] M2 — Migration 126 (function) GREEN on `wacrm-ensayo` + rollback.
- [ ] M3 — Candidate for the two n8n nodes + bench; staging DB + staging Cerebro.
- [ ] M4 — Production (DB + Cerebro), verify, measure capture over the following days.

## Progress
- 2026-09-27: document created.
