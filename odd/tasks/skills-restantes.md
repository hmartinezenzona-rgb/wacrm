# Remaining workflow skills (investigate, correct production data, measure the bot, test on staging)

## Objective
Finish the set of WaCRM workflow skills so later work uses them instead of re-deriving procedures. Built by a cheaper
Claude model (owner decision 2026-10-21: Haiku), reviewed by the parent.

## Skills
1. `wacrm-investigar-conversacion` — `infra/db/conversacion.py <query>` (name, phone or conversation-id prefix) with the
   production READ-ONLY credential (`~/.config/wacrm/prod-db.env`, user respaldo_lectura, via docker psql) printing, in
   one go: matching conversations; messages (time, sender, text, trimmed); operations (service, method, status,
   amounts, group); beneficiaries (vigente/reemplazado, source); admin audit; deposits (depositos_mmg); calculator lines
   (remittance_calculator_entries); tool_execution_log. `--staging` uses .env.staging instead. Customer data stays
   local: never sent to Hermes or other models, never committed.
2. `wacrm-corregir-produccion` — reference with the atomic DO-block pattern (re-check state first, change, audit rows
   with actor `claude-code:owner-request`), ledger rules (completed lines append-only; amount/basis change = void +
   `calculator_feed_operation` re-feed; `crm_corregir_entrada_calculadora` changes only facturado/invertido/retorno),
   silent manual close (`customer_notice_muted_for='completed'`, delivery_mode closed_manually), lot balance via
   `crm_ajustar_saldo_cup`, and `infra/db/correccion-produccion.sh <file.sql> --confirmar` that runs one SQL file
   through the Supabase Management API token (`~/.config/wacrm/supabase-token.env`, 0600) only with --confirmar.
3. `wacrm-medir-bot` — doc skill over `~/cerebro-fase1/pruebas/evals`: cosechar.py, generar_casos.py --desde,
   PARA-ARBITRAR sheet, ascender_arbitraje.py, evaluar.py --reps N (python3 -u), agregar_informes.py (single set and
   --a/--b Fisher comparison), interpretation rules (never totals; history-dependent cases; pre-annotation too literal).
4. `wacrm-probar-staging` — panel-local-staging.sh, realistic fixtures (destination currency/amount, contact, complete
   beneficiaries, a last message), browser check, cleanup SQL; staging Cerebro never executed.

## Constraints
- Read-only against production for investigation; the correction script only with --confirmar and owner go-ahead.
- Secrets never printed; customer data never leaves the machine.

## TDD
Strict for scripts. Runners: `python3 -m unittest discover -s infra/db/tests` (or bash tests like infra/db/tests).

## Tasks
- [x] R1 — wacrm-investigar-conversacion (script + tests + skill).
- [x] R2 — wacrm-corregir-produccion (script + tests + skill).
- [x] R3 — wacrm-medir-bot (skill + reference).
- [x] R4 — wacrm-probar-staging (skill + fixture/cleanup templates).
- [x] R5 — AGENTS.md lines + global symlinks; real read-only run of R1 on a known conversation.

## Progress
- 2026-10-21 (4 Haiku agents in parallel, default effort): R1 2ada4dc (conversacion.py, 18 tests; input validated and
  passed as psql variables; cards masked twice; real read-only run on f8b7779c correct), R2 97db52a (correccion-
  produccion.sh --confirmar, 22 checks; refuses schema-destructive statements; note: crm_ajustar_saldo_cup likely fails
  via the API — no JWT), R3 79fde45 (medir-bot; harness 38 tests OK; found arbitration sheets/cases with real customer
  messages tracked in the local evals git repo — no remote), R4 d8d82f7 (probar-staging fixture/cleanup validated in
  rolled-back transactions; cleanup refuses non-PRUEBA). R5 by the parent: AGENTS.md lines + global symlinks +
  __pycache__ ignored. Token helper dedup delegated (lib-migracion.sh).

## Next step
Use the skills: check production bot traffic and first CUP deduction; investigate the Zelle holder-name issue.
