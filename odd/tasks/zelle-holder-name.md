# Zelle holder name: the written name, clean, and tied to its account

## Objective
The Zelle beneficiary's name must be the real holder's name, clean, and belong to the registered
account.

## Problem / why
None of the 222 stored Zelle beneficiaries lacks a name, but some names are wrong. Real cases
(prod, Aug–Sep 2026):
- **The contact label wins over the name the customer wrote:**
  - "[Contacto] Nelson" then "Nelson Tejo Perez": stored "Nelson" (aea25fc0).
  - "[Contacto] Mi Hermana 12393918180" then "+12393918180 yadamy truyenque dominguez": stored
    "Mi Hermana" (505e468e).
  - "[Contacto] Liliana 16025563888" plus "Liliana Gonzales Velazquez" in the same burst: stored
    "Liliana" (b0e9ee19).
- **Contact labels carry noise:** "MF Farm Solutions ZELLE" (5e08b7c0) and "Tata💙🇺🇸" (b0f3237c).
- **A name paired with another person's account:** "[Contacto] Tata 12392695584" was followed by a
  second account, +1 832 386 9000, which belongs to Lisandra Castillo Sanchez. The stored pair was
  Tata + 8323869000 (b0f3237c).

How the name is decided today:
- `Snapshot final` reads one burst.
- `Merge beneficiario` accumulates across bursts with COALESCE(new, old) in
  `cerebro_beneficiario_parcial`.
- `Registrar zelle auto` writes the deal notes. A different name replaces the previous one
  ("ACTUALIZADO - reemplaza al anterior").

## Rules (approved by the user on 2026-09-28: "sí, aplica esas tres reglas")
1. **The written name wins.** A full name written by the customer replaces a contact label when:
   - it contains that label ("Nelson" → "Nelson Tejo Perez"); or
   - it is written next to the same number ("+12393918180 yadamy truyenque dominguez").
2. **A clean name.** Emojis, flags and the word "Zelle" are removed from contact labels.
3. **The same number.** A name taken with a number (contact card, name + number) belongs to that
   number. If the account changes and no new name comes with it, the old name is dropped and never
   paired with the new account. The bot then asks for the name.

## Scope
- Cerebro `Snapshot final` (JS):
  - clean labels;
  - the "number + name" line;
  - a standalone full name that contains the label (same burst);
  - new outputs `zelle_nombre_cuenta` (the number the name came with) and `zelle_nombre_suelto` (a
    standalone full-name line).
- Migration 131: column `cerebro_beneficiario_parcial.zelle_nombre_cuenta`.
- Cerebro `Merge beneficiario` (SQL):
  - rule 1 across bursts (a standalone full name that contains the stored name);
  - rule 3 (the account changes → a tied name is dropped).
- Not changed: `Registrar zelle auto`, the reparto detector, and stored history.

## TDD
- Mode: strict, from the global config.
- Runners:
  - Snapshot: `pruebas/banco-nombre-zelle.js`, which runs the real node code.
  - Merge: the node's own SQL, run with PREPARE/EXECUTE on wacrm-ensayo.

## Tasks
- [x] Z1 — Snapshot final: rules 1 (same burst and number + name line) and 2, plus the new outputs.
  - Harness RED, then GREEN.
  - The existing name cases stay unchanged.
- [x] Z2 — Migration 131 and Merge beneficiario SQL: rule 1 across bursts and rule 3.
  - Ensayo sequences RED, then GREEN.
