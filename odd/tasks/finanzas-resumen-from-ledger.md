# Finanzas: the Resumen comes from the ledger, and the rounding leftover is profit

## Objective
The two blocks of the Finanzas page (`src/app/(dashboard)/resumen/page.tsx`) always agree for the same day, and the money a customer deposits that is not
delivered because of whole-unit rounding is counted as the business's profit.

## Problem / why (production, 2026-10-08, verified)
- "Resumen" (five period cards: hoy, ayer, esta semana, este mes, mes pasado) <- RPC `cerebro_dashboard_resumen()` <- view `cerebro_resumen_volumen`
  <- view `cerebro_volumen_diario`: counts OPERATIONS and sums what customers DEPOSITED. Today: 4 operations, 130,100 GYD.
- "Cierre financiero" <- RPC `crm_cierre_financiero(desde, hasta)` <- the calculator ledger `remittance_calculator_entries`: sums FACTURADO.
  Today: 4 operations, 130,060 GYD.
- The 40 GYD: Carlos Sangles deposited 47,100 GYD by Zelle at 260 -> floor(47,100 / 260) = 181 USD delivered; the ledger line bills 181 x 260 = 47,060.
  The 40 GYD stay with the business but appear nowhere (not billed, not profit).
- The gap is much larger on longer periods: the Resumen only knows bot operations, the close also counts MANUAL ledger entries
  (e.g. "ayer" Resumen 0 vs close 191,900).

## Owner decisions (2026-10-08)
1. The Resumen comes from the SAME source as the Cierre (the calculator ledger): both blocks always agree and the Resumen includes manual operations.
2. The rounding leftovers "si deben de contar como ganancia": money deposited and not delivered because of rounding is profit and must show in Finanzas.

## Authorised scope
Repo edits; migrations and assertions on STAGING (kolppplawzdsjfydwejr) only; READ-ONLY SELECTs on production (hqztotshnlzaiziwjyzh). No production write,
no n8n, no ssh, no deploy, no push.

## Design
### Part 1 - migration 234 (`cerebro_dashboard_resumen` from the close)
- Dependency query on staging: `cerebro_resumen_volumen` is read only by `cerebro_dashboard_resumen`; `cerebro_volumen_diario` is read by
  `cerebro_resumen_volumen`, `cerebro_volumen(date,date)` and `cerebro_dashboard_volumen_por_servicio` (a dashboard widget). Nothing app-side reads the views
  directly. Decision: both views stay exactly as they are (the dashboard widgets are untouched); only the function body changes.
- `cerebro_dashboard_resumen()` keeps its name, signature, returned columns and grants. Its body calls `crm_cierre_financiero(desde, hasta)` once per period
  and reads `totales`: `operaciones` = totales.operaciones, `volumen_gyd` = totales.facturado_gyd, `ticket_medio_gyd` = round(facturado / operaciones),
  NULL when 0 (the old view rounded the ticket too). Periods unchanged, in America/Guyana: hoy, ayer, esta semana (Monday -> today), este mes, mes pasado.
  Reusing the close (not re-deriving its WHERE) guarantees the same statuses, exclusions (void, deleted, pending-rate), day attribution and account scoping.
- SECURITY change: the old function was SECURITY DEFINER with NO account filter (any authenticated user saw the operations of every account). The close
  scopes to `is_account_member(account_id)`; since the new body calls the close, the Resumen is scoped identically (members see only their accounts,
  no identity -> zeros, as the close does).
### Part 2 - migration 235 (the ledger bills the deposit)
See "Part 2 analysis" below.

