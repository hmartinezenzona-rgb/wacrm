# Overnight loop 2026-10-22 -> 2026-10-23 (owner asleep)

Owner: "quisiera dejarlo en un loop para que siga trabajando incluso si estoy durmiendo y se acaba el límite, pero que
siga hasta que se realice todo lo que falta; puedes revisar las conversaciones con clientes, ahí tienes datos reales".

## Hard limits (never cross while the owner sleeps)

- STAGING ONLY. No production DB writes, no production n8n change, no panel deploy, no push, no merge.
- Never execute the staging or production Cerebro workflows (shared WhatsApp token). No WhatsApp message to anyone.
- Production reads only (Supabase MCP SELECT, n8n executions read): to harvest real customer cases. Real customer text
  stays local (repo notes by 8-char ids, harness `corpus/`), never quoted in reports.
- Measurement budget for the whole night: at most 3M input tokens, 3 reps per case (owner approved re-measuring).
- One DB writer at a time on staging. Agents: sonnet for SQL/Decisor, haiku for mapping/reading; no background
  monitors in agent prompts; TDD strict; one commit per work unit.
- If a step needs an owner product decision: write it under "Questions for the owner" and continue with other steps.
- Two failed attempts at the same step: mark it BLOCKED with the reason and move on.

## Steps (update the status column; one step at a time; parent reviews each result)

| # | Step | Status |
|---|---|---|
| 1 | Assertion triage (agent running at loop start): fix every REGRESSION it finds (migrations 280+) | done: 0 regressions |
| 2 | Capability audit (read-only): what customers ask in real production conversations (last 30 days, by 8-char ids) vs agent tools: change amount, cancel/split/merge operations, move a deposit, change service, recipients, partial deposits | done (8fe079c) |
| 3 | IMPROVE the existing agent tools so they cover step 2's needs + P1 (partial deposit inside repartir_envio). Owner rule: no patches, no tool per gap; extend the tool that owns the domain (like registrar_beneficiario_zelle gained several recipients); a new tool only when no tool owns the domain, and then general (e.g. one "modify operation" tool, not one per case). Migrations after step 1's | done (280-284) |
| 4 | n8n staging: tool nodes/descriptions/prompt + P2 (Decisor states facts only) for step 3 | running |
| 5 | Offline measurement: S5b cases K/C/M/F + up to 6 real-shaped cases from step 2, 3 reps, mocked tools, DB replay rolled back | pending |
| 6 | Fix what step 5 shows (one round), re-measure only the failing cases | pending |
| 7 | Morning summary for the owner in this file + Engram; update odd/tasks/service-resolution.md and its mirror | pending |

## Left for the owner (not overnight)

Browser check of the panel (M6), M7 México status texts, M8 backfill, finance line for México (asked), S7 production
with a go-ahead per step (267 never before 269), re-enabling or removing the readers in production.

## Questions for the owner

1. Cancel before a deposit: the loop lets the BOT cancel an operation that holds no money (no deposit); with money it
   stays human. Confirm or change.
2. Moving a deposit between operations stays human-only for now (money matching). Confirm or change.
3. Recipients: one recipient tool with a type (card, Zelle, México, cash, combo) instead of separate per-rail tools
   would follow the "one tool per domain" rule; not done overnight (large refactor). Decide tomorrow.

## Log
- 22:2x step 1 done (d816e7c, odd/notes/staging-assertions-triage-2026-10-22.md): 162 files, 0 REGRESSION, 19
  pre-existing (15 obsolete since 172 deal triggers dropped, 3 stale vs deliberate changes, 1 stale staging row), 1
  flaky (contexto-envio-mixto: tie on created_at), 6 harness-only. Production follow-ups for the owner: saldo-model
  missing_inputs vs tier cost (check 242 in prod), tiebreaker for mixed part order, replacement coverage before
  retiring n8n-repoint/delivery/operation-incident-reason. Parent spot check: commit exists, report file only.
- step 2 launched (capability audit, read-only).
- step 2 done (8fe079c, odd/notes/capability-audit-2026-10-22.md): top needs amount change (~21 human rows/30 d),
  cancel, service change (14), per-recipient amounts/split, recipient corrections (15), remove recharge number.
  Toolset: extend gestionar_beneficiario, registrar_numeros_recarga (quitar), cambiar_servicio (absorbs
  marcar_destino_usd), repartir_envio (partial deposit = P1); one new GENERAL modificar_operacion (monto, cancelar,
  unir). Parent note: part of the audit predates 274-279 (276 service-aware, 277 planned split) -> step 3 checks first.
- step 3 launched (DB writer).
- 2026-10-23 00:41 step 3 agent had stopped at the usage limit (22:4x) mid-280 (files uncommitted, before
  relacionadas); resumed with the same brief after the reset.
- Owner (22:5x, awake): "Lía" in the Marlene audio is ELIABA, an admin; the 10,000 GYD were a repayment to the business
  for a double transfer on 10-10 (Engram negocio/admins/eliaba-transcription). Question 4 for the owner: model customer
  debts/repayments? Until then the bot hands them to a person. Question 5: other admin names for transcription hints.
- 02:3x step 3 done: 280 partial deposit in repartir_envio (09b4341), 281 general cerebro_modificar_operacion
  monto/cancelar(no money)/unir (a628fe0), 282 registrar_numeros_recarga quitar (408465d), 283 cambiar_servicio takes
  rails incl. cup, marcar_destino_usd deprecated (96a6ee0), 284 gestionar_beneficiario correction by position/type +
  p_op (c08a150). Final sweep 142/167; the 25 failures are the known triage set. Parent spot check: re-ran
  modificar-operacion.sql on staging -> ALL PASS.
- step 4 launched (n8n staging wiring + P2).
