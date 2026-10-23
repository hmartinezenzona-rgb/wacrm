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
| 2 | Capability audit (read-only): what customers ask in real production conversations (last 30 days, by 8-char ids) vs agent tools: change amount, cancel/split/merge operations, move a deposit, change service, recipients, partial deposits | running |
| 3 | DB tools for every gap of step 2 + P1 (partial deposit on a planned split), migrations after step 1's | pending |
| 4 | n8n staging: tool nodes/descriptions/prompt + P2 (Decisor states facts only) for step 3 | pending |
| 5 | Offline measurement: S5b cases K/C/M/F + up to 6 real-shaped cases from step 2, 3 reps, mocked tools, DB replay rolled back | pending |
| 6 | Fix what step 5 shows (one round), re-measure only the failing cases | pending |
| 7 | Morning summary for the owner in this file + Engram; update odd/tasks/service-resolution.md and its mirror | pending |

## Left for the owner (not overnight)

Browser check of the panel (M6), M7 México status texts, M8 backfill, finance line for México (asked), S7 production
with a go-ahead per step (267 never before 269), re-enabling or removing the readers in production.

## Questions for the owner

## Log
- 22:2x step 1 done (d816e7c, odd/notes/staging-assertions-triage-2026-10-22.md): 162 files, 0 REGRESSION, 19
  pre-existing (15 obsolete since 172 deal triggers dropped, 3 stale vs deliberate changes, 1 stale staging row), 1
  flaky (contexto-envio-mixto: tie on created_at), 6 harness-only. Production follow-ups for the owner: saldo-model
  missing_inputs vs tier cost (check 242 in prod), tiebreaker for mixed part order, replacement coverage before
  retiring n8n-repoint/delivery/operation-incident-reason. Parent spot check: commit exists, report file only.
- step 2 launched (capability audit, read-only).
