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
- [x] T1 DB delete: RED assertion calculator-entry-delete.sql; migration 226 on staging; GREEN; regressions. (c0f3883)
- [x] T2 DB weekly cut: RED assertion calculator-weekly-cut.sql; migration 227 (separate from 226) on staging; GREEN; regressions. (5e76733)
- [x] T3 App: trash button + confirmation; "Limpiar todo" through the RPC; cut filter; "Semanas anteriores"; tests. (dd943a6) Not seen in a browser.
- [x] T4 Staging deploy + owner's look.
- [x] T5 Production with the owner's go-ahead.

## Decisions beyond the defaults
- Migrations split: 226 = delete, 227 = weekly cut (one reviewable unit and one rollback each). Both applied on staging
  only (schema_migrations 226, 227).
- The new cut RPC is crm_cerrar_semana_calculadora, NOT crm_limpiar_calculadora: that name already exists on staging
  (crm_limpiar_calculadora(uuid), admin-only, writes remittance_calculator_clearances; no migration in the repo creates
  either, the app never calls them). Left untouched; a new name avoids overloading the old RPC and any dependence on
  unknown production rows in the legacy clearances table.
- Cut read path = a view, not a cut_at filter: calculator_current_entries (security_invoker) = completed_operation, not
  void, not archived (table remittance_calculator_week_entries, entry_id PK). Why: a cut_at rule (completed_at > cut OR
  pending) makes a pending line vanish from the Calculator once resolved after the cut (its completed_at is old) and it
  would be in no archive. With "archived entries" a pending line is never archived, so it stays whatever its age and
  resolved. route.ts only changes the table to the view; GET also returns cutAt (latest week) for the realtime filter,
  which ignores a NOT-shown completed entry with completed_at <= cutAt. Known edge: an operation whose transaction
  started before the cut but committed after has completed_at <= cutAt; the DB view shows it, live events do not until
  the next reload.
- The RPC takes the text, period and manual totals from the client (the autosave can lag the textarea) and computes the
  chat totals and the entry snapshot in SQL from what the Calculator view shows at the cut (not from client-sent ids).
  An entry completed between page load and the click is therefore archived even if the page did not show it yet.
- Archive = remittance_calculator_weeks (cut_at, cut_by, raw_text, period_label, manual_totals, chat_totals, entries
  snapshot); RLS select for members, no client write; any agent+ may cut; viewers refused.
- Delete: admin+ RPC; the page shows the trash button to everyone who sees the pencil (the page has no role state; the
  server returns 403 and the page says only an administrator can delete), for completed and pending lines.
- Confirmations use window.confirm like the page's existing "Limpiar Todo" (the page is a hard-coded-Spanish legacy
  screen, no next-intl provider, no repo Dialog); copy is hard-coded Spanish like the rest of the page, so
  messages/en.json and es.json are unchanged.
- GET /api/calculator/entries (generic ledger listing, no caller in the app) is intentionally NOT cut-filtered: it is
  a history reader.
- Rollbacks: ROLLBACK-226 refuses (changes nothing) when a deleted entry or a deletion audit row exists;
  ROLLBACK-227 refuses when an archived week exists.

## Evidence (staging, 2026-10-07)
- T1 RED: calculator-entry-delete.sql before 226 -> "case 1: the admin delete failed with 42883" (function missing).
  GREEN after 226: PASS 1-10 + ALL PASS.
- T2 RED: calculator-weekly-cut.sql before 227 -> relation "calculator_current_entries" does not exist.
  GREEN after 227: PASS 1-8 + ALL PASS. Finanzas equality (case 4): crm_cierre_financiero(today, today) of the same
  account taken before and after the cut is the SAME jsonb (IS NOT DISTINCT FROM), with the archived lines in
  `detalle`; the cut also leaves the E1/E2/void entry rows byte-identical.
- Round trips (one rolled-back transaction each): 226 apply -> rollback: md5 restored for calculator_feed_operation
  (7f985d9d6adeaee998e3a246a530a5e8), calculator_unfed_operations view (cd475518e23ac05d71659378d1ef33fe) and the audit
  action CHECK (3da4b785eea18913c4bca6b65c9927bb), function and columns gone. 227: three objects + function gone after
  rollback (nothing redefined). Real apply: 226 (feed md5 after ebd19f921ab0b66f8fcb2770b0d5c543), 227; anon cannot
  execute either RPC, authenticated can.
- Regressions after 226 and again after 227, as is AND with promos discarded: calculator-entry-correction, feed-matrix,
  combo-deposit-calculator, visa-model, combo-model, recarga-model, saldo-model, resolve-pending, calculator-recarga,
  calculator-access, calculator-entries-realtime, financial-close, rate-versions, operations-board, and both new
  assertions: all pass. feed-mixed (case 6, "close must count the mixed op once, got 2" + one more) and
  delivery-feed-evidence (fixture setup: no operation created for the deal) FAIL IDENTICALLY with 226 rolled back inside
  the transaction, so they are pre-existing and unrelated to this change; they need their own look.
