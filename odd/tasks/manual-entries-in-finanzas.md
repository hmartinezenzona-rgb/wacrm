# Feature: manual calculator lines count in Finanzas; fresh start with Osmany's week

## Objective
Every business operation shows in Finanzas, manual and automatic: the manual lines typed in the Calculator become
ledger entries that Finanzas, the dashboard and the closes count next to the bot's entries. Then production starts
from zero with only Osmany's manual list for this week (Tue 2026-10-06 and Wed 2026-10-07).

## Owner request (2026-10-07, task sent by Osmany)
"Borrar todo el historial de transferencia, poner lo que él llevaba manualmente y empezar de cero a partir de mañana,
salvo ya con los datos en historial de esta semana." Clarified: delete the operations' data so they do not add up;
count only with Osmany's data; the consumed receipts must stay consumed; also clean the completed operations in the
customers' chats. Where his data count: "2: ya que son operaciones del negocio, todo debe salir en Finanzas, manual y
automáticas".

## Current state (mapped)
- Manual lines are client-parsed text (src/lib/calculator/web-calculator.ts procesarTexto), stored only as
  remittance_calculator_documents.raw_text (one row per account, autosaved through crm_guardar_documento_calculadora);
  they count in the Calculator totals and nowhere else. remittance_calculator_entries allows source 'manual' (095) but
  nothing writes it; void_shape_chk (104) needs operation_id for a void; guard 149 forbids DELETE and most UPDATEs of a
  completed row; the service CHECK (213:48) lists the ledger services.
- Finanzas = crm_cierre_financiero (142:472 or later), source 'completed_operation', status completed per Guyana day;
  dashboard (src/lib/dashboard/queries.ts 206-228) reads entries with status <> void and entry_date; business insights
  and GET /api/calculator/entries also read the table.
- The Calculator GET (route.ts) shows chat entries from calculator_current_entries (227, source completed_operation).
- Osmany's list parses with the page's parser: 31 lines, no errors, facturado 1,157,712.4, invertido 1,023,917.64,
  retorno 133,794.76 (ZELLE, CLASICA, CUP, USDT, TRÁMITES / COMBOS / SERVICIOS).

## Design (Claude defaults, stated to the owner)
A. Manual lines as ledger entries:
- The page keeps its text editor. On save the client also sends the parsed manual lines (structured: day label,
  resolved date, customer, service, amount + currency, facturado, invertido, retorno, raw line, position); one RPC
  replaces the account's manual entries OF THE CURRENT WEEK (those not archived by a weekly cut) with that set, in one
  transaction, idempotently. Lines with a parse error are not materialised.
- Date of a line: its day header ("Martes 6") resolved to the matching date of the current week (the most recent date
  with that day number not after today, Guyana time); no header -> the day it is saved.
- Entries: source 'manual', status completed, operation_id NULL, service names mapped to the ledger vocabulary (extend
  the CHECK where the manual calculator has services the ledger lacks, e.g. USDT, TRAMITES), actor = the saver.
  Guard 149 lets the sync RPC (and only it) replace manual rows.
- Finanzas (crm_cierre_financiero) and every history reader count manual completed entries next to
  completed_operation ones, and show which are manual. The Calculator's chat list keeps showing only bot entries (the
  manual ones are the text itself), so nothing is counted twice inside the Calculator.
- Weekly cut (227): the week's manual entries stay in the ledger (history keeps counting them); the next week starts
  with no manual entries; an archived week shows what it shows today.
- Known rule (told to the owner): an operation the bot registers must not also be typed by hand, or it counts twice.
B. Production fresh start (data task, owner-authorised, after A is in production):
- Backup; dry run with exact counts; then in one guarded transaction: delete every calculator entry; delete closed
  operations (completed and cancelled) with their recipients, proofs and receipts; clear the bot's stale quotes and
  open objectives of conversations with no open operation (the closed operation was the bot's boundary for a 6-24 h
  window); keep the 3 open operations, contacts, conversations, messages, comprobantes_hashes, depositos_mmg (consumed
  marks must be identical before and after), rates, audit rows.
- Then load Osmany's list as the Calculator text of the week (period label for the week of 2026-10-06), which
  materialises the 31 manual entries dated 2026-10-06 and 2026-10-07.

