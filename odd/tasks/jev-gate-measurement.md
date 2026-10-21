# Jev gate measurement (offline)

## Objective

Measure, without touching production, whether the Jev decision model (TypeSafe System One via jev-ai.pro) can decide
reliably on real Spanish WhatsApp traffic: (1) does this customer burst need a reply, and (2) does the burst look
unfinished (the customer is still writing).

## Problem and why

- The Cerebro stays silent on simple acknowledgements through prompt rules and Decisor SKIP notes; the model sometimes
  ignores them (eval 478178) and every such turn still costs a DeepSeek call (~30k input tokens).
- 11% of production batches (275/2,555, 2026-09-21..10-21) were split because the customer kept writing; the
  "incomplete" heuristics in `Evaluar completitud` are fixed regexes.
- Jev answers typed questions with calibrated probabilities in ~0.5 s at negligible cost, but its documentation says
  non-English accuracy is lower. Owner idea (2026-10-21); owner authorized real customer messages for this test.
- Related, separate feature: `odd/tasks/bot-remittance-intent-jev.md` (PARKED 2026-09-24 for budget; different job).

## Scope

- In: dataset extraction from production (read-only), a Jev runner (HTTP, single attempt, no retry), metrics per
  threshold, an arbitration sheet for the disagreements, a report.
- Out: any n8n or production change. Deciding on a gate comes after the report, with the owner.

## Constraints

- Production DB read-only (`~/.config/wacrm/prod-db.env`). Datasets with customer text live in the evals `corpus/`
  (gitignored), never in git. Only the burst text and the bot's previous message go to Jev (no system context).
- Jev key in a 0600 file written by the owner; never printed, never in argv.
- A wrong silence is worse than an extra reply: report precision of "no reply needed" at high thresholds.
- TDD: strict (global CLAUDE.md). Runner: `python3 -m unittest discover -s tests` in `~/cerebro-fase1/pruebas/evals`.

## Tasks

- [x] J1 Dataset A (reply needed?): production batches with the bot's previous message and the bot's actual behavior,
      stratified (short acks and normal messages). Label source: the owner arbitrates disagreements.
- [x] J2 Dataset B (unfinished?): batches labelled by timing: another customer batch arrived while the bot was still
      on this one (unfinished) vs no customer message within 2 min after the bot answered (finished).
- [x] J3 Runner `jev/medir_jev.py` (pure parts tested): build state/questions, call Jev once per case, record
      probability, tokens and errors; cost cap.
- [ ] J4 Run both datasets; metrics per threshold (0.5/0.7/0.8/0.9/0.95): precision/recall, confusion, cost, latency.
- [ ] J5 Arbitration sheet for Dataset A disagreements (Jev vs bot); report with recommendation.

## Acceptance criteria

- Both datasets extracted, counts recorded, no customer text in git.
- Runner tests green; every Jev call logged with status; no retries.
- Report states, per threshold, how many customers would have been wrongly silenced.

## Applicable checks

- `python3 -m unittest discover -s tests` (evals).
- `git status` in evals shows no file under `corpus/` or `informes/`.

## Progress

- 2026-10-21 created. Jev key missing on this machine (owner to write `~/.config/wacrm/jev.env`, mode 600).
- 2026-10-21 J1+J2: `jev/extraer.sql` (evals 331bf18), read-only, last 30 days, text-only batches (audio/image
  events carry no text in session_events). Dataset A 250 (150 short <=4 words: 74 bot replied / 76 silent; 100
  normal: 58 / 42; 40 without a previous agent message). Dataset B 292 (142 unfinished, 150 finished). File
  `corpus/jev/datasets.json` (0600, gitignored).
- 2026-10-21 J3: `jev/medir_jev.py` + `tests/test_medir_jev.py` (evals 331bf18). RED observed (ImportError), GREEN
  12/12, full evals suite 98/98. Question instructions in English (Jev's strongest language), state in Spanish.

## Next step

J4 once the key exists: a 5-call smoke run, then datasets B and A with jev-latest and laya-multilingual.
