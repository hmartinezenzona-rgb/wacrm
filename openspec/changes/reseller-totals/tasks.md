# Tasks: Reseller accumulated GYD total with resettable counter

Change: `reseller-totals`. Inputs: `proposal.md`, `specs/reseller-identity/spec.md`, `specs/reseller-totals/spec.md`, `design.md`, Engram `sdd/reseller-totals/decisions`.

Execution mode: interactive. Delivery strategy: `ask-on-risk`. Artifacts in English.

**Production bundle rule:** `395_reseller_identity.sql` and `396_reseller_tag_guard.sql` MUST reach production in the same `aplicar` call. Between them, an agent could change bot behaviour through the tag. `397_reseller_totals.sql` may ride the same bundle or be applied separately once its own apply is approved. The panel ships after the migrations it calls.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~2,150–2,650 authored lines (S1 ~850–1,000; S2 ~130–160; S3 ~1,150–1,450) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 (395) → PR 2 (396 + panel tag controls) → PR 3 (reports + automation check) → PR 4 (397) → PR 5 (totals API) → PR 6 (totals UI) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain (owner 2026-11-24): six slices delivered in order on feat/port-chat-operations-calculator; no PR flow in this repo, so each slice is a set of work-unit commits verified in staging before the next; production bundles per slice with owner go-ahead |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain, six slices in order (owner 2026-11-24). Slices with disjoint files may be built in parallel; dependent slices stay sequential.
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | 395 identity switch: helpers, backfill, bot rewrite, safety check | PR 1 | `infra/db/staging-migracion.sh aplicar supabase/migrations/395_reseller_identity.sql supabase/staging/assertions/reseller-identity.sql supabase/migrations/ROLLBACK-395-reseller-identity.sql cerebro_es_revendedor` | staging dry-run + apply + rollback md5 + `relacionadas` | `ROLLBACK-395-reseller-identity.sql` restores the allow-list bot body; backfilled tags stay and are listed by audit rows |
| 2 | 396 tag guard + panel tag controls (admin-only, audited) | PR 2 | `infra/db/staging-migracion.sh aplicar supabase/migrations/396_reseller_tag_guard.sql supabase/staging/assertions/reseller-tag-guard.sql supabase/migrations/ROLLBACK-396-reseller-tag-guard.sql` + `npx vitest run src/lib/resellers src/lib/auth/roles.test.ts src/components/contacts --maxWorkers=4` | staging assertion with agent/admin/owner/no-session claims; `panel-local-staging.sh` as agent and admin | `ROLLBACK-396-reseller-tag-guard.sql` removes the trigger; agents return to 017 permissions |
| 3 | Read-only pre-apply reports + automation verification | PR 3 | `infra/db/staging-migracion.sh` not applicable; run `supabase/staging/check-reseller-identity.sql` through the shared `psql_staging` helper | owner runs the same file read-only on production before apply | Delete the script; no schema or data change |
| 4 | 397 totals schema + helper + five RPCs | PR 4 | `infra/db/staging-migracion.sh aplicar supabase/migrations/397_reseller_totals.sql supabase/staging/assertions/reseller-totals.sql supabase/migrations/ROLLBACK-397-reseller-totals.sql` | staging fixture assertion incl. md5 of untouched operation rows | `ROLLBACK-397-reseller-totals.sql` drops RPCs, helper, tables and index (export history first) |
| 5 | Totals API: payload parsers, read model, five routes | PR 5 | `npx vitest run src/lib/resellers src/app/api/revendedores --maxWorkers=4` | route tests with mocked auth + staging RPC smoke from the panel | Revert routes/libs; DB read RPCs remain harmless |
| 6 | Totals UI: sidebar block, dialogs, history, Finanzas tab | PR 6 | `npx vitest run src/components/resellers src/components/finanzas src/components/inbox/contact-sidebar.test.tsx --maxWorkers=4` | `wacrm-probar-staging` full flow with PRUEBA fixtures | Revert components/tab wiring; the feature disappears from the UI |

## Dependency and Parallelism Map

- Sequential spine: `1.1 → 1.2 → 1.3`; `1.4 → 1.5 → 1.6`; `3.1 → 3.2 → 3.3`; Phase 4 strictly in order.
- Parallel after `1.2` is drafted: `1.4` (guard assertion authoring), `1.7` (TypeScript rule mirror), `2.1` (report script) and `3.1` (totals assertion authoring).
- Parallel after `1.7`: `1.8`, `1.9`, `1.10`, `1.11` touch different components and can be split across authors; coordinate only `messages/*.json`.
- Parallel after `3.2`: `3.4` and `3.5`; after both, `3.6`–`3.10` are independent routes; after `3.6`–`3.10`, `3.11`–`3.16` are independent components.
- Global serialization: `messages/es.json` and `messages/en.json` are edited by `1.7` and `3.18`; run `1.12` and `3.20` last.

## Phase 1 — S1: Reseller identity (migrations 395 + 396; one production bundle)

Strict TDD: every task writes its failing test and records the RED result before implementation.

- [ ] 1.1 (RED) Write the failing identity assertion `supabase/staging/assertions/reseller-identity.sql` covering the tag rule, backfill and bot parity.
  - Files: create `supabase/staging/assertions/reseller-identity.sql`; reference `supabase/migrations/109_*.sql` (read-only) for the current `cerebro_es_revendedor` body and `supabase/migrations/383_*.sql` (read-only) for the audit action list.
  - Spec: `reseller-identity/spec.md` — Tag-based reseller identity; Single shared definition for panel and bot; Allow-list to tag migration; Untag and retag preserve contact history.
  - Cases: "Revendedor", "  revendedor  ", "REVENDEDOR"; "Revendedores"/"Revendedór"/untagged do not match; a tag from another account does not count; duplicate matching tags yield one reseller; bot boolean before/after for allow-list contacts; inactive allow-list row tags nothing; existing account tag reused; already-tagged contact idempotent; backfill writes `migration_reseller_tag_added` audit rows.
  - Test/RED: run the assertion alone against staging through the shared helper and record the expected failure (missing helper function/objects). Then keep the file as the GREEN target.
  - Verify RED: `source infra/db/lib-migracion.sh && psql_staging < supabase/staging/assertions/reseller-identity.sql` fails with a missing `reseller_tag_name_matches`/`reseller_contact_is_tagged` error, not `ALL PASS`.
  - Depends: none. Parallel: with `1.4`, `1.7`, `2.1`, `3.1`.

