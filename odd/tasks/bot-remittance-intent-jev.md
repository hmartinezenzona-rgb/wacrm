# Mark remittance intent on conversations, classified by Jev

## STATUS: ON HOLD (owner 2026-10-21: "deja x ahora pendiente lo d jev")
T0.1-T0.3 done, T0.4 measured; pending the owner's counting start date
(proposed 2026-10-08). Do not resume until the owner asks.

## History: T0 offline measurement (resumed 2026-10-21 by the owner: "mide a ver")
Parked 2026-09-24 for budget. A TypeSafe key now exists
(`~/.config/wacrm/jev.env`, endpoint `api.typesafe.ai/v1`). Before building
T1/T2, T0 measures offline whether Jev reads remittance intent in Spanish
well enough. T1/T2 stay unauthorized until the owner decides on T0's result.

## T0 — offline measurement design
Why first: the gate measurement (`odd/tasks/jev-gate-measurement.md`) showed
Jev is weak in Spanish on fine judgements; web research (Engram
`cerebro/jev-gate-assessment-uses`) shows its proven uses are coarse bulk
classification, which this is.

- Production is read-only (`BEGIN READ ONLY`, `~/.config/wacrm/prod-db.env`).
  Customer text lives only in
  `/home/onlinefreedom/cerebro-fase1/pruebas/evals/corpus/jev/` (0600,
  gitignored), never in git or Engram. Only the episode's customer text
  messages are sent to Jev (owner authorized real messages for Jev tests).
- One call per case and model, no retries; 401/402/429 stop the run.
- TDD strict (CLAUDE.md). Runner: `uv run --with pytest python -I -m pytest -q tests`
  in the evals repo.
- Episode = conversation x local day (America/Guyana) with >=1 customer text
  message, 2026-09-28 (operations start after the 09-27 cutover) to 2 days
  before extraction. Text = that day's customer text messages in order.
- Proxy labels: `P_remesa` remesa operation created within 48 h of day start
  (cancelled included); `N_seguimiento` no new operation but one in the
  previous 7 days; `N_sin_op` none in either window (contains the "wanted one
  and we lost them" customers, so Jev "yes" there is reviewed by hand, not a
  plain error); `R_otro_servicio` only a non-remesa operation (reported apart).
- Design-time counts (2026-10-21): P 100, N_seguimiento 11, N_sin_op 143, R 6.

- [x] T0.1 Extraction `jev/extraer_intencion.sql` -> `corpus/jev/intencion.json`; counts.
  2026-10-21: read-only run, 260 episodes (P 100, N_sin_op 143, N_seguimiento 11,
  R 6); text chars median 134, p95 754, max 1722; file 0600 and gitignored.
- [x] T0.2 Runner: question `quiere_enviar`, dataset `c` in `jev/medir_jev.py`, tests RED -> GREEN.
  Evals 43e00f4 (SQL), b11984c (runner). RED 6 failed (no MAX_TEXTO), GREEN 19/19, suite 105/105.
- [x] T0.3 Run jev-latest + jev-preview on dataset c; calls, errors, tokens, latency.
  520 calls, 0 errors, 130,188 input tokens per model (~$0.005), median 0.27 s.
  Both aliases now resolve to jev-1.14.0, so it is one model measured twice
  (near-identical results).
- [ ] T0.4 Report: recall on P, false "yes" on N_seguimiento, hand review of
  Jev "yes" on N_sin_op; recommendation to the owner.
  Proxy metrics (jev-preview): u=0.5 precision 0.51 recall 0.67; u=0.8 0.52 / 0.48.
  N_seguimiento: 1/11 at >=0.5, 0 at >=0.8 (status follow-ups correctly "no").
  Hand review: 20/20 sampled N_sin_op cases at p>=0.8 show a clear send intent
  (amounts, Zelle accounts, Cuban cards, "deposité", "efectuado el pago"), so
  the proxy is what fails, not Jev: 44 episodes / 37 conversations of clear
  intent have no remittance_operation. P misses (33 at p<0.5) are mostly days
  with only data (accounts, names, phones) or follow-ups, where intent was
  stated on another day or by audio/image. N_sin_op <0.2 (62) are visas,
  translations, courtesy, system messages: correct "no".
  Owner (2026-10-21): Zelle sends go through the panel; when the panel fails
  they are done by hand. Follow-up check (read-only) on the 44 episodes: only 4
  have an operation in the same conversation within +-7 days, 0 in another
  conversation of the contact, 16 belong to contacts with no operation ever;
  a human agent replied that day in 39 and the customer sent an image (likely a
  receipt) in 37. First reading ("a third of sends outside the panel") is
  RETRACTED: the owner said many operations were removed from the history
  during the changes, and the data confirms it: production has NO
  remittance_operation before 2026-10-07 although the audit has activity from
  2026-09-27. 37 of the 44 episodes are before 10-07, an artefact of the
  deleted history.
  Recomputed from 2026-10-07 (P 100, N_sin_op 32, N_seg 11): u=0.5 precision
  0.87 recall 0.67; u=0.8 0.87 / 0.48; from 10-08: u=0.5 0.92 / 0.66. Only 7
  high-intent days without an operation remain.
  Next: owner picks the counting start date (10-07 first day with operations,
  10-08 first full day); then re-extract from that date.

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
