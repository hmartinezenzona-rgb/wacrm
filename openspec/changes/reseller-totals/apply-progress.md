# Apply Progress: reseller-totals — slices 1–5

Change: `reseller-totals`. This artifact is cumulative: slice 1 (S1 identity DB), slice 2 (S1 remainder:
396 tag guard + panel tag controls), slice 3 (S2 reports), slice 4 (S3 totals DB) and slice 5 (S3 totals
API) are all reflected here.

## Slice 1 (S1 identity DB) — tasks 1.1–1.3

Scope: `395_reseller_identity.sql`, `ROLLBACK-395-reseller-identity.sql` and
`supabase/staging/assertions/reseller-identity.sql`. Migration number 395 (390–394 are taken on every
local branch/worktree; production `schema_migrations` was not queried because production access is out of
this slice's authorization — Phase 4 `previa` refuses with `RECORDED` if it is ever taken).

### Task Status

| Task | Status | Evidence |
|------|--------|----------|
| 1.1 Failing identity assertion | done | RED on staging: `function reseller_tag_name_matches(unknown) does not exist`; GREEN: `ALL PASS (rolled back on purpose)` |
| 1.2 Migration 395 + ROLLBACK-395 | done | Full staging cycle: dry-run OK, apply OK, assertion OK, rollback md5 equal |
| 1.3 No deposit-path regression | done | `relacionadas`: `TOTAL 1 | SAME 1 | DIFF 0` and `TOTAL 44 | SAME 44 | DIFF 0` |

### What 395 does

1. Audit action list becomes the live staging list after 383 (40 actions, read from
   `remittance_admin_audit_action_chk`, not trusted from the file) plus `migration_reseller_tag_added`,
   `human_reseller_counter_reset`, `human_reseller_adjustment`, `human_reseller_tag_added`,
   `human_reseller_tag_removed`.
2. `reseller_tag_name_matches(text)` (`IMMUTABLE`, `lower(btrim(name)) = 'revendedor'`) and
   `reseller_contact_is_tagged(uuid)` (`STABLE SECURITY DEFINER`, account-scoped contact -> contact_tags ->
   tags). Both revoked from `PUBLIC`, `anon`, `authenticated`.
3. Backfill tags every contact whose `contacts.phone` equals an ACTIVE `cerebro_revendedores.phone`,
   reusing the account's canonical (oldest) matching tag and creating `"Revendedor"` only where the
   account has no matching tag, with `tags.user_id = accounts.owner_user_id`. One
   `migration_reseller_tag_added` audit row per created tag (`table_name 'tags'`) and per created link
   (`table_name 'contact_tags'`, `row_id = contact_tags.id`), actor `migration:395_reseller_identity`.
4. `cerebro_es_revendedor(conv)` reads the tag, same signature; the 109 ACL
   (`{postgres,service_role}`) is restated and preserved (md5 `1b67d2f4ceb2` before and after).
5. A `DO` check raises and applies nothing if a conversation that was a reseller under the allow-list is
   not one under the tag rule.
6. `COMMENT ON TABLE cerebro_revendedores` marks it deprecated/read-only (rollback source);
   `NOTIFY pgrst, 'reload schema'`.

### Work Unit Evidence

| Evidence | Required value |
|---|---|
| Focused test command and exact result | `DRY_ONLY=1 infra/db/staging-migracion.sh aplicar supabase/migrations/395_reseller_identity.sql supabase/staging/assertions/reseller-identity.sql supabase/migrations/ROLLBACK-395-reseller-identity.sql cerebro_es_revendedor` → `dry-run OK`. Full cycle without `DRY_ONLY` → `dry-run OK / apply OK / assertion OK / rollback OK (md5 igual al previo)` |
| Runtime harness command/scenario and exact result | Same staging apply with the self-reverting assertion (fixtures in `pg_temp`/transaction, rolled back). It exercises the tag rule, account scoping, duplicates, the backfill and its audit rows, idempotence, bot parity, untagging, privileges, the deprecation comment and the audit list |
| Rollback boundary | `ROLLBACK-395-reseller-identity.sql` restores the exact 109 body (md5 equal), drops both helpers and the private backfill function, clears the comment and re-adds the 383 list `NOT VALID`. Backfilled tags/links stay and are listed by the audit rows |

### TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 1.1 | `supabase/staging/assertions/reseller-identity.sql` | DB assertion | N/A (new file) | `psql_staging < assertion` → `ERROR: function reseller_tag_name_matches(unknown) does not exist` | After 395 → `ALL PASS (rolled back on purpose)` | Cases 1–6 cover name variants, account scope, duplicates, backfill audit, idempotence, bot parity, untagging, privileges | Assertion kept as the GREEN target; no production code refactored after GREEN |
| 1.2 | Same assertion + `staging-migracion.sh aplicar` | DB migration | Live staging body read first with `pg_get_functiondef`; live audit list read first | Same RED as 1.1 | Full cycle all OK; rollback md5 equal | Dry-run and applied-state assertion both pass; idempotent second backfill asserted | SQL kept as the minimum that passes the assertion |
| 1.3 | `staging-migracion.sh relacionadas` | DB regression | `--ya-aplicada ROLLBACK-395` (395 is applied on staging) | N/A (verification) | `TOTAL 1 | SAME 1 | DIFF 0` (bot) and `TOTAL 44 | SAME 44 | DIFF 0` (deposit path) | N/A | N/A |

### Deviations from Design

- The backfill lives in a private `_reseller_backfill_allow_list()` function instead of an inline `DO`
  block. The staging runner applies the migration before the assertion, so a test cannot create fixtures
  before an inline backfill; the function lets the assertion call the migration's real backfill code
  against its fixtures (and proves idempotence). It returns
  `{tags_created, links_created}`, is `SECURITY DEFINER`, and is revoked from `PUBLIC`, `anon`,
  `authenticated`, `service_role`. ROLLBACK drops it.
- Authored size is 586 lines for the three slice files (forecast ~420–480). The slice is delivered as one
  work unit under the accepted `feature-branch-chain` strategy; nothing was shrunk or omitted to fit.

### Related checks

- `relacionadas 395 cerebro_es_revendedor <skip own assertion> --ya-aplicada ROLLBACK-395` →
  `TOTAL 1 | SAME 1 | DIFF 0`.
- `relacionadas 395 cerebro_registrar_deposito <skip own assertion> --ya-aplicada ROLLBACK-395` →
  `TOTAL 44 | SAME 44 | DIFF 0`; failing bases are pre-existing and therefore SAME.
- Broad summary `relacionadas 395 'revendedor|reseller|beneficiar|audit' '' --ya-aplicada ROLLBACK-395` →
  `TOTAL 182 | SAME 180 | DIFF 2`. The two DIFFs: this migration's own assertion (base lacks the
  helpers, expected) and `delivery-feed-evidence` (pre-existing fixture failure: both sides fail with
  `fixture setup failed — no operation created for deal <uuid>`; identical after full UUID normalization,
  but the tool compares only the first 90 characters, so the random UUID made it look different). No
  regression DIFF.

