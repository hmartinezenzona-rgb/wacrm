# The operations panel shows the bot's current quote

Objective: before any deposit, the client panel shows what the bot quoted for the remesa ("Cotizado: 5,000 GYD ->
15,000 CUP"), so an operation opened from beneficiary data no longer looks like 0 GYD with nothing asked.

Why (owner, 2026-10-02, after the staging retest of gate 83): the remesa opened with the card shows 0 GYD although the
bot already quoted. `quoted_source_amount` is the DEPOSITED amount (cerebro_registrar_deposito overwrites it with the
total), so the quote cannot go there. Fixing a CUP target the calcular_usd way would create the "deposito de mas"
Incidencia the owner does not want (Engram `remesa/deposit-above-quote-behaviour`). So the panel READS the quote.

Source: `cerebro_cotizacion` (171, both environments): the latest quote per conversation (gyd + the bot's text),
written by a trigger on the bot's messages; valid like `cerebro_cotizacion_vigente` (cotizacion_ventana_horas, after the
last closed remesa). The destination ("*15,000 CUP*", "*100 USD*") is read from that text. `cerebro_ultima_cotizacion`
exists only on staging, so it is not used.

Design: migration 187 `crm_cotizacion_de_conversacion(p_conversation_id)` -> (gyd, destino_monto, destino_moneda,
cotizado_en), SECURITY DEFINER, same 42501 authorization as crm_operaciones_de_conversacion (viewer), read-only. The
API route GET /api/remittance-operations returns it as `quote`; the panel shows it on the open operation.
Scope: staging first, production with go-ahead (DB + app deploy). TDD on: SQL assertion (self-reverting) + vitest.

## Tasks
- [x] T1 Assertion + migration 187 (+ rollback): RED, GREEN, staging
- [x] T2 App: route returns `quote`, types, panel line "Cotizado: X GYD -> Y CUP" on the open operation; vitest RED/GREEN
- [x] T3 Staging deploy (DB + app), owner check; then production with go-ahead

## Acceptance
- A conversation where the bot said "Para que lleguen *15,000 CUP* necesita depositar *5,000 GYD*" -> the panel shows
  5,000 GYD -> 15,000 CUP before any deposit; no target, status or amount on the operation changes.
- A quote older than the window, or from before the last closed remesa, is not shown.

## Progress / evidence
- T1 (2026-10-02): `supabase/staging/assertions/panel-quote.sql` (7 cases: no quote, CUP inverse 5,000 -> 15,000 CUP,
  newer USD 26,000 -> 100 USD, forward 30,000 -> 90,000 CUP, read-only (no target fixed), older than the window hidden,
  non-member 42501). RED on staging: `function crm_cotizacion_de_conversacion(uuid) does not exist`. GREEN in a
  rolled-back transaction with `187_panel_quote.sql` (+ ROLLBACK). Applied to staging; ALL PASS after. The owner's
  staging test conversation (9892f40c) reads 5000 GYD -> 15000 CUP.
- T2 (2026-10-02, delegated writer + parent review): GET /api/remittance-operations returns `quote` (null or
  {gyd, destinationAmount, destinationCurrency 'CUP'|'USD'|null, quotedAt}); `mapQuoteRows`; a failed or missing quote
  RPC logs and returns null (production before 187 keeps working); the newest open card shows "Quoted: 5,000 GYD ->
  15,000 CUP" (or "Quoted: 5,000 GYD" without a destination), never on history cards; strings
  `Inbox.operationsPanel.quoted/quotedTo`. RED: 14 failing tests in the 4 test files (e.g. `mapQuoteRows is not a
  function`, card text missing "Quoted: 5,000 GYD -> 15,000 CUP"). GREEN (parent re-run): 4 files / 139 tests; full suite
  141 files / 1677 tests (the board's 2 test files live on feat/operations-board); `tsc --noEmit` clean; eslint clean.
  Parent fix: the mapQuoteRows comment said the amount was kept with an unknown currency; the code drops both.
- T3 staging (2026-10-02 14:23 UTC, owner go-ahead): app `ac45d47` built in prod-build with Node 20 docker + the staging
  build env (NEXT_PUBLIC identical to the server's): manifest staging / kolppplawzdsjfydwejr, 114 money-path tests
  passed, 0 production refs / 32 staging refs, no .env, sha256 OK, the quote RPC present in the server chunks. Uploaded
  (2368 files = 2368), BUILD_ID checked on the server before relinking; served cwd `~/wacrm-releases/ac45d47…`,
  `anterior` -> `e3fff52…` (rollback: relink + `pm2 restart wacrm-staging --update-env`); `/login` 200, domain serves
  BUILD_ID `a3kHAsTQOhkWcW0Q19eSk`; no crash after restart. Pending: owner's check in the panel; production (187 + app)
  with go-ahead.
- Production (2026-10-02, owner go-ahead after checking staging): RED (function absent; 171 trigger and
  cerebro_cotizacion_vigente present); GREEN with 187 in a rolled-back transaction (7 cases); applied
  `187_panel_quote`; function md5 = staging (7a822b63), ACL postgres + authenticated (production grants no
  service_role); real read of conversation 40e6ab76 as a member -> 15000 GYD -> 45000 CUP (this morning's wrong quote;
  that conversation has no open operation). App `304a0c9` (app code = `ac45d47`; diff vs served `bf89693` = the 10
  panel files) built with the production env: manifest production / hqztotshnlzaiziwjyzh, 32 prod refs, 0 staging,
  114 money-path tests passed, sha256 OK; `desplegar-wacrm-produccion.sh`: served cwd `~/wacrm-releases/304a0c9…`,
  `anterior` -> `bf89693…` (rollback: `rollback-wacrm-produccion.sh`), domain serves BUILD_ID `389KqodTU7X9ucywy77V0`,
  `/login` 200. `privado/master` fast-forwarded to `304a0c9`. Staging and production run the same app code.
