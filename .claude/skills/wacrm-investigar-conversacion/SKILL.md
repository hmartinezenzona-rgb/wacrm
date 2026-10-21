---
name: wacrm-investigar-conversacion
description: "Trigger: investigar conversación, revisar cliente, qué pasó con, cliente, operación, por qué el bot. Read-only WaCRM conversation report, prod or staging."
license: Apache-2.0
metadata:
  author: "hmartinezenzona-rgb"
  version: "1.0"
---

## Activation Contract

Load when the owner asks what happened with a customer, conversation or operation, or why the bot answered or acted as it did.

## Hard Rules

- Read-only. Investigate only with `python3 infra/db/conversacion.py`; never write SQL by hand, never change data, never use the Management API.
- Production uses the read-only user from `~/.config/wacrm/prod-db.env`. Never print that file or any URL; the script passes it only as `--env-file`.
- Customer data (message text, names, phones, card numbers) never goes to Hermes or other models, is never committed, and enters engram as ids and counts only.
- Report facts with 8-char ids and UTC times. Label anything not in the output as assumed.
- Bot behaviour needs the n8n execution too: load `wacrm-cerebro-n8n` and read it. The decision logic is not in these tables.
- Use `--staging` only when the owner asks or the question is about staging.

## Decision Gates

| Situation | Action |
|---|---|
| Query is a hex id prefix (>=6, with digits and a-f), digits (>=6) or letters (>=3) | Run it |
| Exit 0 with a list of several conversations | Ask the owner which one; use `--elegir N` only when the owner has named it |
| Exit 2 `consulta no admitida` | Ask for a valid id, phone or name; never work around it |
| Exit 1 `Sin coincidencias` | Try the other query kind once, then report no match |
| Exit 2 for docker, env file or psql | Stop; report the script's error line |

## Execution Steps

1. `python3 infra/db/conversacion.py <consulta> [--desde YYYY-MM-DD] [--mensajes N] [--staging]`.
2. Apply the decision gate if several conversations match.
3. Read the sections and the checks in `references/investigar.md`.
4. For bot behaviour, read the matching n8n execution through `wacrm-cerebro-n8n`.
5. Save to engram only ids, counts and the conclusion.

## Output Contract

Return:
1. Timeline (UTC): one line per event with its table and id8.
2. Findings, each with the ids and times that prove it.
3. `Verificado` (seen in the output) and `Supuesto` (inferred), kept separate.
4. Any empty section or skipped check, with the reason.

## References

- `references/investigar.md`: section meanings, status values, masking and common checks.
