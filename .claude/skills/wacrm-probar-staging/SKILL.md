---
name: wacrm-probar-staging
description: "Trigger: probar en staging, probar en el navegador, ver el panel, caso de prueba, demo. Staging PRUEBA fixtures, panel check, cleanup."
license: Apache-2.0
metadata:
  author: "hmartinezenzona-rgb"
  version: "1.0"
---

## Activation Contract

Load when the owner wants to see or test a WaCRM panel change on staging, in the browser, or needs a demo case.

## Hard Rules

- Staging only: `CRM_STAGING_DATABASE_URL` from `.env.staging`; the panel reads `~/.config/wacrm/staging-build.env`. Never touch production.
- NEVER execute the staging Cerebro n8n workflow: it shares production's WhatsApp token and can message real customers. Fixtures set `ai_autoreply_disabled = true`.
- The owner logs in himself. Never type, ask for, or store a password or token.
- Fixtures: name `PRUEBA <nombre>`, unused phone `5990253nnnn`, realistic data (destination currency and amount, contact, beneficiary with card and phone, last message). Missing parts make the panel hide sections.
- Show the owner the cleanup dry run (what will be deleted) before the real cleanup. Leave zero PRUEBA rows.
- Stale browser tabs: Ctrl+Shift+R.
- `/api/promotions/etecsa` returning 500 locally is expected.

## Decision Gates

| Situation | Action |
|---|---|
| Single operation | `svc2` and `monto2` empty |
| Mixed send (remesa + recarga) | `svc2=recarga`, consumed deposit, `objetivo=1` |
| Panel not running on 3100 | start `panel-local-staging.sh` in background |
| Phone already used | fixture aborts; pick another `n` |

## Execution Steps

1. Start `infra/deployment/panel-local-staging.sh` in background (port 3100).
2. Run `assets/fixture-envio.sql` with `psql -1` (one transaction) and every `-v` variable; read the conversation uuid from the `fixture ok` NOTICE.
3. Open `http://localhost:3100/inbox` with chrome-devtools; the owner logs in; check the conversation with snapshot, click, fill; `evaluate_script` for selects with narrow no-break spaces.
4. Verify in the database with read-only queries.
5. Clean up: dry run of `assets/limpieza.sql` (wrapped in BEGIN/ROLLBACK, `-v conv=<uuid>`), show the owner the NOTICE counts, then the real run with `psql -1`. Confirm zero rows.

Variables, commands and queries: `references/staging.md`.

## Output Contract

Return: conversation uuid and phone, what the owner saw and did in the panel, DB checks, cleanup result (rows left = 0), and any step skipped.

## References

- `references/staging.md` — variable table, run commands, cleanup rules, panel notes.