## Constraints
- Staging first; production only with the owner's go-ahead after the dry-run counts.
- Existing bot entries, closes, weekly cut and deletion (226) keep working; assertions prove it.

## TDD
Strict TDD on. Runners: staging assertions via psql-staging.sh (BEGIN ... ROLLBACK, as is and with no promo); vitest.

## Tasks
- [x] T1 DB (migration 228 + ROLLBACK, staging): manual entries model, sync RPC, guard exception, Finanzas and
  history readers include manual; RED assertion manual-entries.sql then GREEN; regressions.
- [x] T2 App: page sends parsed lines on save, date resolution, Finanzas/close UI shows manual entries, dashboard;
  vitest RED/GREEN; typecheck, lint, full suite.
- [ ] T3 Staging deploy + owner's look (with Osmany's list loaded on staging as a rehearsal).
- [ ] T4 Production: migration + app.
- [ ] T5 Production fresh start: backup, dry run shown to the owner, wipe, load Osmany's list, verify.

## Progress
- 2026-10-07 document created after mapping and the owner's decisions.
- 2026-10-07 T1 done (commit 74d97af): migration 228 applied on staging (schema_migrations 228). T2 done (commit 852f2e3).
  Osmany's list loaded on staging as a rehearsal (see Evidence). T3 (deploy to staging and the owner's look) is next.

## Evidence
T1 (staging DB):
- RED: manual-entries.sql failed before 228 (column line_position / function missing). GREEN after: 7 cases PASS (sync replace /
  idempotent / remove / change / empty; 17 invalid payloads 22023 with nothing written, viewer / other account / no session 42501,
  anon cannot execute; Finanzas totals, per-service, per-day and detail count and mark manual rows and equal the bot-only close
  when there are none; the Calculator view lists only bot entries; weekly cut keeps the closed week's manual rows and a later
  sync cannot touch them, archived week unchanged; raw UPDATE / DELETE refused, chat delete and correct still 22023; all nine
  manual services accepted).