### Commit

- `a976dd7d` — `feat(sdd): switch reseller identity to the Revendedor tag`

---

## Slice 3 (S2 reports) — tasks 2.1–2.4 (prior attempt)

Scope: tasks 2.1–2.4 (read-only pre-apply reports and the automation tag check). No migration, no `src/`
code, no database write.

### Task Status

| Task | Status | Evidence |
|------|--------|----------|
| 2.1 Create `supabase/staging/check-reseller-identity.sql` | done | Read-only script validated on staging (results below) |
| 2.2 Run reports on staging and reconcile with 395 | pending (owner-gated; blocked on 1.2) | Exact commands prepared below; not run by that attempt. 395 is now applied, so this can be run |
| 2.3 Production report + owner tag decision | pending (owner go-ahead required) | Exact command and template prepared below; not run |
| 2.4 Verify no automation changes the "Revendedor" tag | done | Read-only inspection (findings below) |

### Work Unit Evidence

| Evidence | Required value |
|---|---|
| Focused test command and exact result | `bash -c 'source infra/db/lib-migracion.sh && psql_staging < supabase/staging/check-reseller-identity.sql'` → exit 0; `A_count: 0`, `B_count: 0`, `C_contact_count: 0`, `C_account_count: 0`, `D_count: 0` |
| Runtime harness command/scenario and exact result | Same command against staging. The script opens `BEGIN; SET TRANSACTION READ ONLY;` and ends `ROLLBACK;`; staging baseline (0 allow-list rows, 0 active; 3 contacts, 3 contact_tags, 4 tags, none `%revend%`) explains the zeros. Production read-only config query: `automation_steps` add_tag/remove_tag = 0, `flow_nodes` set_tag = 0 |
| Rollback boundary | Delete `supabase/staging/check-reseller-identity.sql`; no schema or data change |

### TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 2.1 | `supabase/staging/check-reseller-identity.sql` (run, not a test file) | DB read-only harness | N/A (new file) | N/A — no production behavior added | Ran on staging, exit 0 | N/A — single read-only report | N/A |
| 2.4 | read-only inspection commands | Static/DB read-only | N/A | N/A — investigation only, no code change | Findings recorded | N/A | N/A |

Rationale: Strict TDD applies to behavior changes. Tasks 2.1 and 2.4 add no production code and no
behavior; they add a human-run read-only report and a read-only investigation. The report was executed on
staging (observed result above) instead of a RED/GREEN unit cycle.

### Report Sizes Observed on Staging

| List | Meaning | Count |
|------|---------|-------|
| A | Active allow-list phones with no matching contact (stop being resellers) | 0 |
| B | Contacts tagged "Revendedor" not on the active allow-list (become resellers) | 0 |
| C contact | Contacts the 395 backfill will tag | 0 |
| C account | Accounts where a new "Revendedor" tag will be created | 0 |
| D | Near-miss tag names the rule will not match | 0 |

