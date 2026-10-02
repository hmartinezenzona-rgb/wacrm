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
- [ ] T3 Align the staging Cerebro n8n workflow (production nodes + deal-free rewiring)
- [ ] T4 Re-measure: every function equal to production except the deal-free ones, documented

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

