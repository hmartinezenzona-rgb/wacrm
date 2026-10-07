# Feature: delete a calculator entry, and "Limpiar todo" as a weekly cut that keeps the history

## Objective
(A) An admin can delete a calculator entry even when it is completed: it stops counting everywhere and never comes
back. (B) "Limpiar todo" starts a clean week in the Calculator without losing history: everything cleared keeps
counting in Finanzas, and the cleared week can be opened again, read-only.

## Owner request (2026-10-07; A is Osmany's request)
"En la calculadora quiero que se pueda eliminar una entrada aunque ya esté completada. Al dar en 'limpiar todo' se
limpie todo de ahí; Osmany lo hace al final de la semana para empezar limpio, pero que mantenga el historial. Si él
específicamente da en borrar una operación, que ya no cuente; pero limpiar todo sí siga contando."
Manual text on clear: "Guardar copia consultable".

## Current state (mapped 2026-10-07)
- "🧹 Limpiar Todo" (calculadora/page.tsx ~614, clearAll ~393-401) only empties the manual text and the period label
  (localStorage + remittance_calculator_documents through the autosave); the text is lost (only the .txt export keeps
  it). Chat entries are never cleared: GET /api/calculadora (route.ts 97-111) returns every non-void
  completed_operation entry of the account, with no date or cut filter.
- Finanzas (crm_cierre_financiero, 142:472), the dashboard and business insights read remittance_calculator_entries
  directly, so a cut applied only to the Calculator view leaves history intact.
- Entries: guard 149 forbids DELETE of a completed row and allows completed -> void with the figures unchanged. A void
  row is REVIVED by calculator_feed_operation (223:1267-1291, ON CONFLICT ... WHERE status = 'void') on re-completion,
  crm_feed_calculator and combo-cost changes; calculator_unfed_operations lists an operation with no non-void entry.
- Per-entry actions today: edit figures (admin, crm_corregir_entrada_calculadora). No delete.
- Manual lines are client-parsed text; they never become entries and do not count in Finanzas.

## Design (Claude defaults, stated to the owner)
A. Delete = durable void:
- remittance_calculator_entries.deleted_at (+ deleted_by); RPC crm_eliminar_entrada_calculadora(p_entry_id) (admin+,
  SECURITY DEFINER): completed or verified_pending completed_operation entry -> status void, voided_at, void_reason
  'deleted by <actor>', deleted_at; figures untouched; one audit row (new audit action).
- calculator_feed_operation never revives a row with deleted_at; calculator_unfed_operations does not list an operation
  whose entries were deleted on purpose. The linked operation is not touched.
- UI: a trash icon next to the pencil (admin only), confirmation dialog, then the line disappears (realtime). Finanzas
  keeps showing it under "excluidas" with the reason "eliminada por ...".
- No undo in this step.
B. "Limpiar todo" = weekly cut + archive:
- Table of weekly cuts per account (cut_at, cut_by) with the archived week: manual text, period label, totals
  (facturado / invertido / retorno, manual and chat parts) and the list of chat entry ids or a rendered summary, enough
  to show that week again read-only.
- RPC crm_limpiar_calculadora (same role that can clear today: agent+): archives, records the cut, empties the document.
  The Calculator shows only entries completed after the latest cut; verified_pending lines older than the cut stay
  visible (they still need a price). History readers are unchanged.
- UI: "Limpiar todo" calls the RPC (confirmation kept, clearer text: the week is archived, history keeps counting);
  "Semanas anteriores" list opens an archived week read-only (text, period, totals, entries).

## Scope
DB migration 226 (+ ROLLBACK-226, staging first), app (Calculator page, routes, read model, realtime filter), i18n,
tests. Out of scope: manual lines counting in Finanzas; undoing a deletion; the bot.

## Constraints
- Finanzas, dashboard and closes must give the same numbers before and after a "Limpiar todo" (assert it).
- A deleted entry never returns through the feed (re-completion, replay, combo cost).
- Production only with the owner's go-ahead.

## TDD
Strict TDD on. Runners: staging assertions via psql-staging.sh (BEGIN ... ROLLBACK, as is and with no promo); vitest.

## Tasks
- [ ] T1 DB delete: RED assertion calculator-entry-delete.sql; migration 226 part A on staging; GREEN; regressions.
- [ ] T2 DB weekly cut: RED assertion calculator-weekly-cut.sql; migration 226 part B (or 227); GREEN; regressions.
- [ ] T3 App: trash button + dialog; "Limpiar todo" through the RPC; cut filter; "Semanas anteriores"; tests.
- [ ] T4 Staging deploy + owner's look.
- [ ] T5 Production with the owner's go-ahead.

## Progress
- 2026-10-07 document created after mapping.

## Next step
T1.