- [ ] 1.2 (GREEN) Create `supabase/migrations/395_reseller_identity.sql` and `supabase/migrations/ROLLBACK-395-reseller-identity.sql`.
  - Files: create both migrations; read live objects first with `pg_get_functiondef` and the live `remittance_admin_audit_action_chk` (do not trust the 383 list blindly).
  - Spec: `reseller-identity/spec.md` — all identity, migration, deprecation and history requirements.
  - Content: `reseller_tag_name_matches(text)` and `reseller_contact_is_tagged(uuid)` helpers; extend the audit action list with `migration_reseller_tag_added`, `human_reseller_counter_reset`, `human_reseller_adjustment`, and the owner-accepted tag audit actions `human_reseller_tag_added`/`human_reseller_tag_removed`; reuse-or-create the "Revendedor" tag per account and tag active allow-list phones only, audited row by row; rewrite `cerebro_es_revendedor(conv)` to the tag rule with the same signature/ACL (restate the 109 REVOKE/GRANT); run the "no current reseller is lost" `DO` check before commit; `COMMENT ON TABLE public.cerebro_revendedores` marks it deprecated/read-only; `NOTIFY pgrst`.
  - ROLLBACK: restore the exact 109 body (md5 must match the pre-migration value), drop both helpers, clear the comment, re-add the previous audit action list `NOT VALID`, and document that backfilled tags stay plus the not-executed removal query driven by `migration_reseller_tag_added` audit rows.
  - Test: the assertion from `1.1` must flip from RED to `ALL PASS (rolled back on purpose)`.
  - Verify: `DRY_ONLY=1 infra/db/staging-migracion.sh aplicar supabase/migrations/395_reseller_identity.sql supabase/staging/assertions/reseller-identity.sql supabase/migrations/ROLLBACK-395-reseller-identity.sql cerebro_es_revendedor`, then the same command without `DRY_ONLY` (dry-run OK, apply OK, assertion OK, rollback md5 equal).
  - Depends: `1.1`. Sequential.

- [ ] 1.3 Verify no deposit-path regression after 395.
  - Files: `supabase/migrations/395_reseller_identity.sql`; assertion corpus under `supabase/staging/assertions/` (read-only).
  - Spec: `reseller-identity/spec.md` — Existing reseller deposit behavior is preserved; Bot parity after migration.
  - Test/Verify: `infra/db/staging-migracion.sh relacionadas supabase/migrations/395_reseller_identity.sql cerebro_es_revendedor` shows `TOTAL n | SAME n | DIFF 0`. Repeat with the pattern `cerebro_registrar_deposito`; any new DIFF blocks the slice.
  - Depends: `1.2`. Sequential before 396 verification.

- [ ] 1.4 (RED) Write the failing tag-guard assertion `supabase/staging/assertions/reseller-tag-guard.sql`.
  - Files: create `supabase/staging/assertions/reseller-tag-guard.sql`; reference `supabase/staging/assertions/agent-service-change-guards.sql` (read-only) for the `request.jwt.claims` fixture pattern.
  - Spec: `reseller-identity/spec.md` — Admin-only editing of the reseller tag.
  - Cases: agent INSERT of the reseller tag → 42501 with `reseller_tag_admin_only`; agent DELETE → 42501 and the row remains; admin and owner succeed; agent insert/delete of another tag succeeds; no user session (`auth.uid()` NULL) succeeds; agent re-insert of an existing `(contact_id, tag_id)` pair succeeds; agent deleting the contact cascades without a guard failure (owner-accepted default: agents may delete a reseller contact); agent UPDATE moving a reseller tag → 42501; add/remove writes a `human_reseller_tag_added`/`human_reseller_tag_removed` audit row.
  - Test/RED: run the assertion alone on staging and record the expected failure (the agent attempt succeeds today, so the expected 42501 does not occur).
  - Verify RED: `source infra/db/lib-migracion.sh && psql_staging < supabase/staging/assertions/reseller-tag-guard.sql` fails before `ALL PASS`.
  - Depends: none (authoring). Parallel: with `1.2`/`1.3`.

- [ ] 1.5 (GREEN) Create `supabase/migrations/396_reseller_tag_guard.sql` and `supabase/migrations/ROLLBACK-396-reseller-tag-guard.sql`.
  - Files: create both migrations.
  - Spec: `reseller-identity/spec.md` — Admin-only editing of the reseller tag; Service path without a user session is not blocked; Panel reflects the tag guard (DB side).
  - Content: `contact_tags_reseller_guard()` (`plpgsql SECURITY DEFINER SET search_path public`) and a `BEFORE INSERT OR UPDATE OR DELETE` row trigger on `contact_tags`. Allow when `auth.uid()` is NULL; allow existing-pair INSERT, no-op UPDATE, and cascade DELETE; otherwise require `is_account_member(t.account_id, 'admin')`, else `RAISE EXCEPTION ... ERRCODE '42501' HINT 'reseller_tag_admin_only'`. Write the owner-accepted audit rows for reseller-tag add/remove using `wacrm_current_actor()`. Do not change permissions for other tags.
  - ROLLBACK: drop the trigger and function only.
  - Test: the assertion from `1.4` must reach `ALL PASS (rolled back on purpose)`.
  - Verify: `DRY_ONLY=1 infra/db/staging-migracion.sh aplicar supabase/migrations/396_reseller_tag_guard.sql supabase/staging/assertions/reseller-tag-guard.sql supabase/migrations/ROLLBACK-396-reseller-tag-guard.sql`, then without `DRY_ONLY`; all four steps OK.
  - Depends: `1.4`; the `human_reseller_tag_*` actions must already exist from `1.2`. Sequential.

