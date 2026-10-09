# Finanzas layout and visual pass

## Objective
Make the Finanzas screen (`/resumen`) cleaner and more readable: fewer elements, "Resumen" on top, and a consistent visual treatment.

## Owner request (verbatim)
"En finanzas quita de ahí el círculo que pusimos y también anuladas y pendientes; también ahí mejora lo visual porque veo partes que les faltan los colores y demás y se ven opacas; y el resumen me parece que quedaría mejor arriba de todo."

## Decisions (already interpreted)
1. "El círculo" = the service colour dots (`ServiceDot`). Removed from Finanzas only: by-service table, detail table, history "Servicio" cell. The name stays as text. The component, `service-color.ts` and the Calculator keep their dots.
   This reverses, for Finanzas only, step 2 (T7) of `semantic-money-colors.md`.
2. The "Anuladas y pendientes de tasa" table is removed from the screen. Data stays in the RPC and in the CSV export. Dead catalog keys removed from es/en.
3. "Resumen" (five period cards + note) moves to the top. Order: header, Resumen, Cierre financiero, Historial.
4. Visual pass using only the approved colour language (money-in blue, money-out amber, profit green / loss red, status tokens, `tarjeta-elevada`). No raw hex, no decorative icons, no layout change beyond item 3.

## TDD
Enabled. Source: user global CLAUDE.md. Runner: `npx vitest run <files>`.

## Tasks
- [x] T1 Structure: remove dots from the three tables
- [x] T2 Structure: remove the excluded section (export untouched), clean catalog keys
- [x] T3 Structure: Resumen on top
- [ ] T4 Visual: Resumen cards (volume in money-in tone, elevation/stripe)
- [ ] T5 Visual: by-day chart with money-tone colours + legend
- [ ] T6 Visual: section headings and spacing, elevated cards
- [ ] T7 Visual: table headers, right-aligned numerics
- [ ] T8 Visual: history filter bar and pagination

## Evidence
- Structure: RED observed (5 failing tests: dots present, excluded table rendered, section order), then GREEN. Tests changed deliberately: section test "opens on the current Guyana week..." (excluded assertions moved to a new "does not render the voided table" test), "tones the three money columns..." (voided-row tone assertions dropped), "service dots" replaced by "no service dots"; page test: the three dot tests replaced by one plain-text test, new section order test. Dead catalog keys removed: Resumen.cierre.excluidas, cols.estado, cols.motivo, estado.*.

## Open points
- Rate-pending lines are no longer visible on this screen (still in the CSV export).