- Staging left clean (0 weeks, 0 deleted entries, no fixture accounts).
- T3: vitest RED first (28 failing in the new route/lib files, 16 in the page), then GREEN; full suite
  `npx vitest run --testTimeout=20000`: 170 files, 2194 tests pass; `tsc --noEmit` clean; eslint on the touched
  directories clean.

## Not verified
- No browser: the page was only exercised through jsdom. The delete button, the confirmation texts, the "Semanas
  anteriores" card and the read-only week view have not been looked at (layout of the Acciones column with two icons in
  particular).
- Realtime with a real channel (only the handler is tested); production not touched; no n8n.

## Progress
- 2026-10-07 document created after mapping.
- 2026-10-07 T1, T2, T3 done on staging/branch (commits c0f3883, 5e76733, dd943a6). Nothing pushed.
- 2026-10-07 T4 staging deployed: release 15e3002838d08bba58da36ab8a7582d2a299759c (app dd943a6), BUILD_ID IQYVehOfutCkkeO0ty_2V, manifest staging, 0 production refs, build tests 114 passed, login 200, delete route 401 without session, bundle has "Semanas anteriores", pm2 restarts 76->77 stable. Rollback: anterior -> e54f2ea. Owner's look pending; T4 not checked.
- 2026-10-07 T3b staging deployed (app 7db1561): release 7db1561a8ee3a01b6ebebbf4c3ed7bb49e693298, BUILD_ID ngnIEczyMZrCjBhfEaeyG, manifest staging, 0 production refs (32 staging), build tests 114 passed, login 200 with the new BUILD_ID and "Bienvenido de nuevo", chunk `_next/static/chunks/0i13guu332z_q.js` contains "¿Eliminar?" in the release and as served by crm.onlinefreedom.site, pm2 restarts 77->78 stable. Rollback: anterior -> 15e3002. Owner's look pending; T4 not checked.

## Next step
T4: staging app deploy and the owner's look (including the Acciones column and the weeks card). T5 production with the owner's go-ahead: apply 226 then 227 (rollbacks ready).

## Owner look on staging (2026-10-07, release 15e3002)
"Ya sale, pásalo a producción, pero antes: la notificación que sale para confirmar al momento de borrar se ve fea, poco
profesional." (It is the browser's window.confirm.) Choice: "✓ / X en la fila".

- [x] T3b Confirmations without window.confirm (done 2026-10-07, app only, not deployed):
  - Delete an entry: inline in the row. The trash turns that row's actions into "¿Eliminar?" with X (cancel) and ✓
    (confirm), same icon-button style as the page's pencil/trash; Escape or X cancels; only one row asks at a time; while
    deleting the ✓ shows a pending cue; errors stay in the row as today.
  - "Limpiar Todo": the app's own dialog (repo Dialog component) with a short title, the text that the week is archived
    in "Semanas anteriores" and the history keeps counting, and Cancel / confirm buttons; no window.confirm.
  - Entry edit row: the "Guardar" / "Cancelar" text buttons become ✓ / X (aria-label + title kept), for consistency.
  - Evidence: vitest RED first (18 failing in page.test.tsx), then GREEN: calculadora page + src/lib/calculator 251
    tests; full suite `npx vitest run --testTimeout=20000` 170 files, 2202 tests pass; `tsc --noEmit` clean; eslint on
    the page directory clean. No window.confirm left in page.tsx; tests assert the spy stays uncalled.
  - The repo Dialog is driven in jsdom as is (wrapped in NextIntlClientProvider in the test render, since the root layout
    provides it in the app); no mock. It renders in a portal on body, outside `.legacyCalc`, so the legacy button CSS
    does not reach it (asserted: the dialog is not inside `main`); no CSS change needed.
  - Not verified (no browser): look of the inline confirmation (one-line Acciones cell, destructive accent on the check)
    and of the dialog in light/dark.

