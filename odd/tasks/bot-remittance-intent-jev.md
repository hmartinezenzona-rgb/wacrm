# Mark remittance intent on conversations, classified by Jev

## STATUS: PARKED (2026-09-24) — budget, not technical
Stopped by the user before any code was written: Jev has no free tier and the
smallest prepaid credit pack (~$19, credits never expire, no subscription) isn't
affordable right now. Nothing here is blocked technically — the research below
is complete and still valid, T1 could be applied the day a key exists.
Do not resume without the user explicitly asking.

## Objective
Give every conversation a yes/no "this customer showed remittance intent" mark,
classified by TypeSafe's Jev (a classifier model, not an LLM), so conversion can
finally be measured: conversations → intent → operation created → completed.

## Why
The Perplexity-assisted dashboard review (2026-09-24) flagged that there is no
explicit intent signal anywhere — conversion can only be approximated today by
"did a conversation end up linked to a `remittance_operation`", which can't
distinguish "never wanted a remittance" from "wanted one and we lost them".
That second number is the one worth knowing.

Jev was chosen because this is exactly its shape: a fixed yes/no decision over
messy text, ~$0.0004 per decision (10k classifications ≈ $0.21 — cost is not a
factor at this volume). Deliberately picked a job that does NOT exist today
rather than replacing a working bot decision, so a bad classification costs
nothing operationally.

## Decisions already made
- **Granularity: per conversation**, not per message (user decision,
  2026-09-24). Enough to measure conversion; per-message would only matter to
  know *where* in the chat intent appeared.
- **Monotonic**: once a conversation is marked `true`, it stays `true`. The
  timestamp records the FIRST detection and is never overwritten.
- `null` = never classified, `false` = classified and no intent seen yet,
  `true` = intent detected. The three states must stay distinguishable — that
  is the whole point over a plain boolean default.
- **Staging only.** Work happens on the `[STAGING] ...` cloned n8n workflows
  (`[STAGING] Cerebro v2 — LEGACY OPTIMIZED V1`, id `U52y1kSNvhgxvWeb`).
  Production workflows (no prefix, or `(PRODUCCION)` suffix) are never touched.

## What the workflow map showed (read-only exploration, 2026-09-24)
- 114 nodes, entry `Webhook WaCRM`.
- The assembled customer text lives in node **`Armar snapshot`** (Code node),
  field **`texto_completo`** — text messages joined, audio transcriptions
  inlined. `Snapshot final` re-exposes it; `Decisor` reads it as
  `s.texto_completo`.
- `Armar snapshot` runs on EVERY turn, including admin commands and
  image-only turns. **`Decisor`** is the first node that separates
  `agente` / `comando` / `silencio` — classifying after it avoids burning
  calls on non-conversational traffic.
- All 39 Postgres nodes use credential `Supabase STAGING` and the pattern
  `operation=executeQuery` calling a function, never a raw table insert.
  Reference: `SELECT cerebro_telemetria_registrar($1, $2::jsonb);` with
  `options.queryReplacement`, `onError: continueRegularOutput`,
  `alwaysOutputData: true`.
- External AI over HTTP: `Transcribir audio` uses a predefined OpenAI
  credential; every other HTTP node uses `genericCredentialType` +
  `httpHeaderAuth` with a named credential (e.g. `WaCRM API STAGING`). No
  predefined TypeSafe credential type exists, so Jev takes the generic
  header-auth path.
- Risk to respect: any node inserted before `Hay imagenes?` must pass the
  snapshot JSON through unchanged (that node tests `{{ $json.imagenes }}`),
  and downstream Code nodes reference `$('Armar snapshot')` /
  `$('Snapshot final')` / `$('Decisor')` by name — inserting is safe,
  renaming is not.

## Tasks
- [ ] **T1 — Schema + function** (no external blocker)
  `supabase/migrations/121_conversation_remittance_intent.sql` + rollback:
  three nullable columns on `conversations` (`remittance_intent boolean`,
  `remittance_intent_at timestamptz`, `remittance_intent_confidence numeric`)
  and `cerebro_marcar_intencion_remesa(p_conversation_id uuid, p_intent
  boolean, p_confidence numeric)`. Must copy the live `cerebro_*` convention
  exactly (verified against the live definition of
  `cerebro_telemetria_registrar`): `plpgsql`, `SECURITY DEFINER`,
  `SET search_path TO 'public'`, early `RETURN` on null input, and
  `EXCEPTION WHEN others THEN RETURN;` so a failed mark can never break a
  customer's turn.
  **Applied manually by the user** (assistant has read-only DB access).

- [ ] **T2 — n8n nodes** (BLOCKED: needs a TypeSafe API key, user must create
  the account — no free tier exists)
  In `[STAGING] Cerebro v2 — LEGACY OPTIMIZED V1`, after `Decisor` on the
  conversational route: an HTTP Request node calling
  `POST https://api.typesafe.ai/v1/systemone` (generic header-auth
  credential, mirroring `WaCRM API STAGING`) with `texto_completo` and a
  fixed yes/no question, then a Postgres node
  `SELECT cerebro_marcar_intencion_remesa($1::uuid, $2::boolean, $3::numeric);`
  with `onError: continueRegularOutput` so the bot turn survives a Jev
  outage. Must not disturb the snapshot JSON passed downstream.

- [ ] **T3 — Measure** (not authorized yet)
  Once data accumulates: conversion read (conversations with intent →
  operations created → completed). Possibly a dashboard widget, possibly
  just a query. Decide when there is real data.

## Acceptance criteria
- A conversation classified `true` keeps its first `remittance_intent_at`
  even after later turns re-classify it.
- A Jev outage or a malformed response leaves the bot turn unaffected
  (no failed execution, customer still gets a reply).
- Nothing outside the `[STAGING]` workflows is modified.

## Progress
T1 authored, pending manual application by the user. T2 blocked on the API key.

## Next step
User creates the TypeSafe account/API key; meanwhile apply T1's SQL.
