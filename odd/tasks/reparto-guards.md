# Reparto guards (staging test 2 findings F1, F2, F3)

Objective: a reparto between several cards must never be overwritten by a single beneficiary, the bot
must be steered to the reparto tool while a reparto is open, and a GYD amount given for a reparto
("5 mil a cada una") must be converted, saved and confirmed, or asked about when it is ambiguous.

Problem (staging live test 2, 2026-10-02 03:36-03:40 UTC, test number 529622896918): two cards,
one phone, "5 mil a cada una", "el celular es el mismo para las dos". Final state: ONE vigente
cuban_card (card 1 + phone); card 2 and the amounts lost; a duplicate "Anotado" reply.
- F1 (n8n Decisor, also in production since gate 78): with a reparto saved, later bursts are not
  `multi_beneficiario`, and the accumulated card + phone (Merge beneficiario) triggered the note
  "TARJETA Y CELULAR DETECTADOS PERO NO REGISTRADOS ... Llama gestionar_beneficiario". The model
  obeyed: the single-beneficiary tool.
- F2 (DB, also in production since 179/180): `cerebro_guardar_beneficiario` wrote a new
  single-beneficiary generation over the vigente reparto (newest generation wins).
- F3 (n8n): "5 mil a cada una" was ignored (reparto saved with empty amounts, no question). The prompt
  already says a bare number is GYD and a reparto in GYD is converted with calcular_envio; the service
  deposit minimums were not in the context, so the model could not tell CUP from clasica/tropical.
- F4 (not in scope): a waiting execution answers on a stale context (300760 waited ~195 s).

Owner's deposit minimums (GYD, 2026-10-02): CUP 5,000; Zelle / clasica / tropical 13,000; USD cash
delivery 29,000; recargas 5,200 to 6,200; translations / visa extensions 5,000.

Scope: staging only (DB migration 184 + staging Cerebro U52y1kSNvhgxvWeb). Production port needs the
owner's go-ahead. Constraints: strict TDD; no deals; drift-checked n8n PUT with a rollback snapshot.
TDD: on (user global config, Strict TDD Mode). Runners: SQL self-reverting assertions via
`docker run postgres:17-alpine psql "$CRM_STAGING_DATABASE_URL"`; Decisor cases via node harness.

## Tasks
- [x] T1 F2: `cerebro_guardar_beneficiario` never overwrites a vigente reparto: a card in the reparto
      patches its slot, a lone phone fills the first slot without one, anything else is refused with
      "use registrar_reparto_multiple" (migration 184 + rollback + assertion)
- [x] T2 F1: Decisor: while a reparto is vigente (or the burst is multi), no single-beneficiary note;
      a REPARTO EN CURSO note lists the slots and what is missing and names registrar_reparto_multiple
- [x] T3 F3: deposit minimums in the context (from cerebro_config, recarga range key added) and a
      Decisor note for a GYD amount in a reparto (per card vs total, CUP vs clasica/tropical, ask when
      ambiguous)
- [ ] T3b Final minimum rule (owner, 2026-10-02, NOT yet implemented — the deployed gate 82 is per card):
      * bare amounts are GYD the customer deposits (rule 4), never CUP to receive;
      * VALIDITY uses the minimum PER DEPOSIT (the whole envio): "3 mil a cada una" = 6,000 GYD >= 5,000,
        valid CUP remesa, split as the customer says; below 5,000 in total -> say the minimum;
      * CURRENCY is inferred PER CARD amount: an amount < 13,000 reaches no other service minimum -> CUP
        ("10 mil a la 1a y 5 mil a la 2a" = CUP both); only an amount >= 13,000 is asked (CUP or USD);
      * then convert each card's GYD to CUP with calcular_envio ("5 mil y 5 mil" = 10,000 GYD, about
        15,000 CUP), save per slot, confirm.
      Change in `~/cerebro-fase1/pruebas/gate82-decisor-bloque.js` (the `bajo` test must use the total), update
      `gate82-banco.js` ("3 mil a cada una" -> CUP, "2 mil a cada una" -> below), then
      `python3 gate82-reparto.py actualizar && node gate82-banco.js && python3 gate82-reparto.py desplegar`