- Round trip in one rolled-back transaction: 228 + assertion + ROLLBACK-228 restored crm_cierre_financiero
  (b8ea2475...) and the guard (c7c9bd08...) to the exact pre-228 md5s, dropped the RPC and both columns. The rollback refuses
  while manual entries exist (observed: the assertion leaves the archived week's manual rows, so the first attempt was refused).
- crm_cierre_financiero before/after on the staging account for 3 date ranges: md5 of the jsonb identical once the new 'source'
  key is stripped (pre-228 snapshot taken before applying).
- Unchanged functions re-checked by md5: crm_cerrar_semana_calculadora, crm_guardar_documento_calculadora,
  crm_eliminar_entrada_calculadora, crm_corregir_entrada_calculadora (same as the 228 header).
- Regressions as is and with promos discarded, all PASS: financial-close, calculator-entry-delete, calculator-weekly-cut,
  calculator-entry-correction, feed-matrix, resolve-pending, calculator-recarga, calculator-access, calculator-entries-realtime,
  saldo-model, combo-model, visa-model, recarga-model, rate-versions, operations-board. feed-mixed (case 5 and case 6) and
  delivery-feed-evidence (fixture setup) fail exactly as before; feed-mixed re-run with 228 rolled back gives the same two
  failures, so they are not 228's.
T2 (app): vitest RED then GREEN for date resolution (manual-entries.test.ts), POST /api/calculadora and /weeks routes, page
  autosave payload / cut / error banner, Resumen detail badge, CSV origin, read model, dashboard query; typecheck clean; eslint
  clean on touched files; full suite 172 files / 2251 tests pass (--testTimeout=20000).
Rehearsal on staging (account 472917ed, owner feeccc91): the list went through crm_guardar_documento_calculadora then
  crm_sincronizar_entradas_manuales with the lines produced by manualEntriesFromText (today = 2026-10-07; 24 lines on 2026-10-06,
  7 on 2026-10-07; period label "SEMANA 06/10/2026"). crm_cierre_financiero(2026-10-06, 2026-10-07): manual part 31 entries,
  facturado 1,157,712.40, invertido 1,023,917.64, retorno 133,794.76 (= parser totals); the staging account's bot entries on those
  dates: 4 operations, 135,000 / 97,500 / 37,500; the close shows 35 operations, facturado 1,292,712.40, invertido 1,121,417.64,
  retorno 171,294.76 (the sum of both). The data stays on staging.

## Decisions beyond the defaults
- No service CHECK change: all nine services the manual calculator produces are already in the ledger CHECK. The parser's direct
  lines (visa, ext, trabajo, estudiante, trad, combo, pasaje) map to DIRECTO, whose label is "Trámites / Combos / Servicios";
  "SALDO MOVIL" maps to SALDO_MOVIL. Which direct service it was lives only in raw_line. Manual currencies follow the bot's:
  CUP -> CUP, RECARGA / SALDO_MOVIL -> REC, DIRECTO -> GYD, the rest USD.
- Identity of a manual row = line number in the text. source_event_id = 'manual:<cycle>:<position>' where cycle = number of weekly
  cuts so far; a cut moves the account to a new key space, so a later sync cannot match, update or delete a closed week's rows.
  The cut (227) is NOT modified. New nullable columns line_position and raw_line.
- completed_at = midday of the line's Guyana day, so the close files it on that day.
- The chat delete (226) refuses manual entries (22023, "only a chat-fed entry can be deleted here"): a manual line is edited
  from the text. The correction (149) keeps refusing them. Raw UPDATE / DELETE need the GUC wacrm.calculator_manual_sync that
  only the sync RPC sets.
- crm_cierre_financiero: operaciones = distinct operations + manual entries; every detail / excluded row carries 'source'.
- Route order: the document is saved first, then the sync, so a bad line never loses the text. If the sync fails the response
  has documentSaved true / entriesSynced false, the page shows an error and retries after 15 s or on the next edit.
  The weekly-cut route syncs the closing week's lines first (the autosave may lag the textarea) and cuts only if that worked.
- Lines the ledger cannot hold (unknown service, amount 0, negative figures) are not sent; the page says "N líneas no se
  registran en Finanzas". Old pages that send no manualLines leave the entries alone.
- A day header resolves to the most recent date with that day number AND that weekday (no match within 400 days: today).
  A header for a future day ("Jueves 8" typed on the 7th) therefore resolves to an old date; the sync accepts dates up to 400
  days back and 1 day ahead.
- The page's `tarifa` is an autosave dependency: a new CUP global rate re-syncs the CUP lines' figures.
- Dashboard: loadLedgerProfit reads the bot's and the manual entries (top clients, currency breakdown).
- CSV export gains an `origen` column (automatica / manual).

## Open points / not verified
- No browser: the Calculator page, the manual badge in /resumen and the error banner were verified only through jsdom tests.
- First page open after the deploy autosaves the stored text and so materialises it (intended); this also happens with any
  text a user has today.
- A request of the old text that is still in flight when a cut lands can write it into the new week (same as the document
  today); the abort on "Limpiar Todo" covers the normal case.
- Production wipe (Part B) and T3-T5 are not part of this change.

## Next step
T3: deploy to staging and the owner's look at Calculator, /resumen and the dashboard with Osmany's week.

- 2026-10-07 parent review of the date rule: the writer's resolver looked 400 days back, and its tests pinned
  "Lunes 6" (typed on Wed 7 Oct, the 6th being a Tuesday) -> 6 July: a mistyped weekday, or a header written ahead of
  time, would date a day's lines months back, outside the week Finanzas shows. Changed (weekly record): look back 14
  days only; the exact weekday + number match first, then the number alone; otherwise today. RED 2 failed, GREEN
  calculator lib + page + API 17 files / 335 tests; tsc and eslint clean.

- 2026-10-07 T3 staging deploy (owner's look pending, T3 stays unchecked): release 75e3a2c
  (75e3a2cd4ea9b4c207ace7ceafb61ddee5f37824), BUILD_ID 8VQ-2ehjwlkQbtamn1dK0, built in docker node:20 from the clean
  prod-build worktree with staging-build.env (locale es), manifest environment=staging, 0 production refs, 32 staging
  refs, 114 money-route tests passed; deployed to oracle2 staging only, pm2 wacrm-staging cwd = the new release,
  /login 200 with the new BUILD_ID, the Calculator notice chunk served from crm.onlinefreedom.site. Rollback: relink
  `current` to the 7db1561 release (`anterior`) and `pm2 restart wacrm-staging --update-env`.
