---
name: wacrm-cerebro-n8n
description: "Trigger: cerebro, n8n, Decisor, workflow del bot, herramienta del bot, prompt del bot. Inspect, back up, change and restore the Cerebro n8n workflows (staging and production) with cerebro_n8n.py."
license: Apache-2.0
metadata:
  author: "hmartinezenzona-rgb"
  version: "1.0"
---

## Activation Contract

Load when reading or changing the Cerebro bot in n8n: the Decisor code node, a tool node, a prompt, or comparing staging with production.

## Hard Rules

- Never execute (run or test) the staging or production workflow. Staging shares production's WhatsApp token and can message real customers.
- Run `respaldo <env>` before ANY write. Staging first, always.
- Ask the owner for an explicit go-ahead before EVERY production write. Earlier approvals do not carry over.
- Take `--esperado` from a fresh `estado <env>` run. Never guess it.
- The Decisor source of truth is `pruebas/decisor/decisor.jscode`. After editing it, run `npx vitest run pruebas/decisor` and update the md5 pin in `pruebas/decisor/correr.ts`.
- Staging and production "Contexto conversacion" queries differ. Never copy a node from staging to production blindly.
- Clone a tool node from the SAME environment's existing tool node so it keeps that environment's credential.
- Never send the n8n key, workflow JSON or customer data to other models, prompts or logs. Never print `~/.n8n-api-key`.

## Decision Gates

| Situation | Action |
|---|---|
| Only reading | `estado <env>`, `comparar`, `respaldo <env>` (all GET) |
| Decisor changed in repo | `publicar-decisor staging --esperado <live md5 prefix>`, verify, then production after go-ahead |
| New or changed tool node, query or connections | Edit via API per `references/cerebro.md`; no helper command exists yet |
| `versionId` != `activeVersionId` after a write | Deactivate then activate (see reference); production needs the owner's go-ahead |
| Wrong result after a write | `restaurar <env> <backup> --esperado <live versionId prefix>` |
| Prompt change | `~/cerebro-fase1/pruebas/evals/desplegar_prompt.py`, only with the eval battery green |

## Execution Steps

1. `python3 infra/n8n/cerebro_n8n.py estado <env>`; note versionId and Decisor md5.
2. `respaldo <env>`; keep the printed path.
3. Apply the change on staging; run `estado staging` and confirm versionId == activeVersionId.
4. Report to the owner and wait for the go-ahead.
5. Repeat 1-3 on production using production's own nodes; finish with `comparar`.

## Output Contract

Return per environment: backup path, versionId before and after, activeVersionId, Decisor md5 (8 chars) and repo match, changed and added node names, and any check skipped. On refusal return the tool's REFUSED line.

## References

- `references/cerebro.md` - ids, node names, tool-node clone recipe, prompt deploy, eval battery, versionId trap.
- Tests: `python3 -m unittest discover -s infra/n8n/tests`.
