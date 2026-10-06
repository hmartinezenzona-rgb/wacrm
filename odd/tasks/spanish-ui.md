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
- [x] T2 es.json for the remaining sections (Pipelines, Broadcasts, Automations, Flows); parity test GREEN; list the
  hard-coded English strings outside the catalog.
- [x] T3 Staging build with NEXT_PUBLIC_APP_LOCALE=es; owner's look (2026-10-06: "si"; production waits for delete-notifications). (Staging deployed 2026-10-06, owner's look pending.)
- [x] T4 Production with the owner's go-ahead.

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

- T2 done: es.json now covers all 14 sections (1,799 strings; 1,617 differ from en, the other 182 are already-Spanish
  values, cognates, brand names or placeholders). Parity test GREEN (4/4), request config test 2/2.
  NEXT_PUBLIC_APP_LOCALE=es added to infra/deployment/wacrm.produccion.build.env.example (before the two manifest-checked
  last lines) and the .env.local.example comment; the real build env files were not touched.

- 2026-10-06 T3 staging deployed (owner "dale despliega"): release 5959dd2 (BUILD_ID yglsJ1Tw9FC-6Vy9Qn0G7), served by
  crm.onlinefreedom.site. Staging build env ~/.config/wacrm/staging-build.env: NEXT_PUBLIC_APP_LOCALE en -> es in place
  (backup .bak-20261006; the manifest-checked last line WACRM_ENVIRONMENT stays last). Manifest staging / kolppplawzdsjfydwejr,
  114 money-path tests passed, 0 production refs / 33 staging refs, sha256 OK, 2417 files + DEPLOYED_VERSION. pm2 cwd =
  `~/wacrm-releases/current` -> 5959dd2, `anterior` -> 225cba2; `/login` 200 locally and on the domain, which serves the new
  BUILD_ID; restarts 63 -> 64 and stable. The served /login shows "Bienvenido de nuevo", "Correo electronico", "Iniciar
  sesion" and none of "Welcome back", "Forgot password", "Enter your password".
  Locale at runtime: pm2 runs node with --env-file=/etc/wacrm-hermes/wacrm.env, which still says NEXT_PUBLIC_APP_LOCALE=en
  (line 12). It does NOT override: Next inlines process.env.NEXT_PUBLIC_* at build time, so the build env decides (the
  login page proved it). Left untouched; set it to es there too only for consistency. Rollback: relink `current` to
  `anterior` + `pm2 restart wacrm-staging --update-env`. Production untouched.

## Terminology (owner review)
Dashboard = Panel; Inbox = Bandeja de entrada; Contacts = Contactos; Pipelines = Embudos (stages = Etapas); Deals =
Negocios (the already-Spanish delivery-proof strings keep "deal"); Broadcasts = Difusiones; Automations =
Automatizaciones; Flows = Flujos; AI Agents = Agentes de IA; Settings = Configuracion; Tablero = "Tablero de
operaciones"; Viewer = Observador; Owner = Propietario; Templates = Plantillas; Quick replies = Respuestas rapidas;
tags = Etiquetas; Incident = Incidencia.

