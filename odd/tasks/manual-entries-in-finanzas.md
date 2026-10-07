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
- [ ] T1 DB (migration 228 + ROLLBACK, staging): manual entries model, sync RPC, guard exception, Finanzas and
  history readers include manual; RED assertion manual-entries.sql then GREEN; regressions.
- [ ] T2 App: page sends parsed lines on save, date resolution, Finanzas/close UI shows manual entries, dashboard;
  vitest RED/GREEN; typecheck, lint, full suite.
- [ ] T3 Staging deploy + owner's look (with Osmany's list loaded on staging as a rehearsal).
- [ ] T4 Production: migration + app.
- [ ] T5 Production fresh start: backup, dry run shown to the owner, wipe, load Osmany's list, verify.

## Progress
- 2026-10-07 document created after mapping and the owner's decisions.

## Next step
T1.
