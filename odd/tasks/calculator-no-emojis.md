# Calculator: remove decorative emojis

## Objective
Drop every emoji from what the Calculator page shows on screen.

## Owner request (2026-10-08)
"En la calculadora aparecen emojis que realmente no aportan mucho y se ve feo, por ejemplo: Facturado (GYD). Quita los emojis."

## Scope
- In: visible text of `src/app/(dashboard)/calculadora/page.tsx` (titles, headings, buttons, summaries, help text, warnings). Words stay exactly; only the emoji and the space after it go.
- Out: the `.txt` export content, anything stored or sent, other pages, ids/test ids/data attributes, semantic colours, lucide icons, "•" bullets, the box grammar. No replacement icons.

## TDD
Mode: strict, enabled. Source: user global CLAUDE.md. Runner: `npx vitest run <files>`.

## Tasks
- [x] T1 RED: test asserting no `\p{Extended_Pictographic}` in rendered states (open week bot+manual, archived week, empty, clear dialog)
- [x] T2 GREEN: strip emojis in page.tsx; update emoji-bearing lookups in page.test.tsx
- [x] T3 verify (vitest full, tsc, eslint, final search) and commit

## Evidence
See the commit message and the final report.

## Open points
- The fullscreen button shows "✕ Salir de Pantalla Completa" / "⛶ Maximizar" (text glyphs, not emoji pictographs); left as is, owner to decide.