Close-but-unmatched tag names (D): none on staging. Staging has only 4 tags and none contains `revend`, so
list D is empty there; production list D is still unknown until the owner runs 2.3.

### Task 2.4 — Automation Findings (read-only)

- **n8n production** `jEzlVLCLUaJhVwzs` (126 nodes, versionId `a3d439e9-380f-41fe-bdb2-832e48e84e82`,
  Decisor md5 `d64e8009` matching the repo): no `contact_tags`/`tags` writes. `Contexto conversacion`
  only reads `contact_tags`/`tags` for admin/assignee; `Registrar deposito auto` consumes the
  `es_revendedor` value returned by `cerebro_registrar_deposito`. No node calls `/api/v1/contacts`.
- **Decisor** `pruebas/decisor/decisor.jscode`: zero references to `revend`, `es_revendedor` or `tags`.
- **`infra/ia/`**: read-only tag reads only (`colectar_dia.py` report; `mejora_nocturna.py` prompt text
  mentions Admin/Revendedor as internal tags). No inserts, updates or deletes.
- **Panel automations/flows (production config, read-only)**: 0 `automation_steps` of type
  `add_tag`/`remove_tag` and 0 `flow_nodes` of type `set_tag`; 0 target the reseller tag.
- **DB-side writers**: `sync_tags_cliente` writes only `nuevo`/`cliente`/`recurrentes`;
  `merge_duplicate_contacts()` can move/drop `contact_tags` during contact dedup (not reseller-specific).
- **Residual by-design exposure**: `POST/PATCH /api/v1/contacts` with the `contacts:write` API-key scope
  uses a service-role client (`auth.uid()` NULL), so it can set arbitrary tag names including
  "Revendedor" and bypass the 396 guard. No n8n node uses that path today.
- **Verdict**: no automation adds or removes the "Revendedor" tag today. Future automation/flow configs
  and external API keys must be reviewed because no-session callers bypass the guard by design.

### Prepared Commands — Not Run

Task 2.2 (395 is now applied on staging):

```bash
bash -c 'source infra/db/lib-migracion.sh && psql_staging < supabase/staging/check-reseller-identity.sql'
```

Reconcile `C_contact_count` with the 395 audit rows through the same read-only helper:

```sql
SELECT count(*) FROM remittance_admin_audit
 WHERE action = 'migration_reseller_tag_added' AND table_name = 'contact_tags';
```

Task 2.3 (production, owner go-ahead required; read-only user):

```bash
docker run --rm --network host -i --env-file ~/.config/wacrm/prod-db.env postgres:17 \
  sh -c 'psql -X -q -A -t "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 -f -' \
  < supabase/staging/check-reseller-identity.sql
```

The owner may instead paste the file into the production SQL editor. Report template:
`A: count | phones -> keep/accept loss`; `B: count | phones -> keep tag/remove tag`;
`C: contacts | accounts creating tag`; `D: count | names -> ignore/rename`.

### Commits (slice 3)

- `dc5b4297` — `feat(sdd): add read-only reseller identity pre-apply report`
- `62e67417` — `docs(sdd): record slice 3 report and automation findings for reseller-totals`

---

## Slice 2 (S1 remainder: 396 tag guard + panel tag controls) — tasks 1.4–1.12

Scope: migration 396 (`contact_tags` reseller guard), `ROLLBACK-396-reseller-tag-guard.sql` and
`supabase/staging/assertions/reseller-tag-guard.sql`; the TypeScript tag rule and admin predicate;
contact detail / form / import gating; i18n. Migration number 396 (395 was the previous slice; 396 was
free in every branch).

### Task Status

| Task | Status | Evidence |
|------|--------|----------|
| 1.4 Failing tag-guard assertion | done | RED on staging: `ERROR: case 2: an agent INSERT of the reseller tag must be refused` |
| 1.5 Migration 396 + ROLLBACK-396 | done | `dry-run OK / apply OK / assertion OK / rollback OK (sin funciones que comparar)`; 12 PASS cases |
| 1.6 395+396 bundle proof | done | `DRY_ONLY=1 ... 395 ... reseller-identity.sql ...` → `dry-run OK` with 396 applied (backfill has no session, so the guard does not block it) |
| 1.7 Tag rule + `canManageResellers` + i18n | done | RED: `Cannot find module './tag-rule'` / `canManageResellers is not a function`; GREEN 3 files / 52 tests |
| 1.8 Detail-view chip gating | done | RED: chip enabled and no hint; GREEN 4/4 component tests |
| 1.9 `toggleTag` error toast | done | RED: no toast; GREEN insert and delete 42501 cases |
| 1.10 Contact-form diff sync | done | RED: delete-all/insert-all; GREEN 5/5 |
| 1.11 Import gating | done | RED: resolver matched/created the reseller tag; GREEN resolver 6/6, modal 2/2 |
| 1.12 S1 panel slice + locale parity | done | `Test Files 8 passed (8) | Tests 74 passed (74)`; `npx tsc --noEmit` exit 0 |

