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

## Owner look on staging (2026-10-07, release 75e3a2c): the display is wrong for what he wants
- "Cambiaste cómo se ve la calculadora, no te pedí eso; lo de borrar entradas y editar se queda así como estaba antes,
  con la fecha en este formato" (he pasted the "Operaciones del chat" table: Fecha, Cliente, Monto, Tipo, Estado,
  Fact., Inv., Ganancia, Acciones). Then, about "🔍 Auditoría de Operaciones por Día": "¿esto es nuevo en staging? si
  es así no me gusta que esté ahí, sobra".
- Verified: nothing in that table changed, and the "Auditoría" section is NOT new (ported 2026-09-13, commit 6055b3f,
  in every production release); he had never seen it filled because production's manual text has been empty. The
  rehearsal put Osmany's list in the text, so it showed there, with no date column and no actions.
- Owner decision ("sí, hazlo así"): one table for every operation, manual ones included, with date, pencil and trash;
  the "Auditoría" section goes away; the text box only ADDS (a "Registrar" button).

## Design v2 (replaces the "text is the source" part of Design A)
- Manual entries are first-class ledger rows (source 'manual'), no longer a mirror of the text:
  - the text box is an input: the person types lines in the usual syntax, presses "Registrar"; the valid lines become
    entries (date from the day header resolved by the weekly rule, else today) and leave the box; lines that cannot be
    interpreted stay in the box with the existing warning. Nothing is registered by the autosave.
  - RPC to ADD manual entries (append, no replace); the "sync/replace" RPC and its key scheme go away.
  - Pencil: crm_corregir_entrada_calculadora also accepts manual entries (same fields it edits today).
  - Trash: crm_eliminar_entrada_calculadora also accepts manual entries (durable void; void_shape_chk relaxed for
    manual rows, which have no operation).
  - The Calculator view (calculator_current_entries and the realtime handler) lists manual entries of the open week
    next to the bot's; the weekly cut archives them with the week and they keep counting in history.
- Calculator page: remove the "🔍 Auditoría de Operaciones por Día" card. The entries table keeps EXACTLY its columns
  and look (Fecha YYYY-MM-DD, Cliente, Monto, Tipo, Estado, Fact., Inv., Ganancia, Acciones) and its inline
  edit/delete; its title becomes "Operaciones"; manual rows carry a small "Manual" mark. Totals and the service
  breakdown come from the entries shown (bot + manual). The weekly close text export and "Semanas anteriores" follow.
- Finanzas, dashboard: unchanged from T1/T2 (manual counted, "Manual" badge).
- Migration 228 is on staging only: amend it in place and re-apply (no 229).

- [x] T2b Rework to Design v2 (DB amend 228 + app) and staging rehearsal with Osmany's 31 lines as 31 rows (24 on 2026-10-06,
  7 on 2026-10-07): done 2026-10-07, commits 2fdbf7a (DB) and d558c29 (app); evidence below. Not deployed yet.
- [ ] T2c Staging deploy of the v2 release and the owner's look (T3 stays open until he has seen it).

## T2b evidence (2026-10-07, staging only; no production, no deploy, no push, no n8n)
DB (migration 228 amended in place, commit 2fdbf7a):
- Return to pre-228: the HEAD ROLLBACK-228 ran on staging in one transaction after removing the rehearsal's 31 manual rows (staging
  only; the guard was opened with its own GUC for that one DELETE) and deleting the schema_migrations row 228. Restored md5 match the
  old header: crm_cierre_financiero b8ea2475..., guard c7c9bd08....
- Pre-228 definitions captured for the new ROLLBACK (md5 equal to the old header): cut 3a046742..., corrector dfbd1eb1..., deleter
  81ef8a23..., view f7cc9fe7..., audit CHECK 5b3ffc19..., void_shape_chk and source_shape_chk text.
- RED: the new manual-entries.sql against the old 228 (git HEAD~) failed at once: `function crm_registrar_entradas_manuales(uuid, jsonb)
  does not exist`. GREEN against the amended 228: 9 cases PASS (add / validation / read / correct / delete / guard / cut / Finanzas / services).
- Round trip in one rolled-back transaction (amended 228, then the new ROLLBACK): the md5 of the six functions, the view, the two CHECKs,
  the audit CHECK, the column list and the ACLs are identical to the pre-228 snapshot. Real apply: schema_migrations row 228 once.
- Existing assertions, as is and with promos discarded, all PASS: financial-close (forced-rollback wrapper), calculator-entry-delete,
  calculator-weekly-cut, calculator-entry-correction, feed-matrix, resolve-pending, calculator-recarga, calculator-access,
  calculator-entries-realtime, saldo-model, combo-model, visa-model, recarga-model, rate-versions, operations-board (the five that end
  with `RAISE EXCEPTION 'ALL PASS ...'` are meant to).
App (commit d558c29): vitest RED then GREEN per layer (lib, routes, page); tsc clean; eslint clean on touched files; full suite 173 files /
  2292 tests pass (--testTimeout=20000).