## Part 2 analysis (read from staging `calculator_feed_operation` 226, `calculator_operation_parts` 142, `calculator_amount_from_basis`, `calculator_facturado`, `calculator_invertido`)
The feed prices each part of a completed operation from its `basis` (GYD): single-service operation -> basis = `quoted_source_amount` (the GYD the customer
deposited: `cerebro_registrar_deposito` sets / accumulates it from the verified receipts); mixed reparto -> `calculator_operation_parts` gives each service its
share, every non-last share rounded to cents and the LAST dollar service the remainder, so the bases add up exactly to the deposit.
| Service | amount | facturado BEFORE | facturado AFTER (235) | leftover can arise? |
|---|---|---|---|---|
| CUP | basis x cup_global_rate (CUP) | amount / rate = basis | basis | no (exact) |
| ZELLE | floor(basis / tier price) USD (260 / 250 / 245 by the deposit's tier) | amount x price | basis | yes, < 1 price unit |
| CLASICA, TROPICAL, USDT (any other dollar rail) | floor(basis / usdt_sell_gyd) | amount x price | basis | yes |
| EFECTIVO (cash USD) | floor(basis / efectivo_usd_gyd) | amount x price | basis | yes |
| RECARGA | units = basis / recharge price (pending unless the deposit is a whole multiple) | units x price = basis | basis | no |
| SALDO_MOVIL | packages = basis / package price (pending unless whole) | packages x price = basis | basis | no |
| COMBO | basis | basis | basis (invertido = combo cost) | no |
| VISA | basis | basis | basis (invertido 0) | no |
| mixed reparto | per part, as above | per part | per part = its basis; parts sum to the deposit | on the dollar parts |
invertido (what the delivery costs) is unchanged everywhere; retorno = facturado - invertido. Manual entries never go through the feed.
`crm_resolve_pending_entry` (admin enters the missing rates) priced a resolved line with the same `calculator_facturado`; it gets the same rule, otherwise a line
resolved by hand would lose its leftover (the brief says pending lines keep their behaviour: they stay pending with no figures until resolved).

## TDD
Mode strict, source user global CLAUDE.md. Runners: DB = staging SQL assertion run through docker postgres:17-alpine psql as
`BEGIN; <assertion minus its own BEGIN/ROLLBACK>; ROLLBACK;` (never `psql -1` alone: it can COMMIT a fixture); app = `npx vitest run <files>`
(RED then GREEN), `npx tsc --noEmit`, `npx eslint <changed>`.

## Tasks
- [x] P1.1 Read and compare definitions (repo / staging / production), dependency query
- [x] P1.2 Assertion `resumen-from-ledger.sql` RED on staging
- [x] P1.3 Migration 234 + ROLLBACK-234; apply; GREEN; rollback proof; widgets untouched evidence
- [x] P1.4 Commit part 1
- [x] P2.1 Per-service analysis of facturado / leftover (below)
- [x] P2.2 Assertion `ledger-bills-the-deposit.sql` RED
- [x] P2.3 Migration 235 + ROLLBACK-235; apply; GREEN; rollback proof
- [x] P2.4 Related ledger assertions re-run, expectations updated deliberately
- [x] P2.5 Client-side recompute check (src/lib/calculator, components, .txt export)
- [x] P2.6 Production preview (read-only) and the list of existing lines with a leftover
- [x] P2.7 Commit part 2

## Evidence
### Part 1 (staging, 2026-10-08)
- Definitions: repo (migration 055 body, 228 close) = staging = production for `cerebro_dashboard_resumen` (md5 84ba499d6e5e0ad876cc0ebc11b1eb28) and
  `crm_cierre_financiero` (c903a47147c04a61b06471061b2e5cff). Drift: view `cerebro_resumen_volumen` md5 differs (staging 9f176ed9..., production 0ba555bd...), only the
  deparser printing `'ayer'::text AS text`; ACL drift: on production `crm_cierre_financiero` has no service_role grant (staging has it). Neither is touched.
- RED: `resumen-from-ledger.sql` failed before 234 (`hoy must equal the close: card 0 operations vs close 2`). 234 applied (`BEGIN; 234; COMMIT;`), assertion GREEN.
- Rollback proof (inside a rolled-back transaction): ROLLBACK-234 restores md5 84ba499d... and the same ACL; after 234 the md5 is 3827c1204e1e3ebd32e9990cf6477a44.
- Widgets untouched: `cerebro_volumen_diario` 6894f74169dd212b375f223a32d0bfa7, `cerebro_resumen_volumen` 9f176ed9ba017e762f42d5423abf17b3, `cerebro_volumen`
  41a41060c9336e7bc97b736625f1b24b, `cerebro_dashboard_volumen_por_servicio` 9369b9f6e5bdc8ca9c41bcb47662f6cd, `crm_cierre_financiero` c903a471... all unchanged after 234.
- Cost: `explain analyze` of the Resumen as a member: 34 ms (five calls of the close).

### Part 2 (staging, 2026-10-08)
- RED: `ledger-bills-the-deposit.sql` failed before 235 on every leftover case (Carlos 47060 vs 47100, tier 259500 vs 259740, cash 46980 vs 47100, clasica, tropical, mixed
  54860 vs 55000, mixed with decimals 74786.67 vs 75000, invariant) while the exact / CUP / visa / combo / saldo / recarga / manual / pending / idempotent cases passed.
  235 applied (`BEGIN; 235; COMMIT;`), assertion GREEN (checks 1-14, incl. 13b a pending line resolved by hand and 7e proving CUP / recarga / saldo facturado equals the old formula).
- Rollback proof (rolled-back transaction): ROLLBACK-235 restores calculator_feed_operation ebd19f921ab0b66f8fcb2770b0d5c543 and crm_resolve_pending_entry
  452b976a0dde55d2754568431060263f with the same ACLs; with them restored the assertion is RED again (cases 1, 4b, 5b, 6, 8, 13b, 14 fail).
- Fingerprints on staging after 234 + 235: cerebro_dashboard_resumen 3827c1204e1e3ebd32e9990cf6477a44, calculator_feed_operation 31c256da1d64ebee784f3a5eb5bedde3,
  crm_resolve_pending_entry 7fa533e0b74235a27c6a6f1598a4dff8; unchanged: crm_cierre_financiero c903a471..., both views. Staging holds no fixture rows (0 entries / accounts / users / operations left).
- Related assertions (53 files that touch the ledger / feed / zelle / reparto / calculator): baseline before 235 = 51 pass, 2 fail (delivery-feed-evidence: fixture setup fails, feed-mixed
  cases 5 and 6 fail); after 235 and the deliberate updates below = the same 51 pass + the same 2 fail with the same messages (this change does not touch their subject: case 5 is
  the pending lines of a mixed op, case 6 the close counting a mixed op once; feed-mixed cases 2-3 pass on amounts only). Changed expectations (old -> new, why: the line now bills the deposit):
  - feed-matrix case 2 ZELLE 26,000 @265: facturado 25970 -> 26000, retorno 1470 -> 1500 (98 USD x 265 = 25,970 left 30 GYD)
  - feed-matrix case 3 CLASICA same: retorno 1470 -> 1500
  - feed-matrix case 8 voided line keeps its figures: 25970 / 1470 -> 26000 / 1500
  - feed-matrix case 9 revival at the new rate 300: facturado 25800 -> 26000, retorno 4300 -> 4500 (86 USD x 300 = 25,800 left 200 GYD)
  - feed-matrix case 10 untouched snapshot and case 19 replay no-op: 25970 -> 26000
  - zelle-objective-tier case 8 and zelle-quote-tier case 8 (259,740 GYD, no objective -> 1038 USD at 250): facturado 259500 -> 259740
  - resolve-pending case 6 (Zelle 26,000 resolved at 265): facturado 25970 -> 26000, retorno 1470 -> 1500
- App: no change needed. The Calculator table, totals, weekly cut and `.txt` export read the stored `facturado_gyd` (`ledger-read-model.ts`, `weeks.ts`, `calculadora/page.tsx`);
  nothing recomputes amount x price on the client for ledger lines. The only remaining copy of the old formula is the domain-only TypeScript mirror (`projection.ts` /
  `entries.ts` / `formulas.ts`, exported from the index and used by tests and the manual line parser, not by any shipped read of a bot line); left as is.
  A Zelle line now reads 47,100 / 43,440 / 3,660 for 181 USD.
- Vitest: 187 files / 2511 tests pass; `npx tsc --noEmit` clean (no app file touched).

### Edge cases (what the rule yields; owner's call where marked)
| Case | What the ledger does | Verdict |
|---|---|---|
| Destination amount fixed by a human (`admin_locked_fields.quoted_destination_amount`: 65,000 -> 250 USD, or a human typing FEWER USD, e.g. 200) | The feed never reads the destination amount: it prices floor(quoted_source_amount / price). 65,000 -> 250 USD, facturado 65,000 (unchanged); with 200 typed by a human the line still says 250 USD and bills 65,000 (asserted, 12a). The leftover therefore stays below one price unit; a human-reduced delivery is NOT visible in the ledger. | Rule is bounded. Whether a human-reduced delivery should show as extra profit is the owner's call (the ledger amount would not match what was really delivered). |
| Deposit larger than the quote ("envio mas") | `quoted_source_amount` is the deposit accumulated by `cerebro_registrar_deposito` from the verified receipts, so "the operation's GYD" is the whole deposit; the line delivers floor(deposit / price) USD and bills the whole deposit. | Consistent with "money in minus cost of the ledger's USD". If the bot delivered only the quoted USD, the extra shows as profit while invertido counts the larger USD: owner's call. |
| `quoted_source_amount` vs the sum of verified receipts | The ledger follows `quoted_source_amount` (asserted, 12b: 65,000 with receipts 60,000 bills 65,000). Production today: 4 of 4 operations with ledger lines have both equal. | No change from today; flag only. |
| `missing_inputs` / `verified_pending` | Unchanged: no figures. When an admin resolves one (`crm_resolve_pending_entry`), the same rule now applies (asserted, 13b). | Decision: included so a hand-resolved line does not lose its leftover. |
| Weekly cut / archived weeks | Untouched; the cut archives the stored figures. | OK |
| Completed lines created before | NOT rewritten (149 append-only; asserted, 9). | OK |
| Manual entries | Untouched (asserted, 11). | OK |
| Mixed reparto | Each part bills its basis; the bases add up exactly to the deposit (asserted, 8a-8c and the invariant in 14, including a CUP share with cents). | OK |

### Production preview (read-only, 2026-10-08, Guyana)
- Part 1 alone: Resumen hoy 4 ops / 130,060 (was 130,100), ayer 7 / 191,900 (was 0), esta semana 35 / 1,287,772.4 (was 4 / 130,100), este mes 35 / 1,287,772.4, mes pasado 0 / 0;
  the close shows exactly the same numbers; ticket hoy round(130,060 / 4) = 32,515.
- Part 2: new lines bill the deposit. The existing lines are NOT rewritten, so today stays 130,060 until Carlos' line is corrected by hand.
- Existing production lines that carry a leftover (operation-fed, completed, facturado <> deposit): exactly one, `c9efb97e-aff6-484d-a852-5f1c4d8c9642` (Carlos Sangles, op
  `27fc3d2f-f9c7-4141-ae2d-915e407d0de2`, ZELLE 181 USD, deposit 47,100, facturado 47,060, invertido 43,440, retorno 3,620). Hand-corrected to 47,100 / 43,440 / 3,660 the Resumen and the
  close would read 4 ops / 130,100 for today. No other line (CUP 1 line, ZELLE 3 lines in total) differs from its deposit.

## Open points
- Owner: correct Carlos' production line by hand (admin edit of the entry) if he wants today's 40 GYD counted.
- Owner: the two edge calls above (human-reduced delivery; deposit above the quote).
- Production drift to know before applying: `cerebro_resumen_volumen` deparse differs staging/production (cosmetic); `crm_cierre_financiero` and the feed have no `service_role` grant on production
  (staging has it); neither blocks 234 / 235. Production migrations 234 and 235 were NOT applied (no production write authorised).
- `feed-mixed` (cases 5, 6) and `delivery-feed-evidence` (fixture setup) were already failing before this work.

## Production (2026-10-08, owner "si corrigelo ... hecho eso pasa a produccion")
- Backup `~/wacrm-respaldos/produccion-20261009T024034Z.dump`. Pre-check: production had the pre-234/235 definitions
  (`cerebro_dashboard_resumen` 84ba499d…, `calculator_feed_operation` ebd19f92…, `crm_resolve_pending_entry` 452b976a…),
  last migration 233.
- `~/cerebro-fase1/pruebas/gate136-aplicar-db.py` (bundle 234 + 235; helper `zz_wu5b_exec` created before, dropped after,
  count 0): `ensayo` -> the five function md5s and the `cerebro_volumen_diario` view md5 equal to staging;
  `GATE_BUNDLE=ida-y-vuelta ensayo` -> the three replaced functions back to their old md5s; `aplicar` -> `{"r":"OK"}`,
  recorded as `234_resumen_from_ledger` and `235_ledger_bills_the_deposit`.
- Assertions on production (rolled back): `ledger-bills-the-deposit` passes. `resumen-from-ledger` cannot run there: its
  fixture uses staging's account ids (FK error on insert, nothing written). Checked directly instead, as the owner: every
  Resumen period equals `crm_cierre_financiero` over the same dates (hoy 4 / 130,060; ayer 7 / 191,900; semana and mes
  35 / 1,287,772.40; mes pasado 0) before the line correction below.
- Carlos Sangles' line `c9efb97e` (operation 27fc3d2f, fed before 235): corrected with the panel's own
  `crm_corregir_entrada_calculadora(entry, 47100, 43440)` through `gate137-carlos-sobrante.py` (dry run, then applied):
  47,060 / 43,440 / 3,620 -> 47,100 / 43,440 / 3,660; one live line for the operation; no outbox rows.
- Read back after both: hoy 4 operations, Resumen 130,100 = Cierre 130,100, ganancia 11,164.85; ayer 191,900 = 191,900;
  esta semana 1,287,812.40 = 1,287,812.40.
