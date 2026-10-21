<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## Skills

- `wacrm-publicar-panel` (`.claude/skills/wacrm-publicar-panel/SKILL.md`): build and publish the production panel; load before any panel deploy or rollback.
- `wacrm-migraciones` (`.claude/skills/wacrm-migraciones/SKILL.md`): staging cycle and production apply for Supabase migrations; load before writing, applying or verifying any migration.
- `wacrm-cerebro-n8n` (`.claude/skills/wacrm-cerebro-n8n/SKILL.md`): inspect, back up, change and restore the Cerebro n8n workflows (Decisor, tool nodes, prompts); load before touching n8n.
- `wacrm-investigar-conversacion` (`.claude/skills/wacrm-investigar-conversacion/SKILL.md`): read-only investigation of a customer conversation (messages, operations, beneficiaries, audit, deposits, calculator, tools).
- `wacrm-corregir-produccion` (`.claude/skills/wacrm-corregir-produccion/SKILL.md`): correct production data with an audited atomic block; ledger and silent-close rules.
- `wacrm-medir-bot` (`.claude/skills/wacrm-medir-bot/SKILL.md`): measure the Cerebro bot with the eval battery (harvest, arbitration, replicated runs, per-case comparison).
- `wacrm-probar-staging` (`.claude/skills/wacrm-probar-staging/SKILL.md`): check a change in the browser against staging with PRUEBA fixtures and cleanup.