Rehearsal (staging account 472917ed, owner feeccc91): the list went through crm_registrar_entradas_manuales as the app builds it
  (manualEntriesFromText, today 2026-10-07, CUP rate 3): 31 rows (24 on 2026-10-06, 7 on 2026-10-07), 31 audit rows, the document text
  EMPTY and the period "SEMANA 06/10/2026". calculator_current_entries: 31 completed rows, facturado 1,157,712.40, invertido
  1,023,917.64, retorno 133,794.76 (all manual; the account's 4 bot entries of those days were archived by earlier staging cuts).
  crm_cierre_financiero(2026-10-06, 2026-10-07): 35 operations, facturado 1,292,712.40, invertido 1,121,417.64, retorno 171,294.76 =
  manual part (31; 1,157,712.40 / 1,023,917.64 / 133,794.76) + bot part (4; 135,000 / 97,500 / 37,500); per day 25 and 10 operations.

## T2b decisions (reasons)
- Add RPC `crm_registrar_entradas_manuales`: all or none, agent+, 500 lines at most, date within the last 60 days and at most tomorrow
  (a weekly record; the old sync allowed 400), returns the created rows in the order sent (created_at = clock_timestamp() per row keeps
  the order), one audit row per entry ('human_calculator_manual_added', new value in the audit CHECK). It is an add: the same lines
  twice are added twice; the page removes what it registered.
- Dropped with the sync: `line_position`, the `manual:<cycle>:<position>` key scheme, the sync GUC. Kept: `raw_line`.
- Guard: a manual row changes only with `wacrm.calculator_correction` (the corrector) or the new `wacrm.calculator_manual_delete` (the
  deleter); account, date, customer, day label, raw line, completed_at and currency never change; a void manual row never changes again.
  source_shape_chk also had to allow `void` for a manual row (found by the first assertion run), as void_shape_chk.
- Weekly cut: signature is now (account, text, period). chat_totals = the bot's entries, manual_totals = the manual entries, both
  computed in SQL; the snapshot carries each entry's `source`. The old six-argument function is dropped (the ROLLBACK recreates it).
  Weeks cut before this change keep their shape and open as before (source absent = bot).
- Page: title "🔗 Operaciones"; "Registrar" sits in the header row of the text-box card (next to "Maximizar") so the bullet button and the
  box do not move; uninterpreted lines show as "⚠️ No interpretado" under the box (the text the removed card used); the box is read-only
  while registering; the registered rows are inserted by date (newest day first) and deduplicated against the live channel; a manual
  row's realtime cut check uses created_at (completed_at is the typed day). Export lists the table rows with their date and "(manual)"
  and the draft section only while text remains.
- Amount text: a DIRECTO row reads "4000 GYD", saldo packages typed by hand read "2 SALDO MOVIL"; the breakdown names DIRECTO "TRÁMITES /
  COMBOS / SERVICIOS" like the old parser.

## T2b existing expectations that changed (and why)
- calculator-entry-delete.sql case 8: "a manual entry must be refused (22023)" became "an agent must not delete a manual entry (42501)"
  and a new case 11 asserts an admin deletes it (durable void). Reason: manual rows are deletable now.
- calculator-entry-correction.sql case 5: "a manual entry is refused (22023)" became "it is corrected like a chat-fed one". Same reason.
- calculator-weekly-cut.sql: the cut takes three arguments; "manual totals stored as sent" became "zero manual totals when there are no
  manual entries"; the missing/out-of-range manual-total refusals and the anon check use the new signature. Reason: totals are SQL now.
- page.test.tsx: "combines only completed snapshots" no longer adds the draft text's totals (the draft is not an operation); the autosave body
  has no `manualLines`; the cut body has no manual totals or lines; the T2 tests of the sync path were replaced by the registration tests.
- route tests: POST /api/calculadora and /weeks no longer sync; manual-entries.test.ts: `position` and the sync shape are gone.

## T2b open points / not verified
- No browser: the page, the Registrar flow, the pencil/trash on manual rows and the archived week were verified through jsdom tests and
  the staging database only; the owner's look comes after the staging deploy (T2c).
- Staging runs release 75e3a2c until redeployed: with the amended DB applied, that old release's autosave and cut (they call the
  removed sync RPC and the six-argument cut) fail against staging until T2c deploys the new release.
- The audit rows of manual additions make the ROLLBACK refuse as well (like the entries themselves).
- Production (T4/T5) is untouched; the production fresh start must now load Osmany's list through the add RPC, not the document.

## Next step
T2c: build and deploy this release to staging (owner-authorised path) and ask for his look at the Calculator (one table with Registrar), /resumen and the dashboard.

- Staging deploy (release 8fb2b6d, BUILD_ID tSS8ThRJRzCy1beEsy9Wl, app commit d558c29): manifest environment=staging, 0 production refs, 32 staging refs, 114 build tests passed, pm2 cwd = new release, /login 200 with "Bienvenido de nuevo", Calculator chunk `_next/static/chunks/0k5xnzh_c9p-l.js` served by crm.onlinefreedom.site identical to the build (has "Registrar" and "🔗 Operaciones", no "Auditoría de Operaciones por Día"), restarts stable at 80. Rollback: anterior -> 75e3a2c. T2b look pending (owner).
