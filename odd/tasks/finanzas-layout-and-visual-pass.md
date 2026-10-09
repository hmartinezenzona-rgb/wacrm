# Finanzas layout and visual pass

## Objective
Make the Finanzas screen (`/resumen`) cleaner and more readable: fewer elements, "Resumen" on top, and a consistent visual treatment.

## Owner request (verbatim)
"En finanzas quita de ahí el círculo que pusimos y también anuladas y pendientes; también ahí mejora lo visual porque veo partes que les faltan los colores y demás y se ven opacas; y el resumen me parece que quedaría mejor arriba de todo."

## Decisions (already interpreted)
1. CANCELLED by the owner ("yo no te mandé a quitar los puntos de color"): the service dots stay exactly as they were. What "el círculo que pusimos" refers to is unknown; nothing else is removed on a guess. Awaiting the owner.
2. The "Anuladas y pendientes de tasa" table is removed from the screen. Data stays in the RPC and in the CSV export. Dead catalog keys removed from es/en.
3. "Resumen" (five period cards + note) moves to the top. Order: header, Resumen, Cierre financiero, Historial.
4. Visual pass using only the approved colour language (money-in blue, money-out amber, profit green / loss red, status tokens, `tarjeta-elevada`). No raw hex, no decorative icons, no layout change beyond item 3.

## TDD
Enabled. Source: user global CLAUDE.md. Runner: `npx vitest run <files>`.

## Tasks
- [x] T1 (cancelled) dots removed in 412d980, restored in the follow-up commit
- [x] T2 Structure: remove the excluded section (export untouched), clean catalog keys
- [x] T3 Structure: Resumen on top
- [x] T4 Visual: Resumen cards (volume in money-in tone, elevation/stripe)
- [x] T5 Visual: by-day chart with money-tone colours + legend
- [x] T6 Visual: section headings and spacing, elevated cards
- [x] T7 Visual: table headers, right-aligned numerics
- [x] T8 Visual: history filter bar and pagination

## Evidence
- Structure: RED observed (5 failing tests: dots present, excluded table rendered, section order), then GREEN. Tests changed deliberately: section test "opens on the current Guyana week..." (excluded assertions moved to a new "does not render the voided table" test), "tones the three money columns..." (voided-row tone assertions dropped), "service dots" replaced by "no service dots"; page test: the three dot tests replaced by one plain-text test, new section order test. Dead catalog keys removed: Resumen.cierre.excluidas, cols.estado, cols.motivo, estado.*.

## Open points
- Which element is "el círculo que pusimos"? Awaiting the owner.
- Rate-pending lines are no longer visible on this screen (still in the CSV export).

## Visual pass evidence
- RED observed (7 failing tests) before GREEN. Full suite 187 files / 2511 tests pass, tsc and eslint clean.
- Chart: `money-in` / `money-profit` added to `chartColors` (opt-in; `AvailableChartColors` default palette unchanged, asserted in `chart-colors.test.ts`).
- New text/background pairs: header row `text-muted-foreground` on `bg-muted/50` over card: dark 5.58, light 5.26 (both >= 4.5). Money text reuses approved pairs.
- Staging deploy (2026-10-09; release 26725abc35abc2bb0324425e5ade2f7c148c4d5f, BUILD_ID PnXpI-Gux8fUOO0gVWsS1, app commit 26725ab; also carries the Calculator fullscreen label change "Salir de Pantalla Completa"): manifest environment=staging, project kolppplawzdsjfydwejr, 0 production refs, 32 files with staging refs, 114 build tests passed, sha256 OK on oracle2 and the unpacked release (2477 files) laid out like the previous one, pm2 wacrm-staging process cwd resolves to the new release, restarts 92 -> 93 and stable (unstable 0, still 93 after 20 s), /login 200 with the new BUILD_ID and "Bienvenido de nuevo", all 16 JS chunks listed by the client-reference manifests of the Finanzas resumen and Calculator pages served by crm.onlinefreedom.site byte-identical to the build, both served stylesheets linked from /login byte-identical to the build and the first (`060ntvq.-z15p.css`) contains `fill-money-in` and `fill-money-profit`, the deployed es messages (and the whole release) no longer contain "Anuladas y pendientes de tasa", and the Calculator chunk `0l.2rkxz5_w-h.js` contains "Salir de Pantalla Completa" with no "✕" glyph before it. Rollback: anterior -> 5b3b4ec (`ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/5b3b4ec75176cceebf887a70c040aa181136d965 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`).
