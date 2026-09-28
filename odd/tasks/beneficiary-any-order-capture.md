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
- [x] B3 — Zelle twin ties name and account in the 3 failing orders: account first, "number then
  name", e-mail. `Snapshot final` (and `Merge beneficiario` if the gap is across bursts).
  - RED: `banco-orden-beneficiario.js` + a cross-burst sequence on wacrm-ensayo.
  - GREEN, with `banco-nombre-zelle.js` and `banco-merge-nombre.py` unchanged (rules 1–3 of
    zelle-holder-name hold, e.g. a tied name never moves to a different account).
- [x] B4 — Staging Cerebro `U52y1kSNvhgxvWeb` with a backup; rerun the benches against it.
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

- 2026-09-28 B3 — Zelle twin, the 3 failing orders (RED evidence from a fresh prod GET,
  `jEzlVLCLUaJhVwzs`, 116 nodes):
  - Root causes, all in `Snapshot final`'s two-line tie rule (it only tied name-line-then-
    number-line, nothing else):
    1. **account first**: the existing two-line rule only walks name→number, never number→name.
    2. **"number, name" in one message**: same root cause as (1) — after the bench joins turns,
       "+1 305 555 0103\nMaria Fernandez Lopez" is structurally identical to account-first.
    3. **e-mail as the account**: the two-line rule's `sig` regex only accepts a phone-shaped
       line, never an e-mail.
    - Checked (not assumed) whether account-first-then-name across BURSTS already works, as the
      doc asked: it does not. `cerebro_nombre_completa($8, cerebro_beneficiario_parcial.zelle_nombre)`
      requires a non-empty stored label to "complete" (`cardinality(b.w) > 0`); when the account
      arrived alone the stored `zelle_nombre` is NULL, so the function returns false and the
      standalone name is never tied. This is a 4th, cross-burst-only gap, added to RED via a new
      `banco-merge-nombre.py` sequence run on wacrm-ensayo (not assumed from reading the SQL).
  - RED (fresh prod GET, before any change):
    - `banco-orden-beneficiario.js` (now scored: the 5 `orden-beneficiario-zelle` cases carry
      `esperado`): ROJO 5 casos con esperado, 3 failures (account-first, number-then-name,
      e-mail); the 2 name-first cases already passed.
    - `banco-merge-nombre.py` (now also asserts the tie `zelle_nombre_cuenta`, not just the name
      and account): ROJO 8 secuencias, 1 failure (the new cross-burst case); the 7 existing
      sequences stayed green under the new, stricter tie assertion.
  - Fix, smallest change, additive only (no existing block touched):
    - `Snapshot final`: one new two-line block, placed right after the existing same-line and
      `[Contacto]` blocks, before the standalone-name fallback. For two adjacent non-blank lines
      (blank lines skipped, same as the existing rule) in EITHER order, when one line is
      account-shaped (a phone line OR a bare e-mail) and the other is name-shaped
      (`pareceNombre`, 2–5 capitalized words, filtered by the same `NO_NOMBRE` set — so
      "Buenas Tardes Hermano" still never ties), it sets `zelle_nombre` + `zelle_nombre_cuenta`
      together, guarded by `if (zelle_nombre) return` so it never overrides an earlier tie.
    - `Merge beneficiario` (SQL, query-text only — see below): one new `WHEN` in both the
      `zelle_nombre` and `zelle_nombre_cuenta` CASE expressions, ordered between "complete an
      existing label" and "drop on account change": when a standalone name ($8) arrives and the
      stored `zelle_nombre` IS NULL, tie it to `coalesce($6, stored.zelle_cuenta)` (this burst's
      new account, or the one already stored) — never a stale account left over after rule 3.
    - Patch script: `~/cerebro-fase1/pruebas/parche-orden-beneficiario.py` (exact-match string
      replacement, same style as `parche-nombre-zelle.py`; fails loudly if the anchor text isn't
      found exactly once).
    - Rule 3 (zelle-holder-name) verified still held, not just assumed: the tied number the new
      block writes is always the same value already sitting in `zelle_celulares[0]` /
      `zelle_correos[0]` (the "principal" account), so the existing rule-3 check at the end of
      `Snapshot final` never nulls a name the new block just tied.
  - GREEN (all against the SAME patched code):
    - `banco-orden-beneficiario.js`: VERDE 5 casos con esperado.
    - `banco-nombre-zelle.js` (regression, unchanged expectations): VERDE 19 casos (was 19 before).
    - `banco-movil-63.js` (regression): VERDE (unchanged).
    - `banco-merge-nombre.py`: VERDE 8 secuencias (was 7 passing + 1 new failing; now 8/8,
      including the tie assertion on the 7 pre-existing sequences).
    - `banco-captura-beneficiarios.js`: skipped — needs a real-remesa corpus file this session
      does not have locally (`ERR_INVALID_ARG_TYPE`, second argument missing); not regenerated
      because doing so needs a fresh prod DB export, out of scope for this task.
  - No migration: no new column or function was needed (`zelle_nombre_cuenta`, `zelle_cuenta` and
    `cerebro_nombre_completa` all already exist from migration 131). Both changes are query/code
    text inside the n8n node, deployed in B4 — no `137_*.sql` was created.
- 2026-09-28 B4 — staging deploy (`U52y1kSNvhgxvWeb`), then the production candidate (not
  applied):
  - Backup: `~/cerebro-fase1/ROLLBACK-cerebro-staging-antes-orden-zelle.json` (fresh GET, 117
    nodes, confirmed byte-identical to the GET taken minutes earlier for the RED baseline).
  - Candidate: `~/cerebro-fase1/candidato-cerebro-staging-orden-zelle.json`, built from that exact
    backup with `parche-orden-beneficiario.py`.
  - Pre-flight (before the PUT): node count unchanged (117/117); only `Snapshot final` and
    `Merge beneficiario` differ; `disabled` unchanged (both `None`/`None`) — staging carries an
    extra experimental node (`DeepSeek Web Search Chat Model`, not in prod) that the diff
    confirmed untouched; connections unchanged (`==` on the full connections object).
  - PUT: `nodos=117`. Read-back GET after the PUT: 117 nodes, `active=true`, zero nodes differ
    from the candidate, `Snapshot final.jsCode` and `Merge beneficiario.query` byte-equal to the
    candidate.
  - No migration to apply on staging Supabase (`kolppplawzdsjfydwejr`): none was created (see B3).
  - Reran the Snapshot/Merge benches against the code AS READ BACK from staging (not the local
    candidate file): `banco-orden-beneficiario.js` VERDE 5/5, `banco-nombre-zelle.js` VERDE 19/19,
    `banco-movil-63.js` VERDE, `banco-merge-nombre.py` VERDE 8/8 (SQL run on wacrm-ensayo,
    unrelated to which n8n environment hosts the query text).
  - Production: never PUT to `jEzlVLCLUaJhVwzs`, never touched Supabase `hqztotshnlzaiziwjyzh`.
    Prepared `~/cerebro-fase1/candidato-cerebro-PRODUCCION-orden-zelle.json` from a FRESH prod GET
    (116 nodes) plus the same patch. Diff summary: node count unchanged (116/116); only
    `Snapshot final` and `Merge beneficiario` differ; `disabled` unchanged; connections unchanged.
    Awaiting a separate B5 decision to deploy.

## Next step
B5 (production), on explicit go-ahead — B4 only covered staging plus preparing (not applying) the
production candidate.
