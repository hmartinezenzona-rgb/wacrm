# Delivery proof per beneficiary (image + caption), Zelle caption fix

## Objective
When completing a remesa in the panel, the operator attaches one proof image per beneficiary, each
with its own caption where it applies (Zelle). A Zelle remesa always shows the caption box. The
customer receives every proof, then the "remesa completada" notice once.

## Problem / why
User report (2026-09-28): "cuando es zelle la remesa no está mostrando para enviar el caption, y si son
2 envíos de zelle por un mismo depósito solo deja poner un caption; debería dejar poner 2 fotos y su
caption, en dependencia de los beneficiarios... eso debemos llevarlo a producción".

Root causes (read-only map, 2026-09-28):
1. The caption box shows only when `isZelleOperation()` is true
   (`src/components/inbox/operations/remittance-operation-card.tsx:200-203`,
   `complete-transfer-container.tsx:325`). It trusts `remittance_operations.delivery_method` (set only
   by the legacy notes trigger, `042`, with an arbitrary `LIMIT 1`; never set by the reparto RPCs
   127/129 or the add-beneficiary RPC 123), OR exactly 1 Zelle beneficiary. A Zelle op with a stale
   column, or 2 Zelle beneficiaries, gets no caption.
2. The model allows one proof per operation: scalar `delivery_proof_wamid` / `delivery_proof_path`
   (101/108); `crm_entregar_operacion(p_operation_id, p_evidence)` takes one evidence; the client draft
   `DeliveryProofDraft` is a single `{file, caption}` (`src/lib/pipelines/delivery-proof.ts`); one
   WhatsApp image (`send-proof-image.ts`), then one stage flip → `remesa_completada`.

## Scope
- P1 (small, shippable alone): caption visibility from the beneficiaries
  (`beneficiaries.some(b => b.beneficiaryType === 'zelle')`), not from the operation column or the
  count.
- P2–P4: one proof (image + caption) per beneficiary; completion (stage flip + remesa_completada) once,
  after every beneficiary's proof was sent.

## Decisions (defaults; change if the user says otherwise)
- One image per beneficiary. The caption box shows only for Zelle beneficiaries; the caption text of
  each Zelle proof carries that beneficiary's name as today.
- The operation is delivered (stage flip, `remesa_completada`) once, after the last proof is sent.
- The operation-level `delivery_proof_*` columns stay, holding the last proof, for backward
  compatibility (ledger feed, history).

## Constraints
- Money path: the calculator ledger feed, the history, and the aged-operations dashboard must stay
  correct.
- Migrations with ROLLBACK files; staging first; production via
  `infra/deployment/build-wacrm.sh` + `desplegar-wacrm-produccion.sh` only with the user's explicit
  go-ahead for that remote operation.

## TDD
- Mode: strict (global user instructions).
- Runners: `npm run test` (vitest) for the UI/lib; SQL assertions on staging
  (`supabase/staging/assertions/delivery.sql`, `reparto-auto.sql`, plus new ones).

## Tasks
- [ ] P1 — Zelle caption: RED tests (stale/null `deliveryMethod` + 1 Zelle beneficiary; 2 Zelle
  beneficiaries; mixed card + Zelle) → fix → GREEN.
- [ ] P2 — DB: table `remittance_beneficiary_proofs` (beneficiary_id, wamid, path, caption, sent_at,
  sent_by) + an RPC to record one beneficiary's proof; `crm_entregar_operacion` completes only when
  every current beneficiary has a proof. Migration + rollback + assertions; staging.
- [ ] P3 — Panel: one proof panel (file + caption for Zelle) per beneficiary; send each image, record
  it, then deliver once. vitest RED → GREEN.
- [ ] P4 — Staging end-to-end with a 2-Zelle reparto and a mixed one; then the production build and
  deploy with the user's go-ahead.

## Acceptance criteria
- A Zelle remesa always shows the caption, whatever `delivery_method` says.
- A 2-beneficiary reparto asks for 2 images (captions for the Zelle ones), sends both, and completes
  once.
- A single-card remesa behaves as today.

## Delivery
- Strategy: ask-on-risk. Forecast: P1 ~60 lines; P2–P3 ~500–700 lines, which exceeds ~400, so the
  chain strategy is asked before P2.

## Progress
- 2026-09-28: document created from the read-only map.

## Next step
P1.