- [ ] 1.6 Verify the 395+396 production bundle on staging.
  - Files: `supabase/migrations/395_reseller_identity.sql`, `supabase/migrations/396_reseller_tag_guard.sql`.
  - Test/Verify: with 396 applied on staging, run `DRY_ONLY=1 infra/db/staging-migracion.sh aplicar supabase/migrations/395_reseller_identity.sql supabase/staging/assertions/reseller-identity.sql supabase/migrations/ROLLBACK-395-reseller-identity.sql cerebro_es_revendedor` and confirm the 395 assertion still passes with the guard present (the backfill runs with no user session, so the guard must not block it). Record this as the bundle proof and note the production rule: 395 and 396 are applied in one `aplicar` call.
  - Depends: `1.3`, `1.5`. Sequential before Phase 4.

- [ ] 1.7 (RED→GREEN) Add the TypeScript rule mirror, the admin capability predicate and the shared i18n keys.
  - Files: create `src/lib/resellers/tag-rule.ts` and `src/lib/resellers/tag-rule.test.ts`; modify `src/lib/auth/roles.ts` and `src/lib/auth/roles.test.ts`; modify `messages/es.json` and `messages/en.json`.
  - Spec: `reseller-identity/spec.md` — Tag-based reseller identity; Panel reflects the tag guard; `reseller-totals/spec.md` — Contact sidebar visibility; Finanzas reseller list.
  - RED: write table-driven `isResellerTagName` tests (case, surrounding spaces, plural/accent variants, null/empty) and a `canManageResellers("admin"|"owner")` true / `"agent"|"viewer"` false test; run them and record the failure.
  - GREEN: `isResellerTagName(name)` mirrors `lower(btrim(name)) = 'revendedor'` and is UI gating only; `canManageResellers(role) = hasMinRole(role, "admin")`; add `Contacts.*.resellerTagAdminOnly`, `Contacts.*.resellerTagBotHint`, `Finanzas.tabs.revendedores`, and the `Resellers.*` key namespace used by Phase 3.
  - Verify: `npx vitest run src/lib/resellers/tag-rule.test.ts src/lib/auth/roles.test.ts src/i18n/messages-parity.test.ts --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: none for tests; can start in parallel with `1.2`. Feeds `1.8`–`1.11` and Phase 3.

- [ ] 1.8 (RED→GREEN) Gate the reseller tag chip in the contact detail view.
  - Files: modify `src/components/contacts/contact-detail-view.tsx`; create `src/components/contacts/contact-detail-view.reseller-tag.test.tsx`; consume `src/lib/resellers/tag-rule.ts` and `src/hooks/use-auth.ts` (read-only) for `accountRole`.
  - Spec: `reseller-identity/spec.md` — Panel reflects the tag guard; `reseller-totals/spec.md` — Reset copy clarity (bot-effect hint context).
  - RED: agent sees the reseller chip disabled with the `resellerTagAdminOnly` explanation; admin sees it enabled with the `resellerTagBotHint`; agent can still toggle other chips.
  - GREEN: render the reseller chip disabled with `title`/hint for non-admins, keep other chips unchanged, show the bot-effect hint for admins.
  - Verify: `npx vitest run src/components/contacts/contact-detail-view.reseller-tag.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `1.7`. Parallel with `1.9`–`1.11` if `messages/*.json` changes are coordinated.

- [ ] 1.9 (RED→GREEN) Surface `toggleTag` errors in a toast instead of failing silently.
  - Files: modify `src/components/contacts/contact-detail-view.tsx`; extend `src/components/contacts/contact-detail-view.reseller-tag.test.tsx`.
  - Spec: `reseller-identity/spec.md` — Agent is refused when adding/removing the reseller tag; "clear, readable error and MUST NOT change contact tags".
  - RED: a mocked `contact_tags` insert/delete error shows an error toast and leaves the chip state unchanged; the 42501 message is readable (no generic error).
  - GREEN: check the Supabase error on both insert and delete paths and call `toast.error` with the message; keep optimistic state only on success.
  - Verify: `npx vitest run src/components/contacts/contact-detail-view.reseller-tag.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `1.8` (same file; sequential to avoid conflicting edits).

- [ ] 1.10 (RED→GREEN) Replace contact-form tag delete-all + insert-all with a diff sync.
  - Files: modify `src/components/contacts/contact-form.tsx`; create `src/components/contacts/contact-form.tag-diff.test.tsx`.
  - Spec: `reseller-identity/spec.md` — Admin-only editing of the reseller tag (agents must keep editing a reseller contact's other fields); `reseller-identity/spec.md` — Agent keeps permissions on other tags.
  - RED: saving an edited reseller contact as an agent issues only the needed tag operations: no DELETE of an unchanged reseller tag; add/remove only changed ids; a removed non-reseller tag is deleted; an added tag is inserted; no duplicate `UNIQUE(contact_id, tag_id)` violation.
  - GREEN: compute `toAdd = selected - current` and `toRemove = current - selected`, issue only those statements, and surface errors. Do not touch tags when the selection is unchanged.
  - Verify: `npx vitest run src/components/contacts/contact-form.tag-diff.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `1.7`. Parallel with `1.8`, `1.9`, `1.11` if component files do not overlap.

