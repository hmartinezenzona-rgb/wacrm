# Feature: panel in Spanish, "Resumen" renamed "Finanzas"

## Objective
The CRM panel shows its interface in Spanish, and the section "Resumen" is called "Finanzas".

## Problem
The panel copy lives in messages/en.json (about 1,800 strings, next-intl). src/i18n/request.ts reads the locale from
NEXT_PUBLIC_APP_LOCALE (default 'en') and falls back to en.json when messages/<locale>.json is missing. There is no
es.json, so the panel is in English except a few hard-coded Spanish screens.

## Why (owner, 2026-10-06)
"quiero poner el crm en español y renombrar algunas cosas" — for now only "que resumen sea finanzas".

## Scope
- messages/es.json: full translation of en.json, same keys and structure, ICU placeholders/plurals/rich-text tags kept
  byte-identical in their syntax ({count}, {count, plural, ...}, <b>...</b>), neutral professional Spanish, the
  business's own vocabulary where it already exists in the app (remesa, recarga, combo, visa, Zelle, Clasica, Tropical,
  tarjeta, beneficiario, deposito, operacion, Calculadora, Tablero...). Brand "Remesas YA" unchanged.
- Rename: the section's visible name becomes "Finanzas" in Spanish ("Finances" in English): Sidebar.resumen, the
  matching Header key, and Resumen.page.title ("Finanzas e historial" / "Finances and history"). The in-page block
  "Resumen por periodo" keeps its name. Route /resumen, the "Resumen" namespace and code identifiers stay unchanged.
- Locale switch: NEXT_PUBLIC_APP_LOCALE=es where builds read it (build env examples/docs in infra/deployment); the real
  staging/production build env files are changed only at deploy time with the owner's go-ahead.
- A test that es.json has exactly en.json's keys and the same ICU arguments per string.
- Out of scope for now: hard-coded English strings outside the catalog (listed in the doc as a follow-up), date and
  number formats, renaming routes or namespaces.

## Constraints
- No behaviour change besides copy. Existing tests that read en.json keep passing.
- Deploy: staging first for the owner's look, then production with the owner's go-ahead.

## TDD
Strict TDD on (user config). Runner: vitest (npm test). RED: the parity test fails before es.json exists.

## Tasks
- [x] T1 Parity test (RED) + es.json for the sections in daily use: LoginPage, Sidebar, Header, ModeToggle, Dashboard,
  Inbox, Contacts, Settings, Resumen, Tablero; rename Resumen -> Finanzas (es and en).
- [ ] T2 es.json for the remaining sections (Pipelines, Broadcasts, Automations, Flows); parity test GREEN; list the
  hard-coded English strings outside the catalog.
- [ ] T3 Staging build with NEXT_PUBLIC_APP_LOCALE=es; owner's look.
- [ ] T4 Production with the owner's go-ahead.

## Acceptance criteria
- With NEXT_PUBLIC_APP_LOCALE=es the panel menus, headers, buttons and messages are in Spanish; the menu shows
  "Finanzas".
- es.json and en.json have identical key sets and ICU arguments; typecheck, lint and the full test suite pass.

## Progress
- 2026-10-06 document created. Delivery strategy: ask-on-risk (the translation is data, not authored logic).

- T1 done: RED observed (parity test failed: es.json missing, 1,799 keys missing; 3 of 4 tests failed). es.json holds LoginPage, Sidebar,
  Header, ModeToggle, Dashboard, Inbox, Contacts, Settings, Resumen, Tablero; the key and ICU tests pass for those
  sections (only Pipelines, Broadcasts, Automations, Flows keys are still missing). Rename applied in both catalogs
  (Sidebar.resumen, Header.resumen, Resumen.page.title). src/i18n/request.test.ts proves NEXT_PUBLIC_APP_LOCALE=es loads es.json.

## Next step
T2.
