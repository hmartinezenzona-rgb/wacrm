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
- [ ] T2 Migration 349 + ROLLBACK + assertion; staging RED -> GREEN; related assertions.
- [ ] T3 n8n node changes (daily, spaced, `leida`); offline check; staging copy updated and inactive.
- [ ] T4 Production: migration 349 (previa/aplicar/verificar), then the n8n workflow; verify; snapshot.

## Progress

- 2026-10-28 created. RDD off.

## Next step

T2.
