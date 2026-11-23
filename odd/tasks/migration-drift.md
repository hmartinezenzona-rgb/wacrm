# migration-drift

**Objective**: map the drift between the repo migrations, production's ledger and staging's ledger, fix what is safe, and leave explicit decisions where only the owner can choose.

**Measured 2026-11-22**
- Repo: 371 numbered migration files.
- Production ledger: 331 rows.
- Staging ledger: 125 rows (last entry 2026-09-26).
- Guard added: `infra/db/tests/probar_numeracion.sh` (duplicate numbers; one ROLLBACK per migration >= 127). It passes.

## What is real and what is bookkeeping

### 1. Production ledger is a partial record, not a missing schema
99 repo numbers have no production ledger row:
`001-055, 058, 059, 095-101, 109-143, 169, 244, 348`.

For all but 348 the schema effects are present; the rows were applied outside the ledger (psql/dashboard before the ledger existed). Evidence:
- 017 already dropped the permissive `messages` policy in the repo, while live production still had it until 386 (the policy history is in 001/017).
- 037 (Cerebro schema) and 051 (message_outbox) tables exist.
- 114/125 are documented as applied everywhere in memory.
- The calculator objects from the 102-108 block exist (`calculator_rate_versions`, `remittance_calculator_entries`, `calculator_facturado`, `calculator_invertido`).

Consequence: `produccion-migracion.sh previa` would not recognise those names as recorded. Never run it on a pre-ledger file without understanding this.

### 2. Nine numbers were reused for different migrations
| Number | Repo file | Production ledger |
|---|---|---|
| 004 | `004_contact_delete_set_null` | `004_reanudar_ia_es_inmediato` |
| 102 | `102_operations_history_and_delivery_readiness` | `102_pausa_humana_caduca` |
| 103 | `103_calculator_rate_versions` | `103_pausa_humana_caduca_por_reloj` |
| 104 | `104_calculator_ledger_feed` | `104_derivacion_atendida_caduca` |
| 105 | `105_calculator_resolve_pending` | `105_memoria_sin_basura` |
| 106 | `106_calculator_session_client_access` | `106_rescate_dsml` |
| 107 | `107_destination_amount_rounds_up` | `107_memoria_guarda_el_skip` |
| 108 | `108_delivery_evidence_before_status` | `108_reintento_avisado` |

Do not renumber applied files. Keep this table as the alias map.

### 3. Legacy unnumbered ledger names
68 production ledger names have no repo file (e.g. `auditoria_semantica_registrar`, `cerebro_*`, `crear_depositos_mmg`, `061b/c/d_*`). They are old names for objects the repo now carries under numbered files or under different names. They are history, not pending work.

### 4. Duplicate numbers already applied
- `088_historial_paginado` + `088b_historial_permisos_exactos`.
- `168_late_mmg_email_recross` + `168_tags_off_delivered_operations` (each has its own ROLLBACK).
- Staging also reuses 102 for two names.
The guard allowlists 088 and 168; any new duplicate fails.

### 5. Legacy gaps below 127
- 79 migrations <= 126 have no ROLLBACK. None >= 127 is missing one (guard enforces it).
- 13 staging assertions do not end with `ALL PASS` (from the 2026-11-22 audit; not re-verified here).

### 6. Staging holds an experiment production does not have (not abandoned)
Seven tables, their functions and 76 columns exist only in staging and in no repo migration:
`cerebro_turns`, `tool_invocations`, `cerebro_outbox_v3`, `claim_checks`, `cerebro_cuentas_deposito`, `cerebro_negocio`, `cerebro_prompt_modulos`; plus `cerebro_claim_ready`, `cerebro_outbox_v3_*`, `cerebro_ingesta`, `cerebro_prompt_modular` and the v3 tool functions (`cerebro_cotizar_tool`, `cerebro_registrar_destino_tool`, `cerebro_ajustar_envio_tool`, `cerebro_completar_turno`, `cerebro_reclamar_turno`, `cerebro_verificar_claims_v3`, `cerebro_cuentas_activas`, `cerebro_negocio_get/completo`, `cerebro_retirar_cuenta`).

Verified absent from production and from every branch. **Correction (2026-11-23): this is not dormant scaffolding.**
- `cerebro_prompt_modulos` holds 13 config rows; `cerebro_cuentas_deposito` and `cerebro_negocio` one each.
- `pg_stat_statements` shows real calls: `cerebro_cuentas_activas` 115, deletes on `cerebro_outbox_v3` 87, `cerebro_verificar_claims_v3` 47, `cerebro_prompt_modular` 24+11.
- The staging n8n workflow carries extra tool nodes (`agregar_servicio`, `declarar_servicio`, `modificar_operacion`) that map to these functions.
- The queue tables are empty, so the turn pipeline is not processing, but the configuration and tool surface are wired.

Two of the audit's nine objects are not part of this experiment:
- `cerebro_ingesta_perdida` **is in the repo** (migration 300), has rows from 2026-10-26 to 2026-11-17, and `hermes_alertas` (314) reads it. Keep it.
- `remittance_calculator_clearances` + `crm_limpiar_calculadora` belong to the calculator-delete feature, empty today; `eval_memoria_replay` is the empty replay harness. Neither is v3.

Consequence: a blanket discard would break the staging v3 path and its tool tests. The safe options are to capture the v3 objects into a migration (reproducible) or keep them documented as staging-only.

### 7. 348 is staging-ahead on purpose
`348_outbox_partes.sql` is not in the production ledger; production lacks `message_outbox.grupo_id/parte/partes`, the extended status CHECK and `cerebro_outbox_encolar_partes`. Production works in single-message mode (`opt_partir_respuesta` absent). This is a feature not yet released, not a lost migration.

## Decisions needed

1. **Staging experiment (section 6)** — **DECIDED 2026-11-23: keep it documented as staging-only and do not touch it.** It is wired into the staging workflow and holds live config, so it is neither dropped nor captured now. Revisit only if the v3 work resumes or staging is rebuilt; a rebuild from migrations would lose it and must be handled then.
2. **348**: keep it staging-ahead until the reply-splitting feature ships, or release it now. Recommendation: keep it staging-ahead.
3. **Ledger backfill (section 1)**: leave it as a documented historical baseline (recommended; backfilling would record rows nobody can verify) or insert rows for the repo names after object-by-object verification.

## Done in this task
- Guard `probar_numeracion.sh` (duplicate numbers, rollback per migration >= 127).
- Alias map and measured state recorded here.

## Follow-ups
- [x] 13 legacy assertions closed 2026-11-23:
  - 10 received the `ALL PASS` marker and pass.
  - `stale-operations-alert` was rewritten to insert `remittance_operations` directly (its deal-based fixture relied on triggers retired by 172) and passes.
  - `deal-insert-creates-operation` and `tag-sync-without-deals` moved to `supabase/staging/assertions/legacy/` with a README: both exercise deal triggers that 172 deliberately dropped.
  - New `sync-tags-cliente.sql` covers the live `sync_tags_cliente` (Nuevo/Cliente/Recurrentes/Admin) and passes.
- Consider a read-only `estado-migraciones` command that prints this classification automatically against both ledgers.
