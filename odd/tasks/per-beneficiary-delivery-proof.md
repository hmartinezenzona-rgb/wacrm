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
- [x] P1 — Zelle caption: RED tests (stale/null `deliveryMethod` + 1 Zelle beneficiary; 2 Zelle
  beneficiaries; mixed card + Zelle) → fix → GREEN. `isZelleOperation()`
  (`remittance-operation-card.tsx`) now derives from the current beneficiaries (`some(b =>
  beneficiaryType === 'zelle')`) whenever any exist, falling back to `deliveryMethod === 'zelle'`
  only for the legacy no-beneficiaries shape. Confirmed the only other caption/proof gate is that
  same function (forwarded as `isZelle`/`showCaption` through `complete-transfer-container.tsx` and
  `complete-transfer-section.tsx` into `delivery-proof.tsx`'s `showCaption` prop) — no other site
  needed a change. Commit `2761685`.
- [ ] P2 — (migration 143; 141/142 went to calculator-feed-from-beneficiaries) DB: table `remittance_beneficiary_proofs` (beneficiary_id, wamid, path, caption, sent_at,
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
- Strategy: ask-on-risk. Forecast: P1 ~60 lines; P2–P3 ~500–700 lines.
- User decision 2026-09-28: "en dos partes". Slice 1 = P2 (DB); slice 2 = P3 (panel). Each is a
  separate reviewed work unit on the feature branch; both reach production together (P4), since the
  DB slice is inert without the panel.

## Progress
- 2026-09-28: document created from the read-only map.
- 2026-09-28: P1 done. RED observed in `remittance-operation-card.test.tsx` for the 2-Zelle-
  beneficiaries, mixed (card+zelle), and pure-Cuban-card-with-stale-zelle-column cases (3 failing,
  right reason: old `isZelleOperation()` gated on count/`deliveryMethod`); the 1-Zelle-beneficiary
  and legacy (no beneficiaries + `deliveryMethod: 'zelle'`) cases were already green under the old
  code, added as regression coverage. Fixed `isZelleOperation()`; same 5 new tests + full existing
  suite for the file GREEN (99/99 across the 3 touched test files). `npm run test`: 1536 passed, 2
  pre-existing failures in `src/lib/dashboard/date-utils.test.ts` (`mondayIndex`, timezone-dependent,
  untouched file, not caused by this change). `npx tsc --noEmit`: clean. `npm run lint` on the
  touched files: clean. Commit `2761685`.

- 2026-09-29 02:5xZ — app deployed to production (user: "despliega la app en producción"):
  - commit e307274, BUILD_ID HgBhyHrHlJRRCga9_2ECo; built with Node 20; money-path vitest passed
    inside build-wacrm.sh; manifest environment=production, project hqztotshnlzaiziwjyzh;
  - `desplegar-wacrm-produccion.sh` on oracle: current → e3072747…; anterior → 854ad653…
    (rollback: `infra/deployment/rollback-wacrm-produccion.sh`); wacrm.onlinefreedom.site serves
    the new BUILD_ID.
  - Ships P1 (Zelle caption, 2761685) and the calculator panel fix (df4e2a4).

## Next step
P2 — DB: `remittance_beneficiary_proofs` table + RPC, staging migration.