## Production app (2026-10-07, owner: "pasalo a produccion" after checking staging; T4 checked)
- Release 7db1561a8ee3a01b6ebebbf4c3ed7bb49e693298, BUILD_ID hXt4pZDKPqL0Z3XV02gX6, same procedure as e54f2ea (clean prod-build, docker node:20 uid 1000, production build env, build-wacrm.sh, desplegar-wacrm-produccion.sh from prod-build). Logs: build-prod11.log, deploy-prod11.log.
- Build tests 114 passed; manifest environment=production, project hqztotshnlzaiziwjyzh; 0 staging refs, 32 production refs; pm2 process cwd is the new release; anterior -> e54f2ea.
- Served (curl -k): /login 200 with the new BUILD_ID and "Bienvenido de nuevo"; POST /api/calculator/entries/<zero-uuid>/delete without session 401; chunk `_next/static/chunks/0i13guu332z_q.js` contains "¿Eliminar?" in the release and as served; pm2 restarts 30 -> 30 stable.
- INCIDENT, unrelated to the release: the TLS certificate of wacrm.onlinefreedom.site expired 2026-10-07 21:15 GMT (Let's Encrypt, not renewed), so without -k curl fails (000) and the deploy script's served-BUILD_ID check reported failure (exit 1) although the release is live. No rollback (it would not fix it). Needs certificate renewal on oracle.
- Rollback: ./infra/deployment/rollback-wacrm-produccion.sh (anterior -> e54f2ea).

- 2026-10-07 T5 PRODUCTION DB (owner: "pasalo a produccion"), migrations 226 + 227 in one transaction:
  - Backup ~/wacrm-respaldos/produccion-20261007T215209Z.dump (sha256 91f4f124e95cdb9f...).
  - Pre-check: calculator_feed_operation 7f985d9d..., calculator_unfed_operations cd475518..., audit CHECK 3da4b785...
    (= ROLLBACK-226 header); no new objects; last migration 225.
  - ~/cerebro-fase1/pruebas/gate125-aplicar-db.py with temporary zz_wu5b_exec. Fingerprint: ensayo
    `feed=ebd19f92... unfed=8d1c5f95... auditchk=5b3ffc19... cols=2 fns=crm_cerrar_semana_calculadora:3a046742...,crm_eliminar_entrada_calculadora:81ef8a23... view=f7cc9fe7... tables=2`
    = staging exactly; ida-y-vuelta = production before; aplicar OK (schema_migrations 20261007215443 226,
    20261007215444 227).
  - probar (forced rollback), 13 assertions pass: calculator-entry-delete, calculator-weekly-cut,
    calculator-entry-correction, feed-matrix, resolve-pending, calculator-recarga, saldo-model, combo-model,
    visa-model, recarga-model, calculator-access, rate-versions, operations-board.
  - After: helper dropped; 85 live entries, all 85 in the Calculator view, 0 deleted, 0 archived weeks; anon cannot
    execute the delete RPC; 0 leftovers.
- 2026-10-07 production app release 7db1561, BUILD_ID hXt4pZDKPqL0Z3XV02gX6 (anterior e54f2ea). The deploy script
  exited 1 only because its final HTTPS check hit the expired certificate (below); the release was live.

## Incident found during the deploy: production TLS certificate expired (2026-10-07 21:15 UTC)
- wacrm.onlinefreedom.site's Let's Encrypt certificate (issued 2026-07-09) expired at 21:15:30 UTC. certbot.timer had
  run and FAILED since 2026-10-06 ("Challenge failed": http-01 got 404).
- Cause: the server's iptables NAT has `-A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 3000` (twice) and the
  same for OUTPUT to 127.0.0.1, so port 80 never reaches nginx: the ACME challenge is answered by the Next app (404).
- Fix done with the owner's authorization ("si renuevalo"): the two PREROUTING rules were removed in memory only,
  `certbot renew --cert-name wacrm.onlinefreedom.site` succeeded (new certificate valid 2026-10-07 21:12 ->
  2027-01-05 21:12 UTC, nginx reloaded by certbot), and the two rules were put back (trap on exit). After: 2
  PREROUTING + 1 OUTPUT rules as before, nginx -t OK, pm2 wacrm online (restarts 30), /login 200 with a valid chain.
- NOT fixed: the automatic renewal will fail again (next expiry 2027-01-05) until the port-80 redirect stops
  shadowing nginx (options: certbot pre/post hooks that lift and restore the rule, or dropping the redirect so port 80
  reaches nginx's 301). Owner decision pending. Staging certificate (crm.onlinefreedom.site) is valid to 2026-11-18;
  its renewal path was not checked.
- 2026-10-07 22:15-22:23 UTC, permanent fix (owner: "si"), production server only: certbot renewal hooks
  /etc/letsencrypt/renewal-hooks/pre/wacrm-port80-redirect.sh (lifts the port-80 -> 3000 PREROUTING rules, saves the
  count in /run/wacrm-port80-redirect.count) and .../post/wacrm-port80-redirect.sh (puts the same number back, removes
  the file); both log with tag wacrm-certbot. Tested with `certbot renew --cert-name wacrm.onlinefreedom.site
  --dry-run`: "all renewals succeeded", journal "pre hook: lifted 2 ..." / "post hook: ... restored (2)", 2 rules after,
  no state file left; certificate still the one valid to 2027-01-05; /login 200 with a valid chain. If the post hook
  ever fails, port 80 reaches nginx (301 to https), which is harmless.
- Staging (oracle2, crm.onlinefreedom.site) checked read-only: no NAT redirect (port 80 answers nginx's 301),
  snap.certbot.renew runs twice a day and succeeds, certificate valid to 2026-11-18 (renewed once on 2026-08-20). No
  change needed.
