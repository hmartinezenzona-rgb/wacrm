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
- [x] M1 — Assertion with real-shaped fixtures, RED.
- [x] M2 — Migration 126 (function) GREEN on `wacrm-ensayo` + rollback.
- [x] M3 — Candidate for the two n8n nodes + bench; staging DB + staging Cerebro.
- [x] R1 — Reparto (user, 2026-09-27: "rendirse no es opción"): one deposit shared among several
  beneficiaries, each with its amount.
  - Prototype `~/cerebro-fase1/pruebas/prototipo-reparto-beneficiarios.js`.
  - Rule: pair each account with the amount written after it or before it (or "a cada una").
  - Accept only if the amounts add up EXACTLY to the deposit at the day's rate and there is exactly
    one way to make it add up.
  - Safeguards:
    - accounts within 2 h of the deposit and within 1 h of each other;
    - no reparto when one account alone covers the deposit (amount written with or after it).
  - Real result: 4 deposits, 10/10 beneficiaries correct, 0 wrong, all verified against the team's
    delivery proofs (7c310d8c 4/4, a6e9919f 2/2, dd328ea4 2/2, ac2638c5 2/2).
  - One wrong candidate (dab0ad10, cross-day coincidence) was found and removed by the safeguards.
- [x] R2 — DB `cerebro_aplicar_reparto(op, jsonb)` (re-validates the exact sum, writes the
  beneficiaries, locks `beneficiaries`, audits) + assertion RED→GREEN.
- [x] R3 — Scheduled n8n workflow "Cerebro - Repartos automaticos" (every 2 min, the validated
  prototype code in a Code node) + bench; staging.
- [x] M4 — Production (126 + reparto), verify.
- [x] R4 — Reparto v2: Cuban cards (user, 2026-09-27).
- [x] R5 — Vision readings stored in the DB (migration 128 + Cerebro node) and used by the reparto workflow (v3).
- [ ] M5 — Measure capture over the following days (weekly rate vs 44% baseline).

## Progress
- 2026-09-27: document created.
- 2026-09-27: M1 RED: "function cerebro_resolver_operacion_beneficiario(...) does not exist".
- 2026-09-27: M2 GREEN on `wacrm-ensayo`, 7/7:
  - amount (Jose Carlos 100 / Liudis 215);
  - proximity (Damaris / Daniuska, WhatsApp unicode normalized);
  - reparto stays ambiguous;
  - never over another operation's beneficiary;
  - rule C;
  - no evidence → ambiguous;
  - a single op resolves as before.
  - First draft used a temp table inside a STABLE function; it was replaced by the read-only helper
    `cerebro_mensajes_cliente_normalizados`.
  - Mutation check: without the "points to another beneficiary" guard, case 4 fails.
  - Commit 96f1927.
- 2026-09-27: M3:
  - n8n candidates change only the resolver call in `Registrar zelle auto` ($3 account) and
    `Registrar beneficiario auto` ($2 card).
  - Bench `~/cerebro-fase1/pruebas/banco-resolver-beneficiario.py` is RED on live, GREEN on the
    candidates.
  - Both node queries compile (PREPARE) on `wacrm-ensayo`.
  - End-to-end with the real Zelle node SQL + 125 + 126: 26,000 → Jose Carlos 7863447729,
    56,000 → Liudis 7868613281.
  - Staging: 126 applied, assertion 7/7; staging Cerebro deployed and verified GREEN.
  - Rollback: `ROLLBACK-cerebro-staging-antes-resolver-beneficiario.json`.
- 2026-09-27: R2 — migration 127 `cerebro_aplicar_reparto`.
  - Assertion `supabase/staging/assertions/reparto-auto.sql`: RED, then 8/8 GREEN.
  - The lock write runs with a scoped `wacrm.origin='admin'` and the previous value is restored,
    because 096 lets only humans change locks. The audit keeps the automation actor.
  - Rollback verified. Commit 94f9cce.
