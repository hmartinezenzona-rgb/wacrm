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
- Staging deploy (2026-10-09; release 5b3b4ec75176cceebf887a70c040aa181136d965, BUILD_ID DI6nzOuGV_kYy3t_jNSt0, app commit 5b3b4ec): manifest environment=staging, project kolppplawzdsjfydwejr, 0 production refs, 32 files with staging refs, 114 build tests passed, sha256 OK on oracle2 and the unpacked release (2477 files) laid out like the previous one, pm2 wacrm-staging process cwd resolves to the new release, restarts 91 -> 92 and stable (unstable 0, still 92 after 30 s), /login 200 with the new BUILD_ID and "Bienvenido de nuevo", all 13 JS chunks listed by the Calculator page client-reference manifest served by crm.onlinefreedom.site byte-identical to the build, the served Calculator page chunk contains "Facturado (GYD)", "Operaciones", "Semanas anteriores" and "Cierre Semanal PRO" and none of the 13 decorative emoji characters. Rollback: anterior -> 7ed8f14 (`ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/7ed8f14a9786d3fea9b92794b758952758f98af8 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`).
