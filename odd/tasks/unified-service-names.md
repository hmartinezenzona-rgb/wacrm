# One name per service, everywhere

## Objective
Every screen that shows a service name shows the same canonical name for it, resolved from either vocabulary
(ledger keys, operation service types, delivery methods / beneficiary types).

## Owner request
Variants found: ZELLE/Zelle, CLASICA/Clásica, Saldo Móvil/Saldo móvil/SALDO MOVIL, VISA/Visa/Extensión de visa,
EFECTIVO/Efectivo en USD, "Trámites / Combos / Servicios" and the same in capitals, "Tarjeta CUP" vs "CUP".

## Decisions (approved by the owner)
Canonical Spanish names, exactly: CUP, Zelle, Clásica, Tropical, MLC, USDT, Efectivo USD, Recarga, Saldo móvil, Combo,
Visa, Trámites, Traducción, México, plus "Remesa mixta" (remittance split over several kinds) and "Remesa" only where
the screen cannot know the rail.
- ONE pure module `src/lib/service-name.ts` resolves any key to a canonical id and names an operation with the DB's
  precedence (`calculator_resolve_operation_service`, migration 223).
- ONE catalog namespace `ServiceNames` in es.json and en.json; Calculator and Finanzas history (no next-intl) use a
  shared Spanish table that a test proves equal to es.json.
- Display only: keys sent to the API or database never change. The Calculator `.txt` export and the text-box grammar do
  not change.

## TDD
Mode: strict TDD ON. Source: user global CLAUDE.md. Runner: `npx vitest run <files>`.

## Tasks
- [x] N1 Names module + catalog namespace (es/en) + tests (parity, es table equals es.json)
- [x] N2 Calculator, Finanzas close and Finanzas history
- [x] N3 Dashboard (donut labels, aged queue), operations board card text, inbox panel
- [x] N4 `CalculatorServiceType` gets COMBO and VISA if it is a pure type fix

## Evidence
- N1 5dfd12b: `service-name.test.ts` RED (module missing) then GREEN; `service-color` resolves through the canonical id.
- N2 702a124: calculator, close, history. RED observed on 8 calculator tests, then GREEN. History refactor-only (names
  already matched), covered by the existing tests.
- N3 acc2930: dashboard aged queue (new test, RED then GREEN), donut, board card text and pills, inbox panel (picker,
  closing control, correction form, add-beneficiary, card header). RED observed on 10 inbox tests.
- N4: COMBO and VISA added to `CalculatorServiceType`; tsc and calculator tests unchanged, so a pure type fix.
- The `use-service-name` hook test was written together with the hook (RED skipped for that tiny hook).
- Full suite 184 files / 2460 tests green; tsc and eslint clean.

## Open points
- Finanzas history still says Remesa for every rail: needs the RPC change (it only receives service_type), next task.
