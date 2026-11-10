# Feature: the AVISO PROMESA alert fires only when a claimed save did not happen

## Objective
The admin alert "AVISO PROMESA" must fire only when the bot claims it saved customer data and nothing was actually
saved. It must judge by the data (beneficiaries, operations, deposits), after the writes had time to land, and ignore
the mandated off-hours notice.

## Problem / why (root cause, 2026-11-10)
- 36 alerts since 2026-10-26 (11 since 11-07); none was a real "claimed saved, nothing saved" case.
- Detector: trigger `cerebro_promesa_sin_escritura_guardar()` (migration 313, extending 296) on AI agent message
  insert; `cerebro_texto_promete()` regex (anotad[oa], queda[n] registrad|anotad|así, quedó registrad|anotado); alerts
  when `tool_execution_log` has no row for the conversation in [-3 min, +1 min].
- ~31 alerts: the prompt-mandated off-hours sentence "queda registrado y se procesa a partir de las {hora}" matches.
- Evidence is wrong: only the tool log counts (automatic paths `Registrar beneficiario auto`, `reparto_auto`,
  `notes_parse` are not there; any read tool such as calcular_usd silences it); the +1 min window is dead because tool
  rows land 22-59 s after the message insert.

## Owner decisions
- 2026-11-10: fix at root ("si, arréglalo de raíz"): judge by saved state, about 2 minutes after the message, ignore
  the off-hours notice.

## Scope
In: migration 362+ with ROLLBACK + staging assertions; staging apply; production with go-ahead.
Out: prompt wording, Decisor, the holiday/horario inconsistency (exec 689460, separate follow-up).

## Constraints
- Staging first; production only with explicit go-ahead. Read LIVE bodies first. Strict TDD (SQL assertions in
  rolled-back transactions, RED then GREEN). Never execute n8n workflows. Never touch the other session's files.
  No AI attribution in commits. RDD off.

## Tasks
- [x] T1 Migration 362: off-hours notice excluded; candidate recorded at message insert, evaluated after ~2 min
      against saved state (beneficiary/operation/deposit rows created or changed for the conversation in the window,
      any writer including automatic paths); alert only when nothing was saved; ROLLBACK; assertion with the 36-alert
      classes as fixtures (off-hours notice, saved before, saved 40 s after, automatic path, read-only tool, real miss)
- [x] T2 Staging: apply, related assertions; replay the 36 historical alerts read-only against the new rule
- [x] T3 Production (owner go-ahead "ok" 2026-11-10)

## Acceptance criteria
- Off-hours notice never alerts.
- Claim with data saved by any path within the window (before or up to ~2 min after) -> no alert.
- Claim with nothing saved -> exactly one alert.
- Replay of the 36 historical alerts -> 0 (or each remaining one justified).

## Progress / evidence
- 2026-11-10: root cause audited (read-only; 36 alerts; convs 9e338224, a0649b77, cfcc80b6, 1727ef31, 5a4c0ab8,
  ff16d5a2 among them).
- 2026-11-10 T1 (commit f3e9c13): live bodies read before changing. md5 of `cerebro_promesa_sin_escritura_guardar`
  4e1291b91dcfbe61446882285bfdc7bb and `cerebro_texto_promete` 09c6b953b95635a8b5df12bbda008972: production ==
  staging. Trigger `zzz_messages_promesa_sin_escritura` present on both.
- Mechanism: pg_cron is installed on staging and production and already runs per-minute sweepers
  (`recruzar-depositos-tardios`, `caducar-*`, `webhook-outbox`). Reused: new job `evaluar-promesas` (`* * * * *`)
  calling `cerebro_promesa_evaluar()`, plus a small candidate table `cerebro_promesa_candidatas` (status pending /
  saved / alerted / failed). No other new infrastructure. Alert path unchanged (cerebro_promesas_sin_escritura
  case row, cerebro_memoria note, `cerebro_outbox_encolar` with key `promesa-<message id>`).
- Window: saved state in [message - 45 min, evaluation time] (evaluation = message + 2 min, so up to ~3 min with
  the per-minute job). Chosen from the 36 historical cases: recap messages trail the save by up to ~38 min.
  Sources: operations (created/updated), beneficiaries (created/confirmed/replaced), deposit receipts, MMG deposit
  consumption, partial beneficiary (Zelle) rows, reparto plans.
- TDD: assertion `promise-alert-by-state.sql` first. RED: `ERROR: function cerebro_promesa_evaluar(timestamp with
  time zone) does not exist`. GREEN: `ERROR: ALL PASS (rolled back on purpose)` (dry-run, apply, assertion on the
  applied state; ROLLBACK-362 test: md5 equal to the previous bodies).
- Staging apply: `staging-migracion.sh aplicar` -> dry-run OK, apply OK, assertion OK, rollback OK. Job
  `evaluar-promesas` is live on staging only.
- Related assertions (`promes|texto_promete`, `--ya-aplicada ROLLBACK-362`): TOTAL 2, SAME 2, DIFF 0 after updating
  `promesa-aviso.sql` and `promesa-sin-escritura.sql` to evaluate the candidate (they ran clean on the base before;
  the first pass showed the expected DIFF 2/2 because the alert is no longer immediate). `promesa-sin-escritura`
  case 7 changed meaning: a tool row alone no longer silences the case.
- T2 replay (read-only on production, 36 alerts since 2026-10-26, evaluation at message + 2 min): 35 would not
  alert (31 are the off-hours notice, no claim; 4 saved by beneficiary/operation/receipt/MMG evidence); 1 would
  still alert (conv f80a33a0, 2026-11-07 14:03: claim, only saves 48 min before and 22 min after the message).

- 2026-11-10 T3 production: previa SEGURO; `OK 362_promise_alert_by_state 20261110071813`; verificar 4/4 equal;
  cron job `evaluar-promesas` present and active on production.

## Next step
Done. Watch the first real candidates (cerebro_promesa_candidatas statuses, cron run details).