### What 396 does

`contact_tags_reseller_guard()` is a `plpgsql SECURITY DEFINER` function (`SET search_path = public`)
fired by `BEFORE INSERT OR UPDATE OR DELETE` on `contact_tags`, for each row:

1. `auth.uid() IS NULL` → allow (migration/backfill, service role such as n8n/automations, API keys).
2. Non-reseller tags → allow (the 017 `contact_tags_modify` RLS policy is unchanged for agents).
3. Not a state change → allow: an INSERT of an existing `(contact_id, tag_id)` pair (upsert
   `ignoreDuplicates`/re-saves) and a no-op UPDATE.
4. Contact-delete cascade (`contacts` row already invisible) → allow; deleting a tag definition also
   cascades (the tag row is already gone, so it is not a reseller match).
5. Otherwise requires `is_account_member(tag.account_id, 'admin')`; else
   `RAISE EXCEPTION ... ERRCODE '42501' HINT 'reseller_tag_admin_only'` with a readable message.
6. Real human add/remove → one `human_reseller_tag_added` / `human_reseller_tag_removed` audit row with
   `actor = wacrm_current_actor()` and `{contact_id, tag_id, tag_name}`.

Panel: `isResellerTagName` mirrors `lower(btrim(name)) = 'revendedor'`; `canManageResellers` mirrors
`is_account_member(account, 'admin')`; the reseller chip is visible but disabled for non-admins with a
Spanish explanation in the detail view and the form; `toggleTag` and the form now surface write errors
(42501 → `resellerTagRefused`). The form writes only the tag diff. The import resolver accepts
`canAssignResellerTag` (default true) and the modal passes `canEditSettings`, so a non-admin import skips
the reseller tag and reports it (`toastResellerTagSkipped`) instead of failing a 100-row batch.

### Work Unit Evidence

| Evidence | Required value |
|---|---|
| Focused test command and exact result | DB: `infra/db/staging-migracion.sh aplicar supabase/migrations/396_reseller_tag_guard.sql supabase/staging/assertions/reseller-tag-guard.sql supabase/migrations/ROLLBACK-396-reseller-tag-guard.sql` → `dry-run OK / apply OK / assertion OK / rollback OK (sin funciones que comparar)`. Panel: `npx vitest run src/lib/resellers src/lib/auth/roles.test.ts src/components/contacts src/lib/contacts/resolve-import-tags.test.ts src/i18n/messages-parity.test.ts --maxWorkers=4` → `Test Files 8 passed (8) | Tests 74 passed (74)`; `npx tsc --noEmit` → exit 0 |
| Runtime harness command/scenario and exact result | Staging apply runs the self-reverting assertion with real `auth.users`/`accounts`/`profiles` fixtures and `request.jwt.claims` for owner/admin/agent; the panel component tests drive the real components over a mocked Supabase client (insert/delete errors, chip disabled state, diff operations). Related-base regression: `relacionadas 396 ... --ya-aplicada ROLLBACK-396` → `TOTAL 213 | SAME 211 | DIFF 2` (both DIFFs explained below) |
| Rollback boundary | `ROLLBACK-396-reseller-tag-guard.sql` drops the trigger and the function only; agents return to the 017 permissions. Audit rows already written stay. Reverting `3e39189f` removes the panel gating and the diff sync |

### TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 1.4 / 1.5 | `supabase/staging/assertions/reseller-tag-guard.sql` | DB assertion | 395 applied on staging; live trigger absent | `ERROR: case 2: an agent INSERT of the reseller tag must be refused` | 12/12 PASS → `ALL PASS (rolled back on purpose)` | no-session, agent, admin, owner; other tag; existing pair; contact cascade; tag cascade; UPDATE move; no-op UPDATE; insert `pg_trigger` shape and grants | SQL kept minimal; no post-GREEN refactor |
| 1.7 | `src/lib/resellers/tag-rule.test.ts`, `src/lib/auth/roles.test.ts` | Unit | New modules | `Cannot find module './tag-rule'`; `canManageResellers is not a function` | 52 tests / 3 files (parity included) | name table (case, spaces, plural, accents, null), refusal shape, role matrix | none needed |
| 1.8 / 1.9 | `src/components/contacts/contact-detail-view.reseller-tag.test.tsx` | Component (jsdom) | Existing component suite | chip not disabled / no title / no toast | 4/4 | agent vs admin, insert refusal, delete refusal | none needed |
| 1.10 | `src/components/contacts/contact-form.tag-diff.test.tsx` | Component (jsdom) | Existing component suite | delete-all/insert-all observed | 5/5 | remove-only, add-only, unchanged, write error, agent gating | none needed |
| 1.11 | `src/lib/contacts/resolve-import-tags.test.ts`, `src/components/contacts/import-modal.reseller-tag.test.tsx` | Unit + component | Existing resolver callers | resolver matched/created the reseller tag for a non-admin | resolver 6/6; modal 2/2 | existing tag, missing tag, case-insensitive, admin default, no pair emitted, modal flag agent/admin | none needed |

