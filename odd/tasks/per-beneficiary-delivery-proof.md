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
- [x] P2 — (migration 143; 141/142 went to calculator-feed-from-beneficiaries) DB: table `remittance_beneficiary_proofs` (beneficiary_id, wamid, path, caption, sent_at,
  sent_by) + an RPC to record one beneficiary's proof; `crm_entregar_operacion` completes only when
  every current beneficiary has a proof. Migration + rollback + assertions; staging.
- [x] P3 — Panel: one proof panel (file + caption for Zelle) per beneficiary; send each image, record
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

- 2026-09-29 P2 — DB slice done inline by the parent, STAGING only (commit after this doc).
  - Migration 143:
    - table `remittance_beneficiary_proofs` (operation_id, beneficiary_id, wamid, path, caption,
      sent_by, sent_at; unique (beneficiary_id, wamid); RLS select for account members; writes only
      via RPC);
    - `crm_pruebas_faltantes(op)`: current beneficiaries without a proof, 0 when fewer than 2;
    - `crm_registrar_prueba_beneficiario(op, beneficiary, {wamid, path?, caption?})`: agent+,
      ready_to_transfer only, current beneficiary of that op only, idempotent per wamid; does not
      change status; returns `{registered, missing}`;
    - `crm_entregar_operacion` (114 verbatim + one check): in `proof_sent` mode it refuses while
      `crm_pruebas_faltantes > 0`, with the error "every beneficiary needs its delivery proof before
      delivering (N missing)". One beneficiary and `no_proof` / `skip_proof` are unchanged.
  - ROLLBACK-143 restores 114's function and drops the new objects.
  - Assertions:
    - `beneficiary-proofs.sql`: RED before 143 (function missing), GREEN 8/8 after.
    - Regressions GREEN: delivery-feed-evidence 2/2, feed-mixed 9/9, feed-matrix 20/20,
      reparto-auto 13/13.
  - Found: `psql -1` COMMITS at the end. Files with their own SAVEPOINT/ROLLBACK TO are safe, but
    `reparto-auto.sql` must run as `BEGIN; <file> ROLLBACK;`. Two earlier `-1` runs left fixture
    data in staging: contacts `test127` 59900127001 and 59900127991, with their account, deal and
    op. Cleanup pending.
  - Panel contract for P3:
    1. For each current beneficiary: send its image (caption for Zelle), then
       `crm_registrar_prueba_beneficiario`.
    2. Then `crm_entregar_operacion` with the last proof's evidence.

- 2026-09-29 P3 — Panel done (commit `9752af5`).
  - New pure module `src/lib/pipelines/send-beneficiary-proofs.ts`: sends + registers each
    beneficiary's proof in order (reusing `uploadProof`/`sendProofImage` deps, same as
    `deliver-with-proof.ts`). Retry-safe: an item whose `sentWamid` is already set skips upload/send
    and only re-calls `registerProof` (idempotent per (beneficiary, wamid), migration 143).
  - `deliver-with-proof.ts`: extended `DeliveryProofDraft` with optional `sentPath`; the stage-only
    retry branch now includes `path` in `moveToDelivered`'s evidence when the draft carries one —
    absent (unchanged behavior) on an ordinary single-proof retry, present when the multi-beneficiary
    flow's synthetic final draft carries the last beneficiary's path.
  - New route `POST /api/remittance-operations/{operationId}/beneficiaries/{beneficiaryId}/proof` +
    command `registerBeneficiaryProof`, calling `crm_registrar_prueba_beneficiario` (143). Same
    auth/beta-flag/UUID/RPC-error-mapping pattern as the sibling `deliver` route.
  - `complete-transfer-container.tsx`: new optional `beneficiaries?: {id, isZelle}[]` prop (default
    `[]`, so existing callers/tests are unaffected). With 2+, the container keeps a per-beneficiary
    draft map (extends the existing single-draft pattern, keyed by beneficiary id, `dealId` still the
    operation id on every entry) and renders the new `CompleteTransferMultiSection` (one
    `DeliveryProofPanel` per beneficiary, caption only for the Zelle ones) instead of
    `CompleteTransferSection`. Confirm: `sendBeneficiaryProofs` sends+registers every beneficiary in
    order, then `deliverDeal` runs once with a synthetic draft carrying the LAST beneficiary's
    `sentWamid`/`sentPath` — reusing `deliverDeal`'s existing "already sent" branch, so it goes
    straight to the stage update rather than re-uploading/re-sending. A partial failure's retry
    re-enters the same function: already-sent beneficiaries are skipped (send) and only re-registered;
    once all are sent, the retry naturally reaches the final `deliverDeal` call. The document-level
    paste listener (single-proof convenience) is disabled in this mode — each panel's own paste still
    works when it has focus. The "complete without screenshot" checkbox always calls the existing
    single-draft `run({skip:true})` directly, bypassing the per-beneficiary flow entirely, matching
    that `crm_entregar_operacion`'s missing-proofs check only applies to `proof_sent` mode.
  - `remittance-operation-card.tsx` passes `operation.beneficiaries.map(b => ({id, isZelle: b.beneficiaryType === 'zelle'}))`.
  - 0/1-beneficiary operations: `beneficiaries.length < 2` keeps the original single-draft code path
    completely untouched (same functions, same JSX branch) — not just behaviorally equivalent.
  - TDD: RED confirmed for the right reason before each new module (missing module / missing route /
    missing exported function / component didn't exist / container didn't accept the prop) at each
    step, then GREEN. 11 new tests in `send-beneficiary-proofs.test.ts`, 1 new in
    `deliver-with-proof.test.ts` (sentPath propagation), 29 in the new route's `route.test.ts`, 3 new
    in `commands.test.ts`, 6 in the new `complete-transfer-multi-section.test.tsx`, 5 new in
    `complete-transfer-container.test.tsx` (2 beneficiaries: renders 2 panels/caption-only-for-Zelle;
    happy path N sends → N registers → 1 deliver in order; partial failure on image 2 stops + retry
    resends only image 2; skip bypasses per-beneficiary flow; 1-beneficiary regression), 1 new in
    `remittance-operation-card.test.tsx`. Full existing suites in every touched file stay green.
  - Verification: `npx vitest run` on the 12 touched/new test files — 294/294 passed. `npm run test` —
    1595/1597 passed, the only failures are the 2 pre-existing timezone tests in
    `src/lib/dashboard/date-utils.test.ts` (untouched file, unrelated). `npx tsc --noEmit` — clean.
    `npx eslint` on every touched/new file — clean.
  - Not decided by this task (left for the user):
    - the per-beneficiary panel's label is an ordinal ("Beneficiary 1", "Beneficiary 2") rather than
      the beneficiary's own name — avoids threading a name through just for a UI label; can change if
      the operator would rather see names;
    - beneficiary send order is `operation.beneficiaries`' existing order (position-based, as returned
      by the RPC) — not re-specified by the user;
    - a register-RPC failure (send succeeded, record failed) surfaces the same generic "Could not send
      the screenshot: {message}" banner text as a send failure — no separate copy was requested for
      that case.

## Next step
P4 — staging end-to-end (2-Zelle reparto + a mixed one), then production build/deploy with the user's
go-ahead. Note: P3 came in well over the ~500–700 line forecast (~1,718 lines, mostly tests: the new
per-beneficiary send/register pure module, its route, and container/component tests each needed their
own coverage) — flagging per the delivery heuristic, not re-splitting after the fact.

<!-- previous next step -->
P3 — panel.

<!-- previous next step -->
P2 — DB: `remittance_beneficiary_proofs` table + RPC, staging migration.
