# Operations board visual pass

## Objective
The board (/tablero) reads at a glance: tinted column headers, cards with more contrast against the column, a bold
amount, and an age that warns when an operation waits too long.

## Owner request
"el tablero se ve pálido". Design approved, not to be re-decided. Change only what is listed.

## Decisions
- Column header: soft tinted background + accent stripe in the column's status tone, from the shared `--status-*`
  tokens (`src/lib/status-tone.ts`). requested = neutral, depositCheck = attention, readyToTransfer = attention,
  completed = success, incident = danger.
- Card: 3px inset left stripe in the tone of its own status (`statusTone(status)`), light elevation, clearly more
  contrast between column and card in both themes.
- Amount larger and bold. Name unchanged.
- Age: muted when recent, attention from 2 h, danger from 24 h; completed never escalates. Named constants and a pure
  function in `src/lib/tablero/board.ts`. Never colour alone (the text says "3 h" / "2 d", tooltip stays).
- No coloured service icons on the card; the service is plain text (names from unified-service-names).
- "Faltan datos del beneficiario": same text, attention tone and a small dot instead of the triangle.
- `awaiting_deposit` joins "requested", `deposit_received` joins "depositCheck" in `BOARD_COLUMNS` (client side).
- Unchanged: columns and order, counts, filters, read-only, chat link and aria-label, refresh, horizontal scroll, w-72
  columns, empty/loading/error states, focus ring.

## TDD
Mode: strict TDD ON. Source: user global CLAUDE.md. Runner: `npx vitest run <files>`.

## Tasks
- [ ] B1 board.ts: age tone constants + function, awaiting_deposit / deposit_received columns, tests
- [ ] B2 operations-board.tsx: column header, card stripe/elevation/contrast, amount, age colour, no icons, missing-recipient dot
- [ ] B3 verification and before/after lightness report

## Evidence
(filled per task)

## Open points
- The RPC still filters out `awaiting_deposit` and `deposit_received`; a later SQL task must stop doing that (the
  client now has a column for them).