## Follow-up: hard-coded English
Visible strings outside messages/*.json (list only, not fixed). calculadora/page.tsx and the *.ts API errors are
already Spanish or out of scope.
- src/app/join/[token]/page.tsx:76,80,84,88 (invite error titles), :189,194,200,215 (toasts), :226,260,267,275,283,340,387 (labels/buttons)
- src/app/(auth)/signup/page.tsx:102,122,164,169,184,199,209,214,241 (title, labels, placeholders, links)
- src/app/(auth)/forgot-password/page.tsx:54,68,82,102,124
- src/app/(dashboard)/notifications/page.tsx:128,161 (toasts), :188-189,202,210-211,264
- src/app/(dashboard)/agents/page.tsx:43-44
- src/components/agents/ai-usage.tsx:73,79,111,140,146-154,162,179,205
- src/components/agents/ai-playground.tsx:46,48,67,88,109-111,155,179
- src/components/flows/header.tsx:67-68,79,81,88,169-170
- src/components/flows/flow-editor-shell.tsx:109; src/components/flows/forms/node-config-form.tsx:459,501,660,808,931
- src/components/interactive/interactive-builder.tsx:97,102,107,112,230,323,374
- src/components/settings/quick-replies-manager.tsx:80,107,118,129-130,193,204,209,217
- src/components/settings/whatsapp-config.tsx:162,187,191,219,274,304,320,330,351,363,371 (toasts)
- src/components/settings/members-tab.tsx:173,225,251,271; invite-member-dialog.tsx:143 (toasts)
- src/components/settings/template-manager.tsx:550,778,848; ai-knowledge.tsx:202,211; appearance-panel.tsx:42; profile-form.tsx:273; settings-rail.tsx:51
- src/components/inbox/message-thread.tsx:501,514,567,579,624,633,713,722,783,829,848 (toasts)
- src/components/inbox/message-composer.tsx:272,280,295,453,473,500 (toasts); message-bubble.tsx:178
- src/components/contacts/contact-detail-view.tsx:351 (toast); src/app/(dashboard)/contacts/page.tsx:542
- src/components/broadcasts/step2-select-audience.tsx:432; step3-personalize.tsx:273,347; step4-schedule-send.tsx:128,141,204
- src/app/(dashboard)/broadcasts/page.tsx:162; broadcasts/[id]/page.tsx:82; automations/page.tsx:337
- src/components/automations/automation-builder.tsx:1013,1022,1311
- src/components/layout/sidebar.tsx:190; src/components/ui/dialog.tsx:75 and sheet.tsx:75 (sr-only "Close")
Count: roughly 150 occurrences in about 35 files (regex scan; not exhaustive: server-returned error strings and
multi-line JSX text can be missed).

- 2026-10-06 T5 done: 159 new keys in en.json and es.json (parity test green). New namespaces: Join (32), Signup (21),
  ForgotPassword (9), Common (close, used by dialog.tsx/sheet.tsx), Settings.quickReplies (19). Keys added to existing
  namespaces: Notifications, Inbox.{composer,messageThread,sessionTimer,bubble}, Contacts.{form,detailView,importModal,page},
  Settings.{whatsapp,members,invite,templates,aiKnowledge,appearance,profile,sectionsAria}, Sidebar.primaryNavLabel.
  Interpolated texts use ICU ({reason}, {name}, {count}, select for the media kind, rich tags for highlighted names).
  Test: src/i18n/spanish-screens.test.tsx renders forgot-password, signup, join (loading state), quick-replies manager and the
  dialog close button with es.json and asserts the Spanish text and the absence of the English one. Proof: full suite
  160 files / 1990 tests pass, tsc clean, eslint on the touched files 0 new problems (the one error, notifications/page.tsx:82
  setState-in-effect, is on unchanged HEAD code). RED was not observed separately for the new screens test (catalogs and
  components were converted in the same step); the parity test is the guard for key mismatches.

- 2026-10-06 T6 done: 250 new keys in en.json and es.json (2,217 keys in total, parity test green). New namespaces: Agents (32),
  InteractiveBuilder (21), Flows.header (15), Flows.validation.issues (54), Common.{currencies,modes,presence,relative,loading}.
  Besides the listed files, the final scan found visible English coming from helpers, now catalog-driven with an English
  fallback kept for non-UI callers and tests: lib/flows/validate.ts issues carry `code` + `params` (the English `message`
  stays for the API); lib/dashboard activity items carry `i18n` (feed renders Spanish); formatRelative (automations) and
  presenceLabel/formatLastSeen (members, assign menu) take an optional translator; plus template status/category badges,
  theme names and taglines, currency names, light/dark words in the appearance panel, mode toggle and settings overview, the
  canvas true/false branch labels, "Loading..." in the dashboard shell, avatar alt texts and the broadcast, flow, automation
  and interactive-builder strings.
  Tests: src/i18n/spanish-screens-more.test.tsx (agents playground, interactive builder, flows validation incl. a check that
  every emitted code exists in both catalogs, dashboard activity feed, presence and relative-time helpers) with es.json.
  Proof: full suite 161 files / 1998 tests pass, tsc clean, eslint on the touched files 0 errors (notifications/page.tsx:82
  setState-in-effect, untouched HEAD code, is the only error in the touched set and it predates this work). One full-suite
  run timed out once on the notifications page test under load (5.9 s); it passes alone and on the re-run.
  RED was not observed separately for the new tests (conversion and catalogs landed together).

### Intentional leftovers (final scan)
- Server-returned error strings shown verbatim (`payload.error`, `data.error`) and src/lib/whatsapp/interactive.ts
  `validateInteractivePayload` messages (shared by the API, the automation engine and their tests): server-side contract, out
  of scope per the follow-up definition.
- Date and number formats: date-fns `formatDistanceToNow` / `format` (conversation list, notifications, flow runs, token chart
  month names), `toLocaleDateString/String()` in broadcast detail. Out of scope in the original Scope; a follow-up could pass the
  date-fns `es` locale.
- Default content stored in new flow nodes (flow-editor-state `Yes`, `View options`, `Option 1`; node-config-form `Option`,
  `Option N`; interactive-builder list button `Menu`): these defaults become customer-facing message content, so changing them changes
  stored data; owner to decide. (The automation default name "Untitled automation" was translated, it is only an internal name.)
- Sample data: broadcast preview contact `John Doe` / `Acme Corp` / `john@example.com`, profile placeholder `Ada Lovelace`,
  `sk-... (OpenAI)`, `en_US`, `reply_id`/`id` field placeholders (code identifiers).
- Dead English fallbacks that are never rendered: flows/shared.tsx NODE_META labels/blurbs and NODE_CATEGORIES (the UI reads
  Flows.builder.nodes/categories), flows/[id]/runs STATUS_META labels (UI reads Flows.logs), message-thread STATUS_OPTIONS labels
  (used as keys), lib/template-status.ts labels (UI reads Settings.templates.status), lib/automations/trigger-meta TRIGGER_META labels
  (UI reads Automations.list.triggerLabels), errors thrown inside try blocks that are caught and replaced by a catalog toast
  (flows page load/create/delete, runs page, message-bubble media load).
- Brand and already-Spanish copy: "Remesas YA", the promo-banner/notifications promo texts, conversation-list hide/pin texts,
  ownership-icon labels, the Calculadora page.

## Next step
T3: staging build with NEXT_PUBLIC_APP_LOCALE=es and the owner's look (needs the owner's go-ahead for any deploy).

- 2026-10-06 production app: release 555535c (BUILD_ID qeG5ojHkJArkrrcbZdzDj), owner go-ahead "pasalo a produccion". Built in prod-build with Node 20 docker + the production build env (NEXT_PUBLIC_APP_LOCALE=es added, backup .bak-20261006, file untracked): manifest production / hqztotshnlzaiziwjyzh, 114 money-path tests passed, bundle 0 staging refs / 32 production refs, sha256 OK. pm2 wacrm cwd = `current` -> release 555535c, `anterior` -> 225cba2; `/login` 200 on wacrm.onlinefreedom.site serving the new BUILD_ID and "Bienvenido de nuevo" (no "Welcome back"); .next/server has "Borrar todas las notificaciones"; pm2 restarts 25 -> 26 and stable. prod-build left clean at 555535c. Rollback: `infra/deployment/rollback-wacrm-produccion.sh`.

## Follow-up tasks (owner, 2026-10-06: "esos 150 textos corrigelos")
Move the hard-coded user-visible English strings listed under "Follow-up: hard-coded English" into messages/en.json and
messages/es.json (next-intl, same conventions), so the Spanish panel has no English left. Copy only: no behaviour change.
The parity test stays green. Server-returned API errors stay out of scope unless they are shown verbatim in the UI.
- [x] T5 Daily-use screens: inbox (message-thread, message-composer, message-bubble), contacts, notifications page,
  settings (whatsapp-config, members-tab, invite-member-dialog, quick-replies-manager, template-manager, ai-knowledge,
  appearance-panel, profile-form, settings-rail), sidebar, dialog/sheet sr-only "Close", auth pages (signup,
  forgot-password) and join/[token].
- [x] T6 The rest: agents (page, ai-usage, ai-playground), flows (header, flow-editor-shell, node-config-form),
  interactive-builder, broadcasts (steps, pages), automations (page, automation-builder); a final scan for any visible
  English left.
- [ ] T7 Staging deploy + owner's look; production with the owner's go-ahead.

- 2026-10-06 T7 staging deployed (owner's look pending; T7 NOT checked off): release 45d6825ddfedb94d50623d1f195a50816f22e540,
  BUILD_ID fMr_foqZzYI-JEiiUHg6J, same procedure as 555535c (clean prod-build worktree, docker node:20 uid 1000, staging-build.env with
  NEXT_PUBLIC_APP_LOCALE=es, built off oracle2). Manifest staging / kolppplawzdsjfydwejr, 114 money-path tests passed, 0 production
  refs / 32 staging refs, sha256 OK. `current` -> 45d6825, `anterior` -> 555535c; pm2 wacrm-staging cwd = ~/wacrm-releases/current,
  restarts 65 -> 66 and stable; /login 200 on the domain with the new BUILD_ID and "Bienvenido de nuevo"; /forgot-password 200 with
  "Restablecer contraseña" (es.json) and not "Reset password" (en.json). No DB change. Rollback: relink `current` to `anterior`
  (555535c) + `pm2 restart wacrm-staging --update-env`. Production not touched.