- 2026-09-27: R3 — node code `~/cerebro-fase1/pruebas/nodo-repartos-automaticos.js` (Zelle only in v1).
  - Bench `banco-repartos.js` on 81 real deposits: 4/4 verified repartos exact, names included, 0
    proposals elsewhere.
  - The bench caught a wrong name: "Buenas tardes" for Vanesa. Fixed with line-based names and a
    greeting filter.
  - Generator `pruebas/generar-workflow-repartos.py`.
  - Staging: 127 applied (8/8).
  - End-to-end with the real workflow on a seeded staging chat that reproduces 9e338224: 4
    beneficiaries 100/100/50/300, named, locked, complete. The test chat was cancelled afterwards.
  - Staging workflow Yu0uskQhydWgNFEy active.
- 2026-09-27: M4 production.
  - Read-only dry run: 3 candidates, 0 repartos would be applied, so no existing data is touched.
  - 126 + 127 applied; md5 of the 3 functions and the audit CHECK are identical to staging;
    anon/authenticated cannot execute them.
  - Cerebro `jEzlVLCLUaJhVwzs`: the live workflow equalled the snapshot; candidate deployed; bench
    GREEN on live. Rollback `ROLLBACK-cerebro-PRODUCCION-antes-resolver-beneficiario.json`.
  - Reparto workflow `5YseDUEC5IAaiofF` active (every 2 min).
- 2026-09-27: R4 — Cuban-card reparto (node code v2).
  - Each card is paired with its phone (8 digits starting with 5, or +53/0053…), read on the
    card's line or the next 2 lines.
  - Shares may be in CUP or GYD, including "10mil", and are stored in CUP at today's rate.
  - A share with no unit is read both ways, never mixed.
  - A card without its phone means no reparto.
  - Filler words are never used as a holder name.
  - Bench: RED (null on e98e868b; then an invented name "tarjeta mil guyanes"), then GREEN 5/5
    verified repartos, 0 proposals elsewhere.
  - Against 5 card repartos registered in the DB: 1 exact (e98e868b: 30,000 + 15,000 CUP, phones
    53280131 / 54475972). The other 4 abstain, because their cards came in photos (0 in text).
  - Staging end-to-end: 2 cards, 30,000 + 15,000 = 45,000 CUP, phones, locked, complete. The test
    chat was cancelled.
  - Production dry run with v2: 0 repartos.
  - Both scheduled workflows were updated (code verified equal to the file).
  - Rollback: `ROLLBACK-repartos-*-antes-tarjetas.json`.
- 2026-09-27: R5 — vision readings.
  - Migration 128: table `cerebro_lecturas_vision` + `cerebro_guardar_lecturas_vision`.
    - The function never raises and is idempotent per (execution, wamid, image hash).
    - Server-side only.
    - Assertion `vision-lecturas.sql`: RED, then 5/5 GREEN.
    - The rollback keeps the history.
  - Cerebro node 'Guardar lecturas vision' (executeOnce, continue on error), branched off
    'Parsear vision'.
    - Structural bench `banco-nodo-lecturas-vision.py`.
    - The real node query was tested through a temp workflow on staging: 2 readings stored.
    - Deployed to the staging and production Cerebro; bench GREEN on live.
    - The prod function md5 equals staging.
  - Reparto code v3:
    - a card's phone is read after OR before the card, accepted only if a single direction gives
      every card its own phone;
    - [Contacto] cards give the phone and the holder;
    - "5" = 5 mil, only if the exact sum confirms it;
    - an announced "para cada persona" is honoured.
  - The workflow query adds each vision reading as a line written at the photo's time.
  - Bench: RED on 1054d03b (cards as photos), then GREEN 6/6 exact (phones 56678919 / 54054534 /
    55773738, 3 x 30,000 CUP, as registered in the DB), 0 proposals elsewhere.
  - Staging end-to-end with stored vision readings: 3 x 30,000 = 90,000 CUP, phones, locked,
    complete. The test was cancelled.
  - Production dry run: 0 repartos.
  - Both workflows are on v3.
  - Rollbacks: `ROLLBACK-repartos-*-antes-vision.json`, `ROLLBACK-cerebro-*-antes-lecturas-vision.json`.
