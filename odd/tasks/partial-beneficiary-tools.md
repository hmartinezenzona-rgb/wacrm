# Partial beneficiary tools (fix 3)

Objective: the bot's tools (and the deterministic registration nodes) save beneficiary data as it
arrives, partial and in any order, instead of all-or-nothing. Owner request 2026-10-01: "las
herramientas deben ser capaces de registrar datos a medias y en el orden que lleguen". Follows fixes
1 + 2 (`odd/tasks/tool-reliability-test.md`, Cerebro version a2b2851d).

Problem: `gestionar_beneficiario` needs card AND phone, `registrar_beneficiario_zelle` needs name AND
account, `registrar_reparto_multiple` needs card + phone + amount for every person; every call appends a
block to `deals.notes` that REPLACES the previous one; `cerebro_parsear_beneficiarios` drops a phone
without a card, a Zelle without an account and any reparto line with a gap. Data given in pieces is
lost (Yeny 99a4065d: two cards, the phone for the second one confirmed later, nothing saved).

Owner rules (2026-10-01):
- D1 arrival order: a card without a phone takes the next phone that arrives; a phone without a card
  attaches to the next card without a phone.
- D2/D3 when in doubt the bot asks; the answer fixes what was saved and creates what is missing.

Design:
- One SQL function per kind, the single place for the merge rules, used by the tools (and later the
  deterministic nodes): `cerebro_guardar_beneficiario`, `cerebro_guardar_zelle`,
  `cerebro_guardar_reparto`. Semantics: PATCH, not replace. Given fields overwrite, empty fields keep
  what is saved. A different card starts without a phone (never inherits the old card's phone); a
  different Zelle account starts without a name. Reparto slots by position. Each call answers what is
  saved and what is missing.
- Storage stays the current one (a new block in `deals.notes` holding the merged state, parsed into
  `remittance_beneficiaries`), so the panel, triggers and the calculator keep working; missing fields
  are stored as "-" and parsed as NULL.
- The parser accepts partial blocks; complete blocks parse exactly as before (checked on every
  production note).

Coordination: the eliminate-deals session (deal-free writers 160/162/163) will port these functions'
storage; the merge rules stay in the functions. Migration number: 179 (free on 2026-10-01).

TDD: on (strict, global instructions). Runner: self-reverting SQL assertions executed on production
(`DO` block ending in `RAISE EXCEPTION 'ALL PASS'`), RED before each migration, GREEN after. Bot
behaviour: gate harness (`~/cerebro-fase1/pruebas/gate7x`).

## Tasks
- [x] T1 Parser accepts partial blocks; complete blocks unchanged on all production notes (179)
- [x] T2 Merge functions with D1 semantics + assertions (179)
- [ ] T3 Tools rewired to the functions; prompt/descriptions say partial data is accepted; bot test
- [ ] T4 Deterministic nodes (`Registrar beneficiario auto`, `Registrar zelle auto`) use the functions
- [ ] T5 Deploy, watch the first real cases

## Progress / evidence
- 179 applied to production 2026-10-01. RED before (P1: phone-only block gave 0 rows), GREEN after: all 4
  parser cases and cases 1-9 of `supabase/staging/assertions/partial-beneficiary-tools.sql` (card then
  phone, phone then card, different card resets the phone, name fix, invalid numbers refused, Zelle in
  parts + account change resets the holder, Yeny's reparto in three calls, one-amount change, new card in
  a slot, USD rail kept, bare USD refused).
- Parser on every production note (444 deals): the 341 rows of the old parser identical; one extra row from
  an old block with a US number as "Celular" -> phone-only rows now require a Cuban mobile; re-run gives 0
  differences on complete blocks.
- Installed prosrc md5 = file for all 6 plpgsql functions (parser c2babec4, guardar_beneficiario 0874fa3b,
  guardar_zelle dcc45293, guardar_reparto dd9a83ca, resolver_para_guardar c85dae88, escribir_bloque d779251e).
- Nothing calls the new functions yet (T3 rewires the tools).
