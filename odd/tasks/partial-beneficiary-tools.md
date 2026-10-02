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
- [x] T3 Tools rewired to the functions; prompt/descriptions say partial data is accepted; bot test
- [x] T4 Deterministic nodes (`Registrar beneficiario auto`, `Registrar zelle auto`) use the functions (180)
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

- T3 (gate 79, `~/cerebro-fase1/pruebas/gate79-candidato.py`, deployed 2026-10-01): `gestionar_beneficiario`,
  `registrar_beneficiario_zelle`, `registrar_reparto_multiple` now run `SELECT deal_id AS id, accion FROM
  cerebro_guardar_*(...)`; every $fromAI argument says "(cadena vacia si todavia no lo tienes)"; manual
  descriptions say partial data is accepted; prompt REGLA DE ORO + tool lines + reparto section say "call
  with each new datum, ask what the tool says is missing"; Decisor reparto and Zelle notes the same.
  Checks before deploy: Decisor bank 193 cases, 0 broken (7 wording diffs), 5 gate-78 cases OK; real replay
  27/30 (the 3 "misses" are yoel_primo: the bot now SAVES the account and asks the holder's name, the
  check wanted the name from an earlier turn); clean scenarios 23/24 (reparto_explicito rep 3 saved cards and
  amounts and asked the phones); reparto saved from the FIRST turn in 6/6 (yeny + reparto_explicito);
  2 "Anotado" wording slips before the customer confirmed (no wrong data).
  Deploy: drift-checked REST PUT, exactly 5 nodes changed, connections identical, active version
  41253c6e-23c0-49cf-9c0b-c0c9e048b63b. Rollback: `~/cerebro-fase1/pruebas/ROLLBACK-79-cerebro-20261001-195029.json`.
- Next: T4 (deterministic nodes through the same functions: a card photo without a phone is saved at once,
  the phone that arrives later completes it, even with the bot paused); a deterministic guard against
  "Anotado" without a write; watch the first real cases (T5).
- T4 (migration 180 + gate 80, deployed 2026-10-01): `cerebro_guardar_beneficiario_auto` /
  `cerebro_guardar_zelle_auto`. With an open remesa (resolved by card/account with
  cerebro_resolver_operacion_beneficiario, as the nodes always did) the data of THIS burst is saved at once,
  partial, D1 (a new card never inherits the old phone: the Merge memory used to pair them). Without an open
  remesa only the complete pair opens one (a lone Cuban phone, e.g. a recarga, never opens a remesa). Several
  undecidable remesas: derive, as before. The memory is cleared when the cuban beneficiary is complete.
  guardar_beneficiario / guardar_zelle / resolver_para_guardar take optional (op, origin tool name);
  the bot tools call them unchanged. RED (functions absent) -> GREEN: cases 1-8 of
  `supabase/staging/assertions/partial-beneficiary-auto.sql` + 179 regressions; the tool log keeps the
  origin ('Registrar beneficiario auto' / 'Registrar zelle auto').
  n8n (`~/cerebro-fase1/pruebas/gate80-nodos-auto.py`): `Beneficiario completo?` fires on a card OR a
  phone in the burst; `Zelle completo?` on a holder OR an account; both registrars call the auto functions.
  Exactly 4 nodes changed, connections identical, active version a91aa13f-be25-4029-bcee-f4a4b2eacaa5.
  Rollback: `ROLLBACK-80-cerebro-20261001-200021.json` (n8n) then `ROLLBACK-180-...sql`.