### Deviations from Design

- An UPDATE that really moves a reseller-tag row is guarded (42501 for non-admins) but not audited: the
  owner-accepted audit scope is add/remove, and no panel path updates `contact_tags` (re-saves are no-op
  UPDATEs and return early). Documented in the migration header.
- The import modal reports the skipped reseller tag with its own message
  (`toastResellerTagSkipped`) while other unknown names keep the existing toast; both are skipped.
- Authored size is ~1,069 added / 48 removed lines for the panel commit (≈675 lines are tests), above the
  ~400 advisory. It is delivered as one work unit because tasks.md unit 2 prescribes exactly this scope
  (396 + panel tag controls) and the accepted strategy is feature-branch-chain with work-unit commits and
  no PR flow. Nothing was compressed or omitted to fit the number.

### Related checks

- `infra/db/staging-migracion.sh relacionadas supabase/migrations/396_reseller_tag_guard.sql 'contact_tag|tag|revendedor|reseller|beneficiar' '' --ya-aplicada supabase/migrations/ROLLBACK-396-reseller-tag-guard.sql`
  → `TOTAL 213 | SAME 211 | DIFF 2`.
  - `reseller-tag-guard`: this slice's own assertion. Base (with 396 rolled back) fails at `case 2`
    because the agent insert succeeds; with 396 it reaches `ALL PASS (rolled back on purpose)`. Expected.
  - `delivery-feed-evidence`: pre-existing fixture failure (`fixture setup failed — no operation created
    for deal <uuid>`). Both sides fail identically after full UUID normalization; `relacionadas` compares
    only the first 90 characters and the random fixture UUIDs differ. The same assertion was already
    flagged in slice 1; there is no new DIFF caused by 396.
- After the cycle, staging still has the trigger: `pg_trigger` lookup for
  `contact_tags_reseller_guard` returns the function of the same name.

### Commits (slice 2)

- `2e0d3429` — `feat(sdd): guard the reseller tag against agent edits`
- `3e39189f` — `feat(sdd): gate reseller tag controls and sync contact tags by diff`
- docs commit — `docs(sdd): record slice 2 of the reseller tag guard` (this file + `tasks.md`)

---

## Slice 4 (S3 totals DB) — tasks 3.1–3.3

Scope: migration 397 (`reseller_counter_resets`, `reseller_total_adjustments`, the
`remittance_operations` index, `_reseller_period_totals`, five RPCs),
`ROLLBACK-397-reseller-totals.sql` and `supabase/staging/assertions/reseller-totals.sql`.
Migration number 397 (free in every local branch; staging had none of its objects; 33
operation rows at cycle time).

### Task Status

