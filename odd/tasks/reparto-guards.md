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
- [ ] T2 F1: Decisor: while a reparto is vigente (or the burst is multi), no single-beneficiary note;
      a REPARTO EN CURSO note lists the slots and what is missing and names registrar_reparto_multiple
- [ ] T3 F3: deposit minimums in the context (from cerebro_config, recarga range key added) and a
      Decisor note for a GYD amount in a reparto (per card vs total, CUP vs clasica/tropical, ask when
      ambiguous)
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
