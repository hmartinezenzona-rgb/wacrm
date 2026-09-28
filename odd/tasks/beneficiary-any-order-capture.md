# Beneficiary capture in any order (model-saved, DB-validated)

## Objective
The Cerebro model saves each beneficiary detail as soon as the customer writes it, in whatever
order it arrives: Zelle name and account, Cuban 16-digit card and mobile. The database validates
every piece before storing it. The deterministic twins stay as a safety net.

## Problem / why
- User request (2026-09-28): "lo que me interesa es que el modelo pueda guardar los datos en
  cualquier orden que lleguen". Approved as the next feature in the previous session.
- Today the model does not save partial data:
  - `registrar_beneficiario_zelle(nombre,cuenta)` refuses unless both come together, and the prompt
    says to call it only with NAME and ACCOUNT.
  - The prompt says cards and mobiles are registered by the system; the model has no tool for them.
- The deterministic layer (`Snapshot final` → `Merge beneficiario` → `cerebro_beneficiario_parcial`,
  COALESCE per field, 24 h expiry) already accumulates cards and mobiles in any order. Its gaps:
  - Zelle "number on one line, name on the next" is not parsed (Yamile / Ana case).
  - Card or mobile runs that are not exactly 16 / 8 digits go to `numeros_no_reconocidos` and are
    dropped.
  - A burst with more than one card or Zelle account blocks auto-registration (`multi_beneficiario`).
  - No "confirmed but not stored" net for cards (migration 135 is Zelle-only).
- Evidence (prod, read-only, 2026-09-28): only 2 real remesas since the 2026-09-27 cutover, both with
  a beneficiary. No loss is measured yet since the cutover; the baseline must come from evals.

## Scope
- Harness: repoint `~/cerebro-fase1/pruebas/evals/evaluar.py` to prod `jEzlVLCLUaJhVwzs`; add
  order-permutation cases.
- DB: one migration with a validated partial-save function for the model's tool.
- Cerebro: a new model tool plus the prompt change; `Snapshot final` learns "number, then name".
- Staging first, then production with a backup.

## Constraints
- The DB accepts a piece only when the customer wrote it (digits, or every word of the name) in the
  last 24 h, with valid formats: card 16 digits, mobile `5xxxxxxx` or `63xxxxxx`, Zelle US phone or
  e-mail. Never store a Cuban card as a Zelle account.
- Idempotent with the twins: saving the same piece twice, or after a twin, changes nothing.
- No change to deposit registration, repartos or the matcher.
- ~400 authored lines per task is an advisory heuristic only.

## TDD
- Mode: strict (source: global user instructions, "Strict TDD Mode: enabled").
- Runners:
  - model behavior: `evaluar.py` (real DeepSeek, mocked tools, temporary workflow);
  - DB: SQL assertions in a rolled-back transaction on staging / wacrm-ensayo
    (`supabase/staging/assertions/`);
  - `Snapshot final`: JS bench running the real node code.
- RED is observed before each change.

## Tasks
- [x] B1 — Baseline (RED). Repoint `evaluar.py` to `jEzlVLCLUaJhVwzs`. Add cases:
  - Zelle: name→account, account→name, "number\nname" in one message, split over 3 turns;
  - card: card→mobile, mobile→card, both in one message, with spaces or dashes;
  - details mixed with small talk.
  Record what the current prod prompt and extractor do with each.
- [~] B2 — Dropped by the user on 2026-09-28 after B1 ("sí, haz el paso 3"): the model already
  saves Zelle in every order and the twin handles cards.
- [ ] B3 — Zelle twin ties name and account in the 3 failing orders: account first, "number then
  name", e-mail. `Snapshot final` (and `Merge beneficiario` if the gap is across bursts).
  - RED: `banco-orden-beneficiario.js` + a cross-burst sequence on wacrm-ensayo.
  - GREEN, with `banco-nombre-zelle.js` and `banco-merge-nombre.py` unchanged (rules 1–3 of
    zelle-holder-name hold, e.g. a tied name never moves to a different account).
- [ ] B4 — Staging Cerebro `U52y1kSNvhgxvWeb` with a backup; rerun the benches against it.
- [ ] B5 — Production `jEzlVLCLUaJhVwzs` with a backup; watch the real executions; record.
- [~] Model tool `guardar_dato_beneficiario` + prompt change: dropped with B2.

## Acceptance criteria
- Every B1 permutation ends with the complete beneficiary stored, exactly once.
- Invented or malformed data is refused by the DB and never stored.
- No regressions in the existing eval cases; 0 DSML / reasoning_content leaks.

## Delivery
- Strategy: ask-on-risk. Forecast ~350 authored lines in the repo (migration, rollback,
  assertions, docs); n8n JSON and harness live outside git.

## Progress
- 2026-09-28: exploration done (explorer map + prod read-only counts). Document created.
- 2026-09-28 B1 baseline (1 repetition; `evals/informes/informe-20260928-061342.json`,
  `snapshot-orden-beneficiario-20260928120235..json`; harness `evaluar.py --workflow`, default
  `jEzlVLCLUaJhVwzs`; cases `casos-orden-beneficiario.json`, 12 cases / 34 turns):
  - All 12 end complete. 0 DSML, 0 reasoning_content, 0 errors.
  - Zelle (6 cases): the model called `registrar_beneficiario_zelle` once, in every order,
    including e-mail and small talk. It waits for the missing piece and asks for it.
  - Zelle twin: fails to tie name and account in 3 of 5 orders (account first, "number then name",
    e-mail). The gap is real, but only matters when the model does not call its tool.
  - Cards (6 cases): the model never calls a tool; the twin extracted card and mobile in every order
    (dashes, 63 prefix).
  - Not covered: 2nd repetition; cross-burst merge in `cerebro_beneficiario_parcial` (needs DB
    writes); the real `[CONTEXTO DEL SISTEMA]` block.
  - Conclusion: the premise "the model cannot save in any order" does not hold in the harness. The
    measurable gap is the Zelle twin (B3). B2/B4 await a user decision.

## Next step
B3.