| Task | Status | Evidence |
|------|--------|----------|
| 3.1 Failing totals assertion | done | RED: `function crm_revendedores_resumen(uuid) does not exist`; GREEN: 13 PASS cases ending `ALL PASS (rolled back on purpose)` |
| 3.2 Migration 397 + ROLLBACK-397 | done | `dry-run OK / apply OK / assertion OK / rollback OK (md5 igual al previo)` |
| 3.3 Staging behavior + related base | done | Targeted `relacionadas 397 crm_revendedor` → `TOTAL 0 SAME 0 DIFF 0` (only this slice's assertion names the new RPCs and it is skipped); broad pattern result recorded below |

### What 397 does

1. `reseller_counter_resets`: one append-only marker per reset with `reset_at`, optional
   `batch_id` (shared by a "reset all"), optional `reason` (1..500), the confirmed snapshot
   (`closed_operations_gyd`, `closed_adjustments_gyd`, `closed_total_gyd`), `created_by`,
   `actor`, `created_at`; `UNIQUE(contact_id, reset_at)` and an account/contact/date index.
2. `reseller_total_adjustments`: signed `amount_gyd` non-zero and under 1e12, optional reason,
   `created_by`, `actor`, `created_at`; contact/date index.
3. Both tables: RLS SELECT for `is_account_member(account_id)`, no write policy,
   `REVOKE ALL FROM anon, authenticated` then `GRANT SELECT TO authenticated`, and a
   `BEFORE UPDATE` trigger (`reseller_ledger_no_update()`) so even the service role cannot edit
   a ledger row (DELETE has no grant; only the contact/account cascade removes rows).
4. `remittance_operations_contact_created_idx (contact_id, created_at) WHERE contact_id IS NOT NULL`.
   Header documents the production SHARE-lock risk and says to record `count(*)` before apply.
5. `_reseller_period_totals(account, contact, from, to)`: one half-open `[from, to)` period
   definition on `created_at`; counted statuses `deposit_received`, `deposit_verification`,
   `ready_to_transfer`, `transferring`, `completed`, `incident`; GYD only, never converted;
   returns operations/adjustments sums, counts, missing-amount count and the net.
6. Read RPCs `crm_revendedores_resumen(account)` and `crm_revendedor_detalle(contact)`
   (`STABLE SECURITY DEFINER`, `is_account_member`, viewer+); write RPCs
   `crm_revendedor_ajustar(contact, amount, reason)`,
   `crm_revendedor_reiniciar(contact, reason, expected)` and
   `crm_revendedores_reiniciar_todos(account, reason, expected)` (admin+). Every write takes
   `pg_advisory_xact_lock(hashtextextended('reseller-totals:' || account, 0))`, stamps
   `clock_timestamp()`, and writes one `remittance_admin_audit` row
   (`human_reseller_counter_reset` / `human_reseller_adjustment`). An expected amount that
   differs from the recomputed total raises `40001` and writes nothing. "Reset all" compares the
   expected amount with the grand total over all tagged resellers, then writes one marker per
   reseller whose total is non-zero (zeros skipped, owner-accepted default) under one batch id.

### RPC signatures and error contract (for the API slice)

```sql
crm_revendedores_resumen(p_account_id uuid) RETURNS jsonb
crm_revendedor_detalle(p_contact_id uuid) RETURNS jsonb
crm_revendedor_ajustar(p_contact_id uuid, p_monto_gyd numeric, p_motivo text DEFAULT NULL) RETURNS jsonb
crm_revendedor_reiniciar(p_contact_id uuid, p_motivo text DEFAULT NULL, p_total_esperado_gyd numeric DEFAULT NULL) RETURNS jsonb
crm_revendedores_reiniciar_todos(p_account_id uuid, p_motivo text DEFAULT NULL, p_total_esperado_gyd numeric DEFAULT NULL) RETURNS jsonb
```
`P0002` contact not found → 404; `42501` not a member / not admin → 403; `22023` not a
reseller, zero/NULL/out-of-range amount, reason > 500 → 400; `40001` expected total differs →
409. Return keys match `design.md` Interfaces (snake_case jsonb).

### Work Unit Evidence

| Evidence | Required value |
|---|---|
| Focused test command and exact result | `infra/db/staging-migracion.sh aplicar supabase/migrations/397_reseller_totals.sql supabase/staging/assertions/reseller-totals.sql supabase/migrations/ROLLBACK-397-reseller-totals.sql <7 function names>` → `dry-run OK / apply OK / assertion OK / rollback OK (md5 igual al previo)` |
| Runtime harness command/scenario and exact result | Same staging apply with the self-reverting assertion: fixture account A (owner/admin/agent/viewer/stranger) plus account B, real operations with explicit `created_at` around the reset marker, and RPC calls with `request.jwt.claims` per role. It exercises counted statuses, exclusions, empty period, ordering, viewer/agent reads, stranger refusal, half-open boundaries, ± adjustments and zero refusal, append-only + grants + RLS, reset-all skip-zero/one batch, stale `40001`, md5 of operation rows, untag/retag history |
| Rollback boundary | `ROLLBACK-397-reseller-totals.sql` drops the five RPCs, the helper, the no-update function, both tables and the index. Every `remittance_operations` row is untouched; audit rows stay |

### TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 3.1 / 3.2 | `supabase/staging/assertions/reseller-totals.sql` | DB assertion | Staging with 395/396 applied; no 397 objects | `function crm_revendedores_resumen(uuid) does not exist` | 13 PASS → `ALL PASS (rolled back on purpose)` | Every qualifying status, each exclusion, two accounts, two resellers (one zero), boundary before/at/after the marker, ± adjustments, stale amount, untag/retag, agent/viewer roles | SQL kept minimal; assertion kept as the GREEN target |
| 3.3 | `staging-migracion.sh relacionadas` | DB regression | `--ya-aplicada ROLLBACK-397` (397 is applied) | N/A (verification) | `TOTAL 0 SAME 0 DIFF 0` for `crm_revendedor`; broad pattern recorded below | N/A | N/A |

### Deviations from Design

- The reset snapshot uses the three design columns (`closed_operations_gyd`,
  `closed_adjustments_gyd`, `closed_total_gyd` plus `created_by`, `actor`, `batch_id`) instead of
  the single `closed_amount_gyd` shorthand in the slice prompt.
- "Reset all" compares `p_total_esperado_gyd` with the grand total over all tagged resellers
  (including zeros) before writing, then skips zero-total resellers when writing markers.
- `reason` is trimmed; an empty string becomes NULL. The transaction-level advisory lock plus
  `clock_timestamp()` keeps markers and adjustments totally ordered, so a concurrent reset never
  lands on the wrong side of an adjustment.
- The assertion's "before the marker" operation (99999) is intentionally part of the closed
  period history, so case 7 proves the live closed total (107099) differs from the closed
  snapshot (2100) instead of assuming they are equal.

### Related checks

- `infra/db/staging-migracion.sh relacionadas supabase/migrations/397_reseller_totals.sql crm_revendedor supabase/staging/assertions/reseller-totals.sql --ya-aplicada supabase/migrations/ROLLBACK-397-reseller-totals.sql`
  → `TOTAL 0 | SAME 0 | DIFF 0`. No pre-existing assertion calls the new RPCs, so this is
  vacuously clean; the broad pattern below is the meaningful regression proof.
- Broad pattern `'revendedor|reseller|saldo|calculadora|audit|operacion'` (own assertion
  skipped, `--ya-aplicada ROLLBACK-397`): `TOTAL 156 | SAME 155 | DIFF 1`. The single DIFF is
  `delivery-feed-evidence`, the known pre-existing fixture flake: both sides fail identically
  (`fixture setup failed — no operation created for deal <uuid>`) but `relacionadas` compares
  only the first 90 characters and the random fixture UUID differs. No new DIFF from 397.

### Commits (slice 4)

- `0b01d9b8` — `feat(sdd): add reseller totals schema and RPCs`


---

## Slice 5 (S3 totals API) — tasks 3.4–3.10

Scope: `src/lib/resellers/payloads.ts`, `src/lib/resellers/read-model.ts`,
`src/lib/resellers/rpc-errors.ts` and the five routes under `src/app/api/revendedores/`, each with its
test. No UI (slice 6), no migration, no database write. The DB contract is the 397 RPCs from slice 4.

### Task Status

| Task | Status | Evidence |
|------|--------|----------|
| 3.4 Payload parsers | done | RED: `Cannot find module './payloads'`; GREEN: 16 payload tests |
| 3.5 Read-model mappers | done | RED: `Cannot find module './read-model'`; GREEN: 9 read-model tests |
| 3.6 `GET /api/revendedores` | done | RED: module missing; GREEN: 6 route tests |
| 3.7 `POST /api/revendedores/reiniciar` | done | RED: module missing; GREEN: 9 route tests |
| 3.8 `GET /api/revendedores/[contactId]` | done | RED: module missing; GREEN: 5 route tests |
| 3.9 `POST /api/revendedores/[contactId]/reiniciar` | done | RED: module missing; GREEN: 8 route tests |
| 3.10 `POST /api/revendedores/[contactId]/ajustes` | done | RED: module missing; GREEN: 10 route tests |

### What the API slice does

- `payloads.ts` — strict body parsers (`parseResetBody`, `parseResetAllBody`, `parseAdjustBody`).
  Known keys only; `reason` trimmed, blank/null → `null`, max 500; expected totals optional finite;
  `amountGyd` signed, finite, non-zero, `abs < 1e12`. No I/O.
- `read-model.ts` — pure snake_case → camelCase mappers for all five RPC payloads. Numeric values may
  arrive as JSON numbers or decimal strings; both coerce. Null payloads return zeros/empty lists.
- `rpc-errors.ts` — `resellerRpcErrorResponse(error, totalField)`: `42501` → 403, `P0002` → 404,
  `22023` → 400 with the RPC message, `40001` → 409 carrying the current total parsed from the RPC
  `HINT` (`currentTotalGyd`, or `currentGrandTotalGyd` for reset-all); `null` for anything else.
- Routes use the caller's SESSION client (never service role), so the RPC sees `auth.uid()` and enforces
  membership/admin itself. Reads `requireRole("viewer")` (all member roles); writes
  `requireRole("admin")`. Every 200 sets `Cache-Control: private, no-store`.

### Request / response shapes exposed (slice 6 contract)

| Route | Auth | Request body | 200 |
|---|---|---|---|
| `GET /api/revendedores` | any member | — | `{ grand: { operationsGyd, adjustmentsGyd, totalGyd, resellers }, resellers: ResellerSummary[] }` |
| `GET /api/revendedores/{contactId}` | any member | — | `{ reseller: ResellerDetail }` |
| `POST /api/revendedores/{contactId}/reiniciar` | admin | `{ reason?: string \| null, expectedTotalGyd?: number \| null }` | `{ reset: { resetId, contactId, resetAt, closed: { operationsGyd, adjustmentsGyd, totalGyd } } }` |
| `POST /api/revendedores/reiniciar` | admin | `{ reason?: string \| null, expectedGrandTotalGyd?: number \| null }` | `{ batch: { batchId, resetAt, count, grandTotalGyd, resets: [{ resetId, contactId, totalGyd }] } }` |
| `POST /api/revendedores/{contactId}/ajustes` | admin | `{ amountGyd: number, reason?: string \| null }` | `{ adjustment: { adjustmentId, contactId, amountGyd, createdAt, totalBeforeGyd, totalAfterGyd } }` |

```
ResellerSummary = { contactId, name, phone, periodStart, operationsGyd, operationsCount,
                    operationsMissingAmount, adjustmentsGyd, adjustmentsCount, totalGyd }
ResellerDetail  = { contactId, name, phone, isReseller,
                    current: ResellerSummaryTotals & { periodStart, adjustmentsCount,
                              adjustments: [{ id, amountGyd, reason, actorName, createdAt }] },
                    periods: [{ resetId, start, end, operationsGyd, adjustmentsGyd, totalGyd,
                                closedTotalGyd, batchId, resetByName, reason }] }  // newest first, max 100
```

Errors: `400 { error }` (non-UUID `contactId`, invalid JSON, invalid/unknown body field); `401`/`403`
from the auth helpers; `403 { error: "Forbidden" }` (RPC 42501); `404 { error: "Not found" }` (P0002);
`400 { error }` with the RPC message (22023); `409 { error, currentTotalGyd | currentGrandTotalGyd }`
(40001, current total from the HINT; `null` when the hint is not numeric); `500 { error: "Internal
server error" }`. Unknown body keys are rejected, not ignored.

### Work Unit Evidence

| Evidence | Required value |
|---|---|
| Focused test command and exact result | `npx vitest run src/lib/resellers/payloads.test.ts src/lib/resellers/read-model.test.ts src/app/api/revendedores --maxWorkers=4` → `Test Files 7 passed (7) │ Tests 81 passed (81)`; full resellers slice `npx vitest run src/lib/resellers src/app/api/revendedores --maxWorkers=4` → `Test Files 8 passed (8) │ Tests 96 passed (96)` |
| Runtime harness command/scenario and exact result | Route tests drive the real route handlers with a mocked session context and mocked RPC results, covering role gating, UUID/body validation, exact RPC name/argument names, all SQLSTATE mappings and the wire shapes. N/A for a live HTTP server: route handlers are unit-tested in-process (sibling pattern) |
| Rollback boundary | Delete the five route folders and `payloads.ts`/`read-model.ts`/`rpc-errors.ts`; the 397 read RPCs remain harmless. No database or migration change |

### TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 3.4 | `src/lib/resellers/payloads.test.ts` | Unit | New module (397 contract fixed) | `Cannot find module './payloads'` | 16 tests pass | Every field: reason trim/blank/null/500/501/non-string; expected totals finite/null/0/negative; amount 0/null/∞/string/1e12; non-object/array/null/unknown key | none needed |
| 3.5 | `src/lib/resellers/read-model.test.ts` | Unit | New module (397 jsonb shapes from slice 4) | `Cannot find module './read-model'` | 9 tests pass | numeric numbers and decimal strings; null payload; `is_reseller: false`; empty adjustments/periods; order passthrough; empty batch | none needed |
| 3.6 | `src/app/api/revendedores/route.test.ts` | Route | 397 applied on staging; read RPC exists | `Cannot find module './route'` | 6 tests pass | 401, success mapping+header, empty payload, 42501→403, unexpected→500 | none needed |
| 3.7 | `src/app/api/revendedores/reiniciar/route.test.ts` | Route | 397 write RPC exists | `Cannot find module './route'` | 9 tests pass | admin gate, invalid JSON/payload, args, omitted nulls, 40001 hint present/absent, 22023, 42501 | none needed |
| 3.8 | `src/app/api/revendedores/[contactId]/route.test.ts` | Route | 397 read RPC exists | `Cannot find module './route'` | 5 tests pass | 401, non-UUID, success+header, P0002, 42501 | none needed |
| 3.9 | `src/app/api/revendedores/[contactId]/reiniciar/route.test.ts` | Route | 397 write RPC exists | `Cannot find module './route'` | 8 tests pass | admin gate, non-UUID, invalid JSON/payload, args, omitted nulls, 40001→409 with total, 22023, P0002 | none needed |
| 3.10 | `src/app/api/revendedores/[contactId]/ajustes/route.test.ts` | Route | 397 write RPC exists | `Cannot find module './route'` | 10 tests pass | admin gate, non-UUID, invalid JSON, five invalid payloads, args, omitted reason, 22023, 42501, P0002 | none needed |

### Deviations from Design

- Read routes use `requireRole("viewer")` instead of `getCurrentAccount()` (task 3.6/3.8 GREEN text).
  Behavior is identical for every valid role (`viewer` is the minimum member role) and it matches the
  sibling `remittance-operations` / `calculator` read routes; the database remains the boundary.
- `resellerRpcErrorResponse` replaces the generic `rpcErrorResponse` so the `40001` 409 body can carry
  the current total from the RPC `HINT` (design says "existing mapping", but the dialog must reload the
  amount; the generic helper discards `hint`).
- `ResellerDetail.current` also exposes `adjustmentsCount` (the RPC returns it and the summary exposes
  it); the design interface omitted it.
- Reset-all `{ batch }` lists the markers actually written (`resets`) and their `count`. The RPC skips
  zero-total resellers and does not return a "skipped" list; the client derives skipped resellers as
  tagged resellers absent from `resets`. Adding a skipped list would need an extra pre-reset read
  outside the advisory lock and could race, so it was not added (open question for slice 6).
- Error bodies are English, like every sibling API route; user-facing Spanish copy belongs to the UI
  slice (`messages/es.json`), which has no server-route i18n mechanism today.

### Related checks

- `npx tsc --noEmit` → exit 0 (project-wide, after all five routes and three libs).
- Existing `src/lib/resellers/tag-rule.test.ts` still passes in the full slice run (96 tests / 8 files).

### Commits (slice 5)

- `b01ad489` — `feat(sdd): add reseller totals API routes`