- [ ] T4 Deploy T2/T3 to staging Cerebro, replay test 2 on staging with the owner

## Acceptance
- Test 2 replayed: final vigente generation is the reparto with both cards, the phone on both, and
  each amount in CUP; no single cuban_card generation written after the reparto.
- Existing assertions (partial-beneficiary-tools/auto, deal-free-money-rules) still ALL PASS.

## Progress / evidence
- T1 (2026-10-02): migration `184_reparto_guards.sql` (staging only, + rollback). RED before:
  `supabase/staging/assertions/reparto-guards.sql` case 1 reproduced test 2 exactly ("guardado ... Completo."
  and the reparto reduced to one card). GREEN after, in one rolled-back transaction and again after applying:
  reparto-guards, partial-beneficiary-tools, partial-beneficiary-auto, deal-free-money-rules ALL PASS.
  `cerebro_guardar_reparto` keeps its 11-argument call (n8n tool) through DEFAULTs.
- T2 + T3 (2026-10-02, staging Cerebro only): `~/cerebro-fase1/pruebas/gate82-reparto.py` (block in
  `gate82-decisor-bloque.js`). Decisor: a vigente reparto (2-3 slots in `beneficiarios_registrados`) takes
  precedence over the single-beneficiary notes and emits REPARTO EN CURSO (slots, what is missing,
  registrar_reparto_multiple only, "same phone for all" goes to every slot, ask on a foreign card); the
  MINIMOS DE DEPOSITO note (from `ctx.minimos`) when the burst has an amount or says "minimo"; the MONTO EN GYD
  PARA EL REPARTO note: per card ("cada una", or one amount per card) -> below the CUP minimum: say it, do not
  save; below the Clasica/Tropical minimum: only CUP, convert with calcular_envio, save, confirm; otherwise ask
  CUP or USD; one amount without "cada" -> ask total or each. Assumption: the minimums apply per card.
  Contexto: `beneficiarios_registrados` carries posicion/monto/moneda, new column `minimos` (validated on the
  staging test conversation in a rolled-back transaction). Migration `185_recarga_minimum_range.sql`
  (`minimo_gyd_recarga_hasta` = 6200, informative only; + rollback), applied to staging.
  Tests `gate82-banco.js`: bank 193 cases identical base vs candidate, 0 broken; 10 new cases, 8 RED on the
  live Decisor and all 10 GREEN on the candidate. Drift-checked PUT, byte-verified, active version
  8f60434f-cc0e-4556-832a-367fc444f03f; rollback `ROLLBACK-82-staging-20261001-220507.json`.
  Test number 529622896918 reset for the replay (T4).
- T3 correction (2026-10-02, owner): the minimum is per envio (the deposit), not per card; a reparto is one
  envio. The GYD reparto note now compares the TOTAL ("5 mil a cada una" x 2 = 10,000 GYD: only CUP; "3 mil a cada
  una" = 6,000: only CUP; "10 mil y 5 mil" = 15,000: ask CUP or USD; "2 mil a cada una" = 4,000: below the CUP
  minimum). `gate82-reparto.py actualizar` swaps only the gate-82 block. Bank 193 identical; 11 cases GREEN, the 3
  whose rule changed were RED on the per-card version. Active version 8d3288fe-9fa1-4fdf-8296-e028cdc109cf;
  rollback `ROLLBACK-82-staging-20261001-221226.json`. Test number still clean.
- T3 second correction (2026-10-02, owner): the previous "per envio" reading was a misunderstanding ("el minimo es
  para enviar" meant the minimum is in GYD sent). Each card's amount is read on its own against the minimums:
  "10 mil a la primera y 5 mil a la segunda" is CUP for both (5,000 is the CUP minimum, 10,000 reaches no other
  service's minimum); below 5,000 is said to the customer; only an amount >= 13,000 is asked about (CUP or USD),
  per card ("5 mil y 20 mil": card 1 CUP, ask card 2). Bank 193 identical; 12 cases GREEN. Rollback
  `ROLLBACK-82-staging-*` (latest snapshot of this deploy).
