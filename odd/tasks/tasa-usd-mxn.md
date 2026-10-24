# Automatic USD -> MXN rate (ARQ uses Google's rate)

## Objective

Keep the USD->MXN rate the business actually uses up to date automatically, so the bot and the panel never quote a
stale number. ARQ (formerly DolarApp) converts at the interbank "Google" rate; it has no public API, so the source is
Google Finance's USD-MXN quote.

## Problem and why

Osmany sets the Mexico payout rate by hand today. The owner confirmed 2026-10-24: "ARQ usa la tasa de cambio de
Google; tenemos que de alguna forma poder tener esa tasa actualizada de forma automática". Without a stored,
timestamped rate the bot cannot quote MXN and the operator has to look it up for every send.

## Evidence and constraints

- ARQ/DolarApp publishes no documented public API, but its FX calculator is an Astro island
  (`CurrencyCalculator` → `useInView` hook) that calls
  `GET https://api.arqfinance.com/v1/tickers?currencies=MXN`. The payload is
  `[{"ask":...,"bid":...,"book":"usdc_mxn","date":...}]` and it is reachable from the database
  (verified on staging 2026-10-24). This is the faithful source: the customer's payout uses the **bid** (the
  business sells USDc for MXN); ask is kept in `detalle`.
- Google Finance cannot be fetched from the database: its HTTP client gets an "Unsupported" page, and reader
  proxies block anonymous access. Yahoo Finance works but returned 429 and is not ARQ.
- `pg_net` is asynchronous: its worker cannot see a queued request until the queueing transaction commits. A single
  function cannot poll its own request; the fetch and the parse must be separate cron transactions.
- Both databases already run `pg_cron` (4 jobs) and have `pg_net`.

## Design

- `cerebro_tasas_cambio (id, par, valor, fuente, obtenida_at, registrada_at, detalle)`: one row per processed
  fetch (`arq`/`erapi`) or manual override (`manual`); `valor` NULL for a failed fetch; ARQ's `ask`/`bid`/`date`
  and `book` in `detalle`.
- `cerebro_tasas_solicitudes`: one row per queued pg_net request (fuente, url, request_id, procesada_at).
- `cerebro_parsear_tasa_arq(jsonb)` — BID of `book = usdc_mxn`, plausible range 5..50;
  `cerebro_parsear_tasa_erapi(jsonb)` — `rates.MXN`.
- `cerebro_tasa_solicitar()` — queues both GETs (its own cron transaction commits them).
- `cerebro_tasa_procesar()` — one minute later: reads `net._http_response`, parses, stores one value, marks the
  request processed, purges processed rows older than 7 days. ARQ wins; er-api is stored only when ARQ failed.
- `cerebro_tasa_usd_mxn()` / `cerebro_tasa_usd_mxn_info()` — readers (value, source, age, ask/bid).
- Jobs: `solicitar-tasa-usd-mxn` at `*/30 12-22 * * *`, `procesar-tasa-usd-mxn` at `2,32 12-22 * * *` UTC
  (08:00-18:30 Guyana).

## Tasks

- [x] T1 Migration 297 (tables, parsers, request/process steps, readers, two cron jobs) + ROLLBACK.
- [x] T2 Assertion with ARQ and er-api payload shapes, wrong book, implausible values, storage and latest-value
  rules, both jobs.
- [x] T3 Staging cycle green; real runs reach `api.arqfinance.com` and store its bid.
- [ ] T4 Production previa, owner go-ahead, apply, verificar, first real run.
- [x] T5a Calculator display: read-only row at the end of "Tasas actuales" — ARQ bid as the figure, ask/age/ARQ time
  underneath, amber "sin actualizar desde…" after two hours (GET /api/calculator/rates returns it; an RPC failure
  omits the row). Tests + tsc green.
- [ ] T5b Bot quote / M7 text once the owner answers whether the customer sees MXN before paying.

## Acceptance criteria

- A real run stores a plausible USD->MXN value with source google and its timestamp.
- A failed run stores valor NULL with the reason and leaves the last good value readable.
- `cerebro_tasa_usd_mxn()` returns the newest non-NULL value.
- Cron exists once, runs only in the business window, and the rollback removes it.

## Checks

TDD: enabled. RED before the migration, GREEN in staging, related assertions for pg_cron/net untouched.