- [ ] 1.11 (RED→GREEN) Gate reseller-tag assignment during import for non-admins.
  - Files: modify `src/lib/contacts/resolve-import-tags.ts`, `src/lib/contacts/resolve-import-tags.test.ts`, `src/components/contacts/import-modal.tsx`; add a test in `src/components/contacts/import-modal.reseller-tag.test.tsx`.
  - Spec: `reseller-identity/spec.md` — Admin-only editing of the reseller tag; Panel reflects the tag guard.
  - RED: with `canAssignResellerTag = false`, an imported "Revendedor" tag is skipped and reported like an unknown tag name; non-reseller tags are assigned; with `true` (admin default), the reseller tag is assigned.
  - GREEN: add the optional `canAssignResellerTag` flag (default `true`), pass `canManageResellers(role)` from the modal, and report skipped reseller tags in the import result.
  - Verify: `npx vitest run src/lib/contacts/resolve-import-tags.test.ts src/components/contacts/import-modal.reseller-tag.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `1.7`. Parallel with `1.8`–`1.10`.

- [ ] 1.12 Verify the whole S1 panel slice and locale parity.
  - Files: all Phase 1 panel files.
  - Verify: `npx vitest run src/lib/resellers src/lib/auth/roles.test.ts src/components/contacts --maxWorkers=4`, `npx vitest run src/i18n/messages-parity.test.ts --maxWorkers=4`, and `npx tsc --noEmit`. Record RED/GREEN evidence from `1.7`–`1.11`.
  - Depends: `1.7`–`1.11`. Sequential, last in Phase 1.

## Phase 2 — S2: Pre-apply reports and owner decisions

- [x] 2.1 Create the read-only identity report script `supabase/staging/check-reseller-identity.sql`.
  - Files: create `supabase/staging/check-reseller-identity.sql`; use `supabase/staging/check-production-clean.sql` (read-only) as the structural pattern.
  - Spec: `reseller-identity/spec.md` — Pre-apply reports; `design.md` Decision 6.
  - Content: `BEGIN READ ONLY` … four labelled result sets … `ROLLBACK`:
    A. active allow-list phones with no matching contact (stop being resellers);
    B. contacts already carrying a matching tag whose phone is not on the active allow-list (become resellers);
    C. contacts the backfill will tag and accounts where the tag will be created;
    D. near-miss tag names (`name ILIKE '%revend%'` and not matching the rule).
  - Critical: use the inline predicate `lower(btrim(name)) = 'revendedor'` (and an inline account-scoped join), not the 395 helpers, so the file runs read-only on production BEFORE 395 exists.
  - Verify: `source infra/db/lib-migracion.sh && psql_staging < supabase/staging/check-reseller-identity.sql` prints four result sets and ends without error (read-only rollback).
  - Depends: none. Parallel with Phase 1 authoring.
  - Progress (2026-11-24): created the script with four labelled result sets (`A_count`/`A_phone`, `B_count`/`B_phone`, `C_contact_count`/`C_contact_phone`/`C_account_count`/`C_account`, `D_count`/`D_tag_name`), the inline `lower(btrim(t.name)) = 'revendedor'` predicate and account-scoped joins, inside `BEGIN; SET TRANSACTION READ ONLY;` / `ROLLBACK;`. Validated on staging with `bash -c 'source infra/db/lib-migracion.sh && psql_staging < supabase/staging/check-reseller-identity.sql'` (the lib needs bash) → exit 0: `A_count: 0`, `B_count: 0`, `C_contact_count: 0`, `C_account_count: 0`, `D_count: 0`. Staging baseline: 0 allow-list rows (0 active), 3 contacts, 3 contact_tags, 4 tags, none matching `%revend%`, so the zeros are genuine. Commit `dc5b4297`.

- [ ] 2.2 Run the reports on staging and reconcile them with the 395 backfill.
  - Files: `supabase/staging/check-reseller-identity.sql`; staging DB (read-only).
  - Spec: `reseller-identity/spec.md` — Pre-apply reports; Matching active phone appears in neither report.
  - Test: run the script on staging after `1.2`; confirm A/B/D lists match the fixture expectation, and C matches the contacts actually tagged by the 395 assertion (no allow-list phone with a contact is missing the tag).
  - Verify: capture the four result sets as evidence and compare C against the `migration_reseller_tag_added` audit rows. Any mismatch blocks production.
  - Depends: `1.2`. Parallel with `1.5` authoring.
  - Prepared command (not run; blocked on `1.2` = 395 applied on staging): `bash -c 'source infra/db/lib-migracion.sh && psql_staging < supabase/staging/check-reseller-identity.sql'`. Reconcile `C_contact_count` with `SELECT count(*) FROM remittance_admin_audit WHERE action = 'migration_reseller_tag_added' AND table_name = 'contact_tags'` through the same read-only helper; any mismatch blocks production.

- [ ] 2.3 Produce the production report and obtain the owner's tag decision.
  - Files: `supabase/staging/check-reseller-identity.sql`; production DB accessed read-only through the authorized read-only path chosen by the owner.
  - Spec: `reseller-identity/spec.md` — Reports are available before production apply; `proposal.md` — Remaining owner confirmations.
  - Owner go-ahead required: yes, before reading production and before any tag edit.
  - Test/Verify: show the owner lists A–D (privacy-scrubbed counts plus the rows the owner needs), record the decision for every unmatched phone and every newly-reseller contact, and stop if any list is ambiguous.
  - Depends: `2.1`, `2.2`. Sequential before Phase 4.
  - Prepared command (do NOT run without owner go-ahead): `docker run --rm --network host -i --env-file ~/.config/wacrm/prod-db.env postgres:17 sh -c 'psql -X -q -A -t "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 -f -' < supabase/staging/check-reseller-identity.sql` (owner may instead paste the file into the production SQL editor).
  - Prepared report template: `A: count=<n> | phones=<…> -> owner decision: keep as reseller / accept loss`; `B: count=<n> | phones=<…> -> owner decision: keep tag / remove tag before apply`; `C: contacts=<n> | accounts creating tag=<n>`; `D: count=<n> | names=<…> -> owner decision: ignore / rename`. Record one decision per row and stop if any list is ambiguous.

- [x] 2.4 Verify that no automation adds or removes the "Revendedor" tag.
  - Files: n8n workflows via `.claude/skills/wacrm-cerebro-n8n/SKILL.md` (read-only) and the panel automations/flows configuration (read-only); `src/app/api/v1/` (read-only) for API-key tag writers.
  - Spec: `reseller-identity/spec.md` — Service path without a user session is not blocked; owner-accepted default 6.
  - Test/Verify: inspect read-only exports and search for `contact_tags`, `tags`, `Revendedor` writes; document every match. If an automation can change the tag, stop and report to the owner before the production apply, because no-session callers bypass the guard by design.
  - Depends: none; complete before `2.3` sign-off. Read-only.
  - Progress (2026-11-24, read-only): n8n production `jEzlVLCLUaJhVwzs` (126 nodes, versionId `a3d439e9-380f-41fe-bdb2-832e48e84e82`, Decisor md5 `d64e8009` = repo) has no `contact_tags`/`tags` writes; only reads in "Contexto conversacion" (admin/assignee) and `es_revendedor` returned by the RPC in "Registrar deposito auto". Decisor `pruebas/decisor/decisor.jscode`: 0 `revend`/`es_revendedor`/`tags` references. `infra/ia/`: read-only tag reads only (`colectar_dia.py`, `mejora_nocturna.py` prompt text), no writes. Production configuration read-only: `automation_steps` add_tag/remove_tag = 0, `flow_nodes` set_tag = 0, reseller-tag hits = 0. DB functions: `sync_tags_cliente` writes only nuevo/cliente/recurrentes; `merge_duplicate_contacts()` can move/drop `contact_tags` during dedup. Residual by-design exposure: `/api/v1/contacts` POST/PATCH with `contacts:write` uses a service-role client (`auth.uid()` NULL) and can set arbitrary tag names, including "Revendedor"; no n8n node calls it today. Verdict: no automation adds or removes the "Revendedor" tag today.

- [ ] 2.5 Apply the owner-approved tag edits in the panel before the production apply.
  - Files: panel contact tag UI (no code change); production data via admin panel actions.
  - Spec: `reseller-identity/spec.md` — Pre-apply reports; Tag-based reseller identity.
  - Owner go-ahead required: yes, for each contact to keep/gain/lose the tag.
  - Test/Verify: an admin applies the confirmed edits in the currently deployed panel, then `2.1` is re-run read-only on production to confirm A/B/C reflect the decision. Do not edit tags during the migration window.
  - Depends: `2.3`, `2.4`. Sequential before `4.1`.

## Phase 3 — S3: Reseller totals (migration 397, RPCs, API, sidebar, Finanzas)

- [ ] 3.1 (RED) Write the failing totals assertion `supabase/staging/assertions/reseller-totals.sql`.
  - Files: create `supabase/staging/assertions/reseller-totals.sql`; reference `supabase/staging/assertions/resumen-from-ledger.sql` (read-only) for fixture style.
  - Spec: `reseller-totals/spec.md` — all requirements.
  - Cases: every qualifying status included, `incident` included; `cancelled`, pre-deposit and non-GYD excluded; another contact's operations excluded; empty period = 0; operations and adjustments returned separately with total = sum; grand total over tagged contacts only; adjustments +/−, zero rejected, optional reason, append-only; reset single; reset all atomic with one batch id; **reset all skips resellers whose current total is 0 (owner-accepted default, overriding the proposal's "one marker per tagged reseller")**; closed period appears in history, ordered, open period distinguishable; expected-amount mismatch → 40001; viewer reads; agent writes refused; untag/retag keeps history; md5 of `remittance_operations` rows unchanged before/after resets and adjustments.
  - Test/RED: run the assertion alone and record the expected failure on missing tables/RPCs.
  - Verify RED: `source infra/db/lib-migracion.sh && psql_staging < supabase/staging/assertions/reseller-totals.sql` fails before `ALL PASS`.
  - Depends: `1.2` for the tag helpers (parallel authoring is possible but the fixture joins rely on the identity rule).

- [ ] 3.2 (GREEN) Create `supabase/migrations/397_reseller_totals.sql` and `supabase/migrations/ROLLBACK-397-reseller-totals.sql`.
  - Files: create both migrations.
  - Spec: `reseller-totals/spec.md` — all requirements; `design.md` Decisions 8–12.
  - Content: `reseller_counter_resets` and `reseller_total_adjustments` tables with constraints/indexes; RLS SELECT for members, no write policy, REVOKE anon/authenticated then GRANT SELECT; `reseller_ledger_no_update()` BEFORE UPDATE trigger on both; `CREATE INDEX IF NOT EXISTS remittance_operations_contact_created_idx ON public.remittance_operations (contact_id, created_at) WHERE contact_id IS NOT NULL`; `_reseller_period_totals(...)` helper; the five RPCs `crm_revendedores_resumen`, `crm_revendedor_detalle`, `crm_revendedor_ajustar`, `crm_revendedor_reiniciar`, `crm_revendedores_reiniciar_todos`; per-account advisory lock `hashtextextended('reseller-totals:' || account_id::text, 0)`; expected-amount check raising `40001`; reset all reads totals under the lock and writes markers only for resellers whose total is non-zero; audit rows with the actions from `1.2`; REVOKE PUBLIC/anon and GRANT authenticated on every RPC.
  - Performance guard: before the production apply, record `count(*)` on `remittance_operations` so the index build cost is known; the index statement runs inside the migration transaction.
  - ROLLBACK: drop the five RPCs, helper, trigger function, both tables and the index; header says to export the tables first if history must be kept.
  - Test: the assertion from `3.1` reaches `ALL PASS (rolled back on purpose)`.
  - Verify: `DRY_ONLY=1 infra/db/staging-migracion.sh aplicar supabase/migrations/397_reseller_totals.sql supabase/staging/assertions/reseller-totals.sql supabase/migrations/ROLLBACK-397-reseller-totals.sql`, then without `DRY_ONLY`; all steps OK.
  - Depends: `3.1`; `1.2` applied on staging. Sequential.

- [ ] 3.3 Verify 397 staging behavior and related-base regression.
  - Files: `supabase/migrations/397_reseller_totals.sql`; assertion corpus (read-only).
  - Spec: `reseller-totals/spec.md` — Derived, correction-safe total; Concurrent writes remain consistent.
  - Test/Verify: `infra/db/staging-migracion.sh relacionadas supabase/migrations/397_reseller_totals.sql crm_revendedor` → `DIFF 0`; re-run the totals assertion; confirm no `remittance_operations`, deposit or calculator row changed (md5 assertion).
  - Depends: `3.2`. Sequential.

- [ ] 3.4 (RED→GREEN) Add request payload parsers `src/lib/resellers/payloads.ts`.
  - Files: create `src/lib/resellers/payloads.ts` and `src/lib/resellers/payloads.test.ts`.
  - Spec: `reseller-totals/spec.md` — Manual adjustments; Reset a reseller; Reset all resellers; `design.md` API contract.
  - RED: table-driven tests for `parseResetBody`, `parseResetAllBody`, `parseAdjustBody`: reason trimmed, nullable, max 500; amount finite, non-zero; expected totals optional finite; non-object and invalid JSON rejected.
  - GREEN: implement the parsers with no I/O, returning typed results or a 400-shaped error.
  - Verify: `npx vitest run src/lib/resellers/payloads.test.ts --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.2` (contract). Parallel with `3.5`.

- [ ] 3.5 (RED→GREEN) Add the RPC read-model mappers `src/lib/resellers/read-model.ts`.
  - Files: create `src/lib/resellers/read-model.ts` and `src/lib/resellers/read-model.test.ts`.
  - Spec: `reseller-totals/spec.md` — Per-reseller total with separate lines; Grand total; Period history per reseller; `design.md` Interfaces.
  - RED: map snake_case jsonb to `ResellerSummary`, `ResellerDetail`, `ResellerAdjustment`, `ResellerPeriod`; assert totals, counts, null handling, `is_reseller: false`, empty lists, ordering passthrough.
  - GREEN: implement the pure mappers.
  - Verify: `npx vitest run src/lib/resellers/read-model.test.ts --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.2`. Parallel with `3.4`.

- [ ] 3.6 (RED→GREEN) Create `GET /api/revendedores`.
  - Files: create `src/app/api/revendedores/route.ts` and `src/app/api/revendedores/route.test.ts`.
  - Spec: `reseller-totals/spec.md` — Read access for members; Grand total; `design.md` Panel API.
  - RED: member allowed (viewer/agent/admin/owner); calls `crm_revendedores_resumen` with the current account; maps via `read-model`; sets `Cache-Control: private, no-store`; 401 from the auth helper; RPC error mapped by `rpcErrorResponse`.
  - GREEN: implement with `getCurrentAccount()`.
  - Verify: `npx vitest run src/app/api/revendedores/route.test.ts --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.4`, `3.5`. Parallel with `3.7`–`3.10`.

- [ ] 3.7 (RED→GREEN) Create `POST /api/revendedores/reiniciar` (reset all).
  - Files: create `src/app/api/revendedores/reiniciar/route.ts` and `route.test.ts`.
  - Spec: `reseller-totals/spec.md` — Reset all resellers; Read access for members, writes admin-only.
  - RED: `requireRole("admin")` (agent/viewer → 403); body parsing; calls `crm_revendedores_reiniciar_todos` with `p_account_id`, `p_motivo`, `p_total_esperado_gyd`; 409 on `40001`; response `{ batch }`; `no-store`.
  - GREEN: implement.
  - Verify: `npx vitest run src/app/api/revendedores/reiniciar/route.test.ts --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.4`, `3.5`. Parallel with `3.6`, `3.8`–`3.10`.

- [ ] 3.8 (RED→GREEN) Create `GET /api/revendedores/[contactId]`.
  - Files: create `src/app/api/revendedores/[contactId]/route.ts` and `route.test.ts`.
  - Spec: `reseller-totals/spec.md` — Per-reseller total; Period history; Read access for members.
  - RED: member allowed; non-UUID → 400; calls `crm_revendedor_detalle`; 404 on `P0002`; `{ reseller }`; `no-store`.
  - GREEN: implement.
  - Verify: `npx vitest run src/app/api/revendedores/[contactId]/route.test.ts --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.4`, `3.5`. Parallel.

- [ ] 3.9 (RED→GREEN) Create `POST /api/revendedores/[contactId]/reiniciar`.
  - Files: create `src/app/api/revendedores/[contactId]/reiniciar/route.ts` and `route.test.ts`.
  - Spec: `reseller-totals/spec.md` — Reset a reseller; Read access for members, writes admin-only.
  - RED: admin-only; non-UUID → 400; calls `crm_revendedor_reiniciar` with `p_contact_id`, `p_motivo`, `p_total_esperado_gyd`; 409 on `40001`; 400 on `22023`; 404 on `P0002`; `{ reset }`.
  - GREEN: implement.
  - Verify: `npx vitest run src/app/api/revendedores/[contactId]/reiniciar/route.test.ts --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.4`, `3.5`. Parallel.

- [ ] 3.10 (RED→GREEN) Create `POST /api/revendedores/[contactId]/ajustes`.
  - Files: create `src/app/api/revendedores/[contactId]/ajustes/route.ts` and `route.test.ts`.
  - Spec: `reseller-totals/spec.md` — Manual adjustments; Read access for members, writes admin-only.
  - RED: admin-only; non-UUID/invalid payload → 400; calls `crm_revendedor_ajustar` with `p_contact_id`, `p_monto_gyd`, `p_motivo`; maps `22023`/`42501`/`P0002`; response `{ adjustment }`.
  - GREEN: implement.
  - Verify: `npx vitest run src/app/api/revendedores/[contactId]/ajustes/route.test.ts --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.4`, `3.5`. Parallel.

- [ ] 3.11 (RED→GREEN) Create `src/components/resellers/reseller-reset-dialog.tsx`.
  - Files: create the component and `src/components/resellers/reseller-reset-dialog.test.tsx`.
  - Spec: `reseller-totals/spec.md` — Confirmation shows the amount being closed; Reason is optional; Reset copy clarity.
  - RED: shows the amount being closed for single and all modes; states "counter only, no money change"; optional reason; sends `expectedTotalGyd`/`expectedGrandTotalGyd`; on 409 refetches and shows the new amount without resetting.
  - GREEN: implement the dialog.
  - Verify: `npx vitest run src/components/resellers/reseller-reset-dialog.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.7`, `3.9`. Parallel with `3.12`–`3.16`.

- [ ] 3.12 (RED→GREEN) Create `src/components/resellers/reseller-adjust-dialog.tsx`.
  - Files: create the component and its test.
  - Spec: `reseller-totals/spec.md` — Manual adjustments (signed amount, optional reason, separate line).
  - RED: signed non-zero amount; optional reason; previews the new total; rejects zero; submits `{ amountGyd, reason }`.
  - GREEN: implement.
  - Verify: `npx vitest run src/components/resellers/reseller-adjust-dialog.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.10`. Parallel.

- [ ] 3.13 (RED→GREEN) Create `src/components/resellers/reseller-history.tsx`.
  - Files: create the component and its test.
  - Spec: `reseller-totals/spec.md` — Period history per reseller; History survives untag and retag.
  - RED: renders start, end, live total, closed snapshot when different, actor and reason (absent when null); newest first; open period distinguishable.
  - GREEN: implement.
  - Verify: `npx vitest run src/components/resellers/reseller-history.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.8`. Parallel.

- [ ] 3.14 (RED→GREEN) Create `src/components/resellers/reseller-sidebar-block.tsx`.
  - Files: create the component and `reseller-sidebar-block.test.tsx`.
  - Spec: `reseller-totals/spec.md` — Contact sidebar visibility.
  - RED: total with operations/adjustments split; admins see adjust/reset; agents/viewers see the total only; no requests when not a reseller (the parent gates).
  - GREEN: implement using `canManageResellers`.
  - Verify: `npx vitest run src/components/resellers/reseller-sidebar-block.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.8`, `1.7`. Parallel.

- [ ] 3.15 (RED→GREEN) Wire the reseller block into `src/components/inbox/contact-sidebar.tsx`.
  - Files: modify `src/components/inbox/contact-sidebar.tsx` and `src/components/inbox/contact-sidebar.test.tsx`.
  - Spec: `reseller-totals/spec.md` — Reseller sees the block; Non-reseller sees no total; Untagging hides the block.
  - RED: block rendered only when `tags.some(t => isResellerTagName(t.name))`; absent for non-resellers; disappears after refresh when untagged.
  - GREEN: add the conditional render using the existing loaded tags; no extra request for non-resellers.
  - Verify: `npx vitest run src/components/inbox/contact-sidebar.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.14`. Parallel with `3.16`.

- [ ] 3.16 (RED→GREEN) Create `src/components/finanzas/revendedores-tab.tsx`.
  - Files: create the component and `revendedores-tab.test.tsx`.
  - Spec: `reseller-totals/spec.md` — Finanzas reseller list; Reset copy clarity.
  - RED: list with per-reseller totals, grand total, empty state; admins see reset/reset-all/adjust/history; agents see the list and totals without write actions; reset dialog shows the amount.
  - GREEN: implement; use `canManageResellers`.
  - Verify: `npx vitest run src/components/finanzas/revendedores-tab.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.6`, `3.7`, `3.11`, `3.12`, `3.13`. Parallel with `3.15`.

- [ ] 3.17 (RED→GREEN) Add the third Finanzas tab.
  - Files: modify `src/lib/finanzas/tabs.ts`, `src/lib/finanzas/tabs.test.ts` (create if absent), `src/components/finanzas/finanzas-view.tsx`, `src/app/(dashboard)/finanzas/page.test.tsx`.
  - Spec: `reseller-totals/spec.md` — Finanzas reseller list.
  - RED: `FINANZAS_TABS = ["semana", "cierres", "revendedores"]`; `?tab=revendedores` opens the new tab; unknown/missing still defaults to `semana`; existing redirects unchanged.
  - GREEN: wire the tab and lazy mount.
  - Verify: `npx vitest run src/lib/finanzas src/app/(dashboard)/finanzas/page.test.tsx --maxWorkers=4` and `npx tsc --noEmit`.
  - Depends: `3.16`. Sequential.

- [ ] 3.18 Finalize locale keys for the totals slice.
  - Files: modify `messages/es.json`, `messages/en.json`; test `src/i18n/messages-parity.test.ts` (read-only unless it needs a new key list).
  - Spec: `reseller-totals/spec.md` — Reset copy clarity; Finanzas reseller list.
  - Test: add every `Resellers.*` key used by `3.11`–`3.17`; no missing or extra keys; ICU parse passes; reset copy states "counter only, no money change" in both locales.
  - Verify: `npx vitest run src/i18n/messages-parity.test.ts --maxWorkers=4`.
  - Depends: `3.11`–`3.17`. Sequential; coordinate with `1.7`.

- [ ] 3.19 Run the staging end-to-end flow with PRUEBA fixtures.
  - Files: `.claude/skills/wacrm-probar-staging/SKILL.md` (read-only); staging data only.
  - Spec: `reseller-totals/spec.md` — success criteria in `proposal.md` (list, grand total, reset, adjust, history, sidebar).
  - Test/Verify: create PRUEBA resellers with qualifying/cancelled/non-GYD operations, open Finanzas as admin and as agent, reset one, reset all (confirm zero-total resellers are skipped), add ± adjustments, open history, open a contact sidebar; clean up the fixtures.
  - Depends: `3.18`. Sequential before Phase 4.

- [ ] 3.20 Full slice verification.
  - Files: all Phase 3 files.
  - Verify: `npx vitest run src/lib/resellers src/app/api/revendedores src/components/resellers src/components/finanzas src/components/inbox/contact-sidebar.test.tsx --maxWorkers=4` and `npx tsc --noEmit`. Record any skipped or failing check honestly.
  - Depends: `3.19`. Last in Phase 3.

## Phase 4 — Production rollout (owner go-ahead required at every step)

- [ ] 4.1 Run `previa` for the production bundle and obtain the owner's go-ahead.
  - Files: `supabase/migrations/395_reseller_identity.sql`, `supabase/migrations/396_reseller_tag_guard.sql`, `supabase/migrations/397_reseller_totals.sql`; `infra/db/produccion-migracion.sh` (read-only execution).
  - Test/Verify: `infra/db/produccion-migracion.sh previa supabase/migrations/395_reseller_identity.sql supabase/migrations/396_reseller_tag_guard.sql supabase/migrations/397_reseller_totals.sql` prints `VEREDICTO: SEGURO`. Any `DIFFERENT`, `MISSING-IN-PROD`, `EXTRA-IN-PROD` or `RECORDED` is shown to the owner; no apply without an explicit answer. `2.3`–`2.5` must be complete.
  - Owner go-ahead required: yes.
  - Depends: 1.6, 2.5, 3.3, 3.20 (all migration files and verification evidence ready). Sequential.

- [ ] 4.2 Apply the production migrations as one bundle.
  - Files: `supabase/migrations/395_reseller_identity.sql`, `supabase/migrations/396_reseller_tag_guard.sql`, `supabase/migrations/397_reseller_totals.sql`; production DB via `infra/db/produccion-migracion.sh`.
  - Spec: `proposal.md` — Dependencies; `design.md` — Migration / Rollout.
  - Critical: `395` and `396` MUST be in the same `aplicar` invocation; never apply one without the other. If 397 is not ready, apply only 395+396 and defer 397 to its own approved step.
  - Owner go-ahead required: yes, for this exact invocation.
  - Test/Verify: `infra/db/produccion-migracion.sh aplicar supabase/migrations/395_reseller_identity.sql supabase/migrations/396_reseller_tag_guard.sql supabase/migrations/397_reseller_totals.sql` returns OK for each file; then `infra/db/produccion-migracion.sh verificar supabase/migrations/395_reseller_identity.sql supabase/migrations/396_reseller_tag_guard.sql supabase/migrations/397_reseller_totals.sql` prints `VERIFICADO: 3/3`. On an API error, stop at that file and report; do not retry blindly.
  - Depends: `4.1`. Sequential.

- [ ] 4.3 Publish the panel after the migrations.
  - Files: `.claude/skills/wacrm-publicar-panel/SKILL.md` (read-only); `infra/deployment/publicar-panel.sh` (read-only execution).
  - Spec: `proposal.md` — Dependencies; `design.md` — Migration / Rollout step 4.
  - Owner go-ahead required: yes, before `publicar`.
  - Test/Verify: run `infra/deployment/publicar-panel.sh servido`, diff `src messages public package.json package-lock.json` against the served sha, build in `~/wacrm-worktrees/prod-build` with `infra/deployment/publicar-panel.sh compilar`, report the sha/build_id and the rollback sha, then `infra/deployment/publicar-panel.sh publicar <sha>`. Push `release/prod-<topic>` to `privado` only. Never ship app code that needs a missing migration.
  - Depends: `4.2`. Sequential.

- [ ] 4.4 Post-deploy smoke check.
  - Files: production panel (read-only), production DB read-only.
  - Spec: `proposal.md` — Success criteria; `reseller-totals/spec.md` — Finanzas reseller list; Contact sidebar visibility.
  - Test/Verify: owner opens Finanzas → Revendedores (list + grand total), a tagged contact sidebar, and one history drawer; re-run `supabase/staging/check-reseller-identity.sql` read-only on production and confirm no unintended identity change; confirm `cerebro_es_revendedor` still returns true for every contact that was a reseller on the day of the switch.
  - Depends: `4.3`. Sequential, last.

## Strict TDD Note

`strict_tdd` is active. Every behavior task above is executed test-first: write the failing assertion/test, run it, capture the RED result, then implement until GREEN, then refactor without changing behavior.

- DB runners: `infra/db/staging-migracion.sh aplicar <migration> <assertion> <rollback> [functions]` (add `DRY_ONLY=1` for the dry-run) and `infra/db/staging-migracion.sh relacionadas <migration> <pattern>`. Assertions end with `ALL PASS (rolled back on purpose)` and self-revert.
- Unit/route/component runners: `npx vitest run <paths> --maxWorkers=4`.
- Type check: `npx tsc --noEmit`.
- Locale check: `npx vitest run src/i18n/messages-parity.test.ts --maxWorkers=4`.
- Production is never used as a test environment. Staging first, always; `previa` must print `VEREDICTO: SEGURO` before any `aplicar`.

## Owner Decisions Baked Into These Tasks

1. The pre-production identity report is run read-only and shown to the owner (2.3).
2. Agents may delete a reseller contact; the guard allows the cascade (1.4, 1.5).
3. Adding/removing the reseller tag writes an audit row (1.2 action list, 1.5 trigger).
4. Viewer role can read totals (3.1, 3.6, 3.8).
5. "Reset all" skips resellers whose current total is 0 (3.1, 3.2).
6. Automation tag writes are verified during implementation (2.4).

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary. The authorization boundary (tag guard, RPC role checks, RLS, grants) is covered by the DB assertions in 1.4/1.5, 3.1 and 3.2.
