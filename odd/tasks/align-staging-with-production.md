# Align staging with production (before the deal-free production rewiring)

Objective: staging must hold what production runs (migrations 168-180 applied to production on
2026-10-01 directly, at the owner's request) PLUS the staging-only deal-free work (156-167, 172, 181),
so the next step of `odd/tasks/eliminate-deals.md` (WU5b, rewire production off `deals`) is built and
tested on the real production behaviour. Authorized by the owner 2026-10-01 ("alinea staging con
producción"), after taking over eliminate-deals from the deep-claude session.

Measured 2026-10-01 (function prosrc md5, production vs staging vs each repo migration, 64 functions
defined in 144-181): 57 differ.
- Production-only (copy as-is): 168_late_mmg_email_recross, 169, 170 (except the registrar), 171, 173,
  174, 175, 176, 179, 180. Includes non-function objects: the `recruzar-depositos-tardios` cron job,
  `automation_late_deposit_verification` in `remittance_admin_audit_action_chk` (production = staging +
  that value), config keys `minimo_gyd_*` / `completar_ventana_horas`, table `cerebro_cotizacion` +
  trigger `trg_registrar_cotizacion` on messages. `cerebro_registrar_cotizacion()` (171, trigger) and
  `cerebro_registrar_cotizacion(uuid, numeric, numeric, text, text)` (153, staging-only) are different
  overloads and coexist.
- Staging-only (keep): 153, 156, 158-167, 168_tags_off_delivered_operations, 172, 181.
- Changed on both sides (merge by hand, staging deal-free body + production fixes):
  `cerebro_registrar_deposito` (prod 178 / staging 167), `cerebro_cruzar_depositos` (178 / 167),
  `cerebro_cruzar_deposito` (144 / 167), `crm_comprobantes_de_operacion` (177 / 165).
- n8n: staging Cerebro carries the deal-free node rewiring (WU5); production Cerebro carries gates
  78-80 and the Snapshot/Decisor fixes. Merged in T3.

Constraints: staging only; production untouched. Each step verified by md5 against production (copied
objects) or by the assertions of both sides (merged objects). Strict TDD for the merged functions.

## Tasks
- [x] T1 Copy the production-only objects to staging, in production order, excluding the 4 merges
- [x] T2 Merge the 4 functions changed on both sides (deal-free + production fixes), RED/GREEN with both
      sides' assertions (2 needed no merge; migration 182 for the rest)
- [x] T3 Align the staging Cerebro n8n workflow (production nodes + deal-free rewiring)
- [x] T4 Re-measure: every function equal to production except the deal-free ones, documented
- [x] T5 Live WhatsApp test on staging (test number 529622896918, reset first) — needs the owner

## Progress / evidence
- T1 (2026-10-01): 168_late, 169, 170 (minus `cerebro_registrar_deposito`), 171, 173, 174, 175, 176, 179, 180 applied
  to staging in ONE transaction (exit 0; the cron job `recruzar-depositos-tardios` scheduled, the audit
  action added, `cerebro_cotizacion` + its trigger created). Re-measured: 33 production function bodies now
  present on staging byte-identical. `crm_corregir_entrada_calculadora` differs only in comments (production
  applied 149 before two comment lines were added to the file): no behaviour difference, left as is.
- T2 (2026-10-01): `crm_comprobantes_de_operacion` (staging 165 already decides can_verify by status, 177's
  fix) and `cerebro_cruzar_deposito` (167 contains 144) need no merge. Migration
  `182_deal_free_money_rules.sql` (staging only, + rollback): registrar = 167 + 170 (sum branch by operation
  status/window/minimum, ADDS the deposit) + 178 (same Ref = same deposit, via the receipts table);
  cruzar_depositos = 167 + 178 (burst dedupe, consumed-by-this-operation idempotency);
  objetivo_minimo / cruzar_pendientes / aplicar_cotizacion / recruzar_depositos_tardios keyed by operation
  (receipts table, objetivo operation_id), accepting a deal id or an operation id.
  RED: `supabase/staging/assertions/deal-free-money-rules.sql` case 1 — the deal-free path OVERWROTE the
  first deposit (10,000 instead of 13,000: Yais' bug). GREEN after 182: ALL PASS (11 cases: Yais, minimum
  wait, CUP in parts, two full deposits, ready remesa untouched, quote target, resent receipt on a ready and a
  waiting remesa, same Ref twice in a burst, late MMG email, no deal created).
  Regression over the other staging assertions, each run with and without 182 in the same transaction:
  identical failures without 182 (fixtures relying on the deal-insert trigger 172 retired; comprobantes_hashes
  fixture collision; stale-alert text; incident-reason case 1), so pre-existing. 182 IMPROVES the
  deals-referencing function set (8 -> 5; the remaining extra two vs the 4 expected are production's
  `cerebro_escribir_bloque_beneficiario` and `cerebro_sync_beneficiarios`, ported in WU5b). Only
  `deposit-path-without-deals` cases 3/4 changed: they registered four DIFFERENT deposits with the SAME Ref;
  with 178 that is a resend, so the fixture now gives each deposit its own Ref -> ALL PASS.

- T3 (2026-10-02 UTC): migration `183_deal_free_beneficiary_block.sql` (staging only, + rollback): the single
  writer of 179/180, `cerebro_escribir_bloque_beneficiario`, stores without deals (creates the operation with
  `cerebro_crear_operacion` when none, writes the parsed block as a new generation, 175's replacement rule,
  operator lock respected). RED before: partial-beneficiary-tools.sql case 1a ("guardado" but nothing stored,
  the deal no longer creates an operation since 172). GREEN after: partial-beneficiary-tools.sql and
  partial-beneficiary-auto.sql ALL PASS on staging; deal-free-money-rules.sql still ALL PASS.
  n8n (`~/cerebro-fase1/pruebas/gate81-staging-merge.py`, staging only): base = staging workflow (its URLs,
  credentials, webhook path, secret kept); from production: Snapshot final, Decisor, Beneficiario/Zelle completo?,
  Registrar beneficiario/zelle auto, the 3 registration tools, the agent prompt (with staging's 138 services
  catalog section) and text, the write-tool descriptions, Cruzar deposito con MMG (173 pedido_objetivo looked up
  by OPERATION via cerebro_resolve_op_id), and the official DeepSeek node (staging still used the community
  node, the DSML one). Kept from staging: Historial and Contexto deal-free readers (+ production's
  beneficiarios_registrados column), the 153 last-quote calc tools, marcar_destino_usd deal-free. Contexto
  validated with EXPLAIN on staging; every ctx field the production Decisor reads is present. Drift-checked PUT,
  15 nodes changed, verified byte-identical; active version fad5f789-1c43-4bc5-ba67-d9f057a4d115. Rollback:
  `~/cerebro-fase1/pruebas/ROLLBACK-81-staging-20261001-210429.json`.
  Found and NOT carried: the staging agent has a stray parameter `options.systemMessage` holding a B1.1 prompt
  ("cuanto recibe") that n8n never used; B1.1 was never live on staging either.
- T4: deals-referencing functions on staging back to exactly 4 (`deal-free-panel-verification` [0] PASS: the
  179/180/182 additions are deal-free now). Remaining staging-vs-production function differences are the
  deal-free ones (156-167, 182, 183) and staging-only 153/138.
- Incident during T2 checks (fixed): running the other session's assertions with `psql -1` and a prepended
  ROLLBACK-182 COMMITTED the revert (those scripts end in NOTICE, not an exception). 182 re-applied (md5
  verified), and the 2 fixture contacts my runs left were deleted. Runbook saved to Engram.
- T5 started (2026-10-02, eliminate-deals WU5b step 1, owner go-ahead): end-to-end deal-free test on staging. Test number
  reset (1 contact, 1 conversation, 1 operation removed). Staging: Cerebro ec691647 (gate 83), app ac45d47 (panel quote),
  `deals` has 0 rows, the [STAGING] MMG ingestion receives the real bank emails (unconsumed 5,000 GYD deposits of
  2026-10-02: 20402119681701 at 15:24 and 10402113200446 at 13:36 UTC). Script: quote "15 mil CUP" -> card -> phone ->
  a real receipt of a 5,000 GYD deposit from the last 72 h -> panel delivery. Checks: no deals row, operation created
  by cerebro_crear_operacion, receipt in remittance_operation_receipts, verification against depositos_mmg,
  ready_to_transfer, panel refreshes live, delivery completes and feeds the calculator.
- T5 DONE (2026-10-02 17:04-17:14 UTC, owner, conv 812eb3ee, operation 00af7859): voice "15 mil CUP" -> "Para que lleguen
  15,000 CUP necesita depositar 5,000 GYD"; card -> operation opened deal-free; phone 53721238 -> beneficiary complete;
  real receipt (MMG 20402119681701, 5,000 GYD) -> remittance_operation_receipts row, depositos_mmg consumed by this
  operation, "verificado", ready_to_transfer; panel delivery with proof -> completed (audit human_delivery, proof_sent),
  calculator entry completed_operation CUP 5,000 GYD -> 15,000 CUP. `deals` stayed at 0 rows. Owner saw the panel refresh
  live at every step.
  ONE FAILURE, not deal-related: the "Listo, su remesa ... ya fue completada" message was not sent. Cause: staging
  `cerebro_config.notify_url` was 'http://127.0.0.1:1/receipts-noop' (and notify_secret 'receipts-noop'): the assertion
  `supabase/staging/assertions/operation-receipts.sql` overwrites them assuming an outer BEGIN ... ROLLBACK; run without
  it, the SAVEPOINT failed, psql kept going, and the overwrite was committed (so staging sent no status notification at
  all; net._http_response showed "Couldn't connect to server" at 17:08 and 17:09). Fixed: notify_url restored to the
  staging notifier webhook (staging-wacrm-notify-etapa), notify_secret restored and then rotated (it was printed in a
  local tool output) in DB + ~/.config/wacrm/staging-n8n.env; the missed notification replayed for 00af7859 -> 17:13:58
  "Listo, su remesa de *15,000 CUP* ya fue completada". Hardened: the 16 assertions that write cerebro_config behind a
  SAVEPOINT now start with `\set ON_ERROR_STOP on` (proved: run without BEGIN it stops at the SAVEPOINT and the config is
  untouched). horario_cierra (the other key they write) equals production.
