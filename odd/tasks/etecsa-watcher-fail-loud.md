# Etecsa promo watcher: fail loud, read once a day

## Objective

The Etecsa promo watcher (n8n `vk6aEa4bOZtl5xSz`) must never report a failed read of etecsa.cu as a successful
check. The admins get a notice once when it cannot read the site. It reads the site once a day, with spaced
requests, so that etecsa.cu stops blocking it.

## Problem (2026-10-28, read-only)

- Every run since at least 2026-10-27 22:00 UTC (older runs are pruned) gets `connect ECONNREFUSED
  190.92.127.202:443` on "Leer etecsa.cu". The node has `onError: continueRegularOutput`. The chain then ends in
  `cerebro_promo_revision`, which stamps `promo_etecsa_ultima_revision` anyway and returns "revision hecha, sin
  promocion legible". The staleness check (a manual query, 2 days) therefore never fires.
- The last promo detected was `b3556d1b`, on 2026-10-18. The x6 promo of 29-31 Oct was never detected. An admin
  told a customer about it by hand, and the bot said there was no confirmed promo.
- From a local machine, etecsa.cu answered the home page and two promo pages, then refused the connection on the
  4th request in a few seconds. It blocks bursts. The watcher fires home + every candidate page back to back, and
  the staging copy `okU7TYnB8R8b1OSo` hits the same site from the same n8n server every 3 h too.
- Run on the downloaded pages, the parser reads the live promo correctly (600-1250 CUP, x6, 29-31 Oct 2026). The
  parser is fine.

## Owner decisions (2026-10-28)

- "si, registrala": register the 29-31 Oct promo by hand (done, T1).
- "sigue con el punto 2": a failed read must not count as a check, and the admins are told.
- "si etecsa bloquea por varios intentos entonces haz solo una al dia": one run per day.

## Scope

1. DB (migration 349): `cerebro_promo_revision` takes an optional `leida` flag.
   - `leida = false`: do not stamp `promo_etecsa_ultima_revision`; record `promo_etecsa_ultimo_fallo`
     (time + error); notify owner/admins (type `promo_etecsa_fallo`) once per failure streak, meaning no such
     notice since the last good read.
   - Key absent: old behaviour, so the DB can go before n8n.
2. n8n production: one run a day at 08:00 Guyana; the home read sends a browser User-Agent; candidate pages are
   read one at a time, 20 s apart; the parser forwards `leida` and the error.
3. n8n staging copy: same nodes, left inactive (manual runs only), so it no longer adds requests from the same
   server.

## Out of scope

- Reading etecsa.cu from another server if the n8n server stays blocked (owner decides later).
- The completion notice without an amount (separate feature).

## Constraints

- Staging first; backup before every n8n write; never execute the Cerebro workflows.
- Never print tokens; customer data stays out of the repo.

## TDD

- Strict, on (global CLAUDE.md). Runners: SQL assertion `supabase/staging/assertions/promo-read-failure.sql`
  (self-reverting, `ALL PASS`) through `infra/db/staging-migracion.sh`; the node code is checked offline with
  `node` on recorded inputs.

## Tasks

- [x] T1 Register the 29-31 Oct promo in production (owner go-ahead). `promo_etecsa` `6bec68e3` (600-1250 CUP x6,
  2026-10-29..31, estado detectada); 3 `promo_etecsa` notices ("Precio 6200 GYD. Confirmela..."). Script
  `/tmp/claude-1000/-home-onlinefreedom/84dcfea5-1c88-47f9-85e7-612785657e25/scratchpad/registrar-promo-20261029.sql`.
- [x] T2 Migration 349 + ROLLBACK + assertion; staging RED -> GREEN; related assertions. RED (old body):
  `FAILED: 6 expectation(s)`; aplicar: dry-run/apply/assertion OK, rollback md5 equal, md5 after 1def13b04bfe;
  relacionadas: promo-notice SAME (ALL PASS), promo-read-failure DIFF (FAILED 6 -> ALL PASS). Commit 201cac6.
- [x] T3 n8n node changes (daily, spaced, `leida`); offline check; staging copy updated and inactive.
  Node code in `pruebas/vigilante/` (buscar.jscode, parsear.jscode, md5 pins in correr.ts, vigilante.test.ts):
  RED 11/12 on the live code -> GREEN; `npx vitest run pruebas/vigilante pruebas/decisor pruebas/partir` 269/269.
  Trigger "Una vez al dia" 08:00 `America/Guyana`; browser User-Agent; candidate pages batchSize 1 every 20 s.
  Staging `okU7TYnB8R8b1OSo` 623d73ad -> f1557b8e, inactive, staging credential kept. Manual run 570494:
  ECONNREFUSED (browser UA too: the n8n server's IP is blocked) -> `fallo de lectura, avisado: ...`.
  Backups `/home/onlinefreedom/cerebro-fase1/respaldos-n8n/vigilante-{produccion,staging}-*-20261028-151335.json`.
- [x] T4 Production: migration 349 (previa/aplicar/verificar), then the n8n workflow; verify; snapshot.
  previa `EQUAL cerebro_promo_revision`, VEREDICTO SEGURO; aplicar `OK 349_promo_fallo_lectura 20261028211606`;
  verificar 1/1 (prod=stg=1def13b0). n8n `vk6aEa4bOZtl5xSz` eb8da02b -> f9a9ba18 == active, 6 nodes, production
  credential kept, code md5 equal to the repo, connections equal. Not run by hand: the first real run is
  2026-10-29 08:00 Guyana. Snapshot `infra/n8n/snapshots/vigilante-etecsa-f9a9ba18-20261028.json` (secret scan 0).
  Rollback: `cerebro_n8n.py`-style PUT of the eb8da02b backup + `ROLLBACK-349-promo-fallo-lectura.sql`.

- [ ] T5 Panel confirm (owner 2026-10-28: "no deja confirmar la promocion, revisa x q"). Cause: the POST of
  /api/promotions/etecsa UPDATEs promo_etecsa with the service key; production service_role has only SELECT
  (305); staging had a table-level UPDATE, so the 2026-10-04 staging test passed. Migration 350: column UPDATE on
  estado/confirmada_at/confirmada_por (staging's table-level UPDATE revoked first). Staging: RED (no grant, prod-like
  base) `permission denied for table promo_etecsa` -> ALL PASS; aplicar OK; relacionadas 32: SAME 31, DIFF 1 =
  promo-confirmar-panel (pre-existing failures unchanged); previa VEREDICTO SEGURO. Production apply waits for the
  owner's go-ahead.

## Progress

- 2026-10-28 created. RDD off.

## Next step

- 2026-10-29 after 08:00 Guyana: check the run (expected `fallo de lectura, avisado` while the IP stays blocked)
  and that the admins see "No se pudo revisar la web de Etecsa".
- Owner decides whether to read etecsa.cu from another server (the n8n server's IP is refused).