- [x] Z3 — Deploy: staging (131 + Cerebro), then prod, with backups; watch the executions.
- [x] Z4 — The name the bot CONFIRMS reaches the panel. Approved by the user on 2026-09-28 ("eso esta
  bien").
  - Evidence: of 122 bot confirmations, 113 match what was stored. In 7 of the 9 mismatches the
    bot was right (Lisandra, Sampedro, PTK family, Liliana, Yorlandis, Yadamy, Tiger), and 13
    confirmations were never stored.
  - The user's rule: a field labelled "Nombre:" in the customer's data is the name, kept as
    written ("Nombre: Yandry Batista / Iscrito: K&Y …" → Yandry Batista).
  - Migration 132: `cerebro_aplicar_nombre_confirmado`, fired by an AFTER INSERT trigger on
    agent messages that carry "*Nombre:*". It corrects the NAME only, when:
    - exactly one Zelle block is in the message;
    - the account equals the only current Zelle beneficiary of an open operation;
    - the beneficiaries are not locked;
    - every word of the name was written by the customer in the last 24 h (so a typo such as
      "Mairensy" never overwrites a correct "Mairenys").
  - It writes the same notes block as `Registrar zelle auto` (the sync applies it) and updates
    `cerebro_beneficiario_parcial`. It never raises and never creates a beneficiary.

## Acceptance
- On the real texts:
  - Nelson → "Nelson Tejo Perez";
  - Mi Hermana → "yadamy truyenque dominguez";
  - Liliana → "Liliana Gonzales Velazquez";
  - "MF Farm Solutions";
  - "Tata".
- Tata then a different account without a name → no name, so no wrong pair.
- Names that were already right behave the same: Liudis Aguilar Rojas (line + number), Maria Del
  Carmen Silva (contact card), a name read by the vision.

## Progress
- 2026-09-28 Z1 — `Snapshot final`.
  - Patch `pruebas/parche-nombre-zelle.py`.
  - Bench `pruebas/banco-nombre-zelle.js` (real node code): RED 14 failures, then GREEN 12/12.
  - A replay of all 2,565 real customer bursts since August through the old and the new code
    (`pruebas/comparar-snapshot-historico.js`) found two more wrong outputs:
    - "depositelo agui" and "registrada como Leidis Guerra" read as names;
    - names paired with another account in multi-account bursts.
  - Added:
    - more non-name words;
    - punctuation cleanup;
    - lowercase names only with 3+ words;
    - rule 3 inside the burst: the name must be tied to the main account.
  - The 7 new cases were RED, then GREEN 19/19.
  - Final replay: 37 bursts change.
    - Gains: names written next to their number that used to be lost (Eddys Pérez, LLM Insurance
      Corp, Jose Luis Rodríguez Velázquez, Cesar Cuba Rodriguez…).
    - Cleaned: Tata, MF Farm Solutions, Miami Tuna Export Services.
    - Completed: Liliana Gonzales Velazquez, Orainis Espinosa Figueredo.
    - 6 names dropped, all of them wrong pairs in multi-account bursts: Tati U, Imperium Dynasty LLC
      x2, Allan MULTICERVICE, Marlen Comendeiro Movil, Liudis on Jose Carlos's account.
- 2026-09-28 Z2 — migration 131.
  - Adds `zelle_nombre_cuenta` and `cerebro_nombre_completa`.
  - Assertion `zelle-holder-name.sql`: RED (function missing), then GREEN 4/4.
  - `Merge beneficiario` SQL:
    - rule 1 across bursts;
    - rule 3: the account changes without a name → the name is dropped.
  - Bench `pruebas/banco-merge-nombre.py` runs the node's real SQL on ensayo: RED (Nelson, Tata),
    then GREEN 7/7. Commit 4748790.
- 2026-09-28 Z3 — deploy.
  - 131 on staging (4/4) and on prod; the md5 is the same on both (92c7cfef…).
  - Cerebro staging, then prod: only `Snapshot final` and `Merge beneficiario` change.
  - The live code passes every bench, including banco-movil-63.
  - Order: DB first, because the new node SQL needs 131.
  - Rollback copies: `ROLLBACK-cerebro-{staging,PRODUCCION}-antes-nombre-zelle.json`. Restore the
    node BEFORE dropping the function.
- 2026-09-28 Z4 — migration 132 (`cerebro_aplicar_nombre_confirmado` plus the trigger
  `trg_zz_nombre_confirmado_zelle` on agent messages).
  - Assertion `zelle-confirmed-name.sql`: RED (still "Liliana"), then GREEN 7/7.
    - The setup now includes the accumulated row that `Merge beneficiario` always leaves.
  - The rollback drops the trigger and the functions; checked (case 1 fails again), then 132 was
    re-applied.
  - Read-only simulation over the real mismatches since August: 11 of 12 would be corrected with
    the right name.
    - Corrected: Lisandra, Sampedro, PTK family, Liliana, Yorlandis, Yadamy, Tiger, Miami Tuna x2,
      Xpress, MF Farm.
    - The only one left untouched is the bot's typo "Mairensy"; the customer wrote "Mairenys".
  - Applied on staging (every assertion green: reparto 13, 131 4, 132 7) and on prod; the md5 is the
    same on both (d0967dd3…). Commit e4e3734.
  - Limitation: it only corrects names. The 13 confirmations that were never stored as a
    beneficiary are not created by this.
