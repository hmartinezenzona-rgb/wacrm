# Apply Progress: reseller-totals — slices 1–6, 7a, 7b, 7c

Change: `reseller-totals`. This artifact is cumulative: slice 1 (S1 identity DB), slice 2 (S1 remainder:
396 tag guard + panel tag controls), slice 3 (S2 reports), slice 4 (S3 totals DB), slice 5 (S3 totals
API), slice 6 (S3 totals UI), slice 7a (S7 reseller deposits, 398 DB), slice 7b (S7 Decisor reseller
confirmation route) and slice 7c (S7 panel read model/UI deposit line) are all reflected here.

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

---

## Slice 6 (S3 totals UI) — tasks 3.11–3.20

Scope: the reseller UI (`src/components/resellers/`), the Finanzas "Revendedores" tab, the third
Finanzas tab wiring, the inbox sidebar block, the locale keys and the API client. No migration, no
database write, no production access.

### Task Status

| Task | Status | Evidence |
|------|--------|----------|
| 3.11 Reset dialog | done | RED missing module; GREEN 4/4 |
| 3.12 Adjust dialog | done | RED missing module; GREEN 3/3 |
| 3.13 Period history | done | RED missing module; GREEN 4/4 |
| 3.14 Sidebar block | done | RED missing module; GREEN 4/4 |
| 3.15 Contact-sidebar wiring | done | RED no block/no request; GREEN `contact-sidebar.test.tsx` 9/9 |
| 3.16 Revendedores tab | done | RED missing module; GREEN 6/6 |
| 3.17 Third Finanzas tab | done | RED tab expectations; GREEN tabs 10/10, view 8/8, page 5/5 |
| 3.18 Locale keys | done | Locale parity 4/4; `tsc --noEmit` exit 0 |
| 3.19 Staging E2E with PRUEBA fixtures | pending, owner-gated | Not run: needs the staging panel plus the owner's login/browser interaction (`wacrm-probar-staging`). No fixtures created, no staging data touched |
| 3.20 Full slice verification | done (3.19 pending) | `Test Files 31 passed (31) | Tests 450 passed (450)`; `tsc --noEmit` exit 0 |

### What the UI slice does

- `src/lib/resellers/client.ts` — session-only client for the five routes. Reads the camelCase wire
  model the routes already produce, unwraps `{ reseller }`, `{ reset }`, `{ batch }`, `{ adjustment }`,
  and maps a 409 to `ResellerConflictError` with `currentTotalGyd`/`currentGrandTotalGyd` from the body.
- `src/lib/resellers/format.ts` — `formatGyd`, `formatSignedGyd`, `formatResellerDate`, all on the
  existing Finanzas figure style (`num` from `src/lib/finanzas/number-format.ts`, comma thousands).
- `reseller-reset-dialog.tsx` — single and all modes; shows the amount being closed and the
  counter-only copy, optional reason, sends the expected total, and on 409 reloads the shown amount
  from the response body, keeping the dialog open for a second confirmation. All mode shows a summary
  after success and derives skipped resellers as tagged ids absent from `resets`.
- `reseller-adjust-dialog.tsx` — signed non-zero GYD amount, optional reason, live new-total preview;
  zero/blank/out-of-range disables submit.
- `reseller-history.tsx` — open period labelled first, closed periods newest first, confirmed snapshot
  only when it differs from the live total, actor and reason only when present.
- `reseller-detail.tsx` — current-period breakdown with operations/adjustments/total, the
  missing-amount note, the adjustment history and the period history. Used by the tab's drawer.
- `reseller-sidebar-block.tsx` — rendered by `contact-sidebar.tsx` only when the already-loaded tags
  carry `isResellerTagName`; current total with the split, period start, detail link
  (`/finanzas?tab=revendedores`) and admin-only reset/adjust.
- `revendedores-tab.tsx` — grand total + split, per-reseller rows, empty state, admin-only
  reset/reset-all/adjust, detail for every member, and a Sheet drawer with the detail view.
- `FinanzasView`/`FINANZAS_TABS` — third tab `revendedores`, same lazy mount and `?tab=` behaviour;
  the panel receives `active` so it refetches when visited.
- Locales — `Finanzas.tabs.revendedores` and the full `Resellers.*` namespace in `messages/es.json`
  and `messages/en.json` (neutral professional Spanish; ICU signatures mirrored).

### Work Unit Evidence

| Evidence | Required value |
|---|---|
| Focused test command and exact result | `npx vitest run src/lib/resellers src/app/api/revendedores src/components/resellers src/components/finanzas src/components/inbox/contact-sidebar.test.tsx src/lib/finanzas 'src/app/(dashboard)/finanzas/page.test.tsx' --maxWorkers=4` → `Test Files 31 passed (31) │ Tests 450 passed (450)` |
| Runtime harness command/scenario and exact result | Component tests run the real components in jsdom under a real `NextIntlClientProvider` with the Spanish catalog, a mocked auth role and a stubbed `fetch`; they exercise the actual URLs, POST bodies, the 409 reload, the reset-all skipped derivation, the admin/agent split and the detail drawer. `npx vitest run src/i18n/messages-parity.test.ts --maxWorkers=4` → 4/4. `npx tsc --noEmit` → exit 0. `npx eslint src/components/resellers src/components/finanzas/revendedores-tab.tsx src/lib/resellers` → exit 0 |
| Rollback boundary | Revert `6cc4926`: the new components, the client/format helpers, the third tab wiring and the locale keys disappear; the rest of Finanzas and the inbox are unaffected. No database change |

### TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 3.11 | `src/components/resellers/reseller-reset-dialog.test.tsx` | Component (jsdom) | Slice 5 API contract; dialog pattern from `balance-dialog.tsx` | `Cannot find module './reseller-reset-dialog'` | 4/4 | single/all amount, counter-only copy, trimmed reason, expected total, 409 reload + second submit, skipped derivation | none needed |
| 3.12 | `src/components/resellers/reseller-adjust-dialog.test.tsx` | Component | Slice 5 adjust route | missing module | 3/3 | signed preview, zero rejected, null reason | none needed |
| 3.13 | `src/components/resellers/reseller-history.test.tsx` | Component | Slice 5 wire shapes | missing module | 4/4 | open first, newest first, snapshot difference, actor/reason absence, empty | none needed |
| 3.14 | `src/components/resellers/reseller-sidebar-block.test.tsx` | Component | `useAuth`, `canManageResellers` | missing module | 4/4 | total/split/period/missing note, admin actions, reset amount, agent read-only | effect rewritten to a cancelled promise to satisfy `react-hooks/set-state-in-effect` |
| 3.15 | `src/components/inbox/contact-sidebar.test.tsx` | Component | Existing sidebar suite | reseller tests failed (no block, no request) | 9/9 | reseller tag renders + one request, untagged renders nothing and requests nothing | none needed |
| 3.16 | `src/components/finanzas/revendedores-tab.test.tsx` | Component | Slice 5 summary/detail routes | missing module | 6/6 | grand total, rows, empty, admin vs agent actions, reset amount, detail drawer | none needed |
| 3.17 | `src/lib/finanzas/tabs.test.ts`, `finanzas-view.test.tsx`, `page.test.tsx` | Unit + component | Existing tab shell | array/redirect/tab-list expectations | 10/10, 8/8, 5/5 | known tabs, fallback, lazy mount, `active` flag | none needed |
| 3.18 | `src/i18n/messages-parity.test.ts` | Catalog | Existing parity test | N/A (new keys, not behavior) | 4/4 | key paths, ICU signatures, no empty strings | none needed |

### Deviations from Design

- Added `src/lib/resellers/client.ts` and `src/lib/resellers/format.ts` (not in the design file table):
  all five UI entry points share the fetch/409 handling and the GYD/date formatting instead of
  duplicating it.
- Added `src/components/resellers/reseller-detail.tsx` (design describes the detail view but lists no
  file): the tab's drawer and any future detail surface share one rendering of the current period,
  adjustments and history.
- The client consumes the **camelCase wire model** produced by slice 5 routes; it does not re-map the
  397 RPC snake_case (the API layer owns that mapping).
- On a 409 the dialog reloads the amount from the 409 body instead of issuing an extra GET; the API
  contract carries `currentTotalGyd`/`currentGrandTotalGyd` precisely for this.
- Reset-all does not add a skipped list to the API: the UI derives skipped as tagged ids absent from
  `resets`, as slice 5 left open.
- "History" in Finanzas opens the detail drawer (current period + adjustments + `ResellerHistory`)
  rather than a separate history-only surface; the sidebar links to the Finanzas tab.
- Authored size for the code commit is 2,106 insertions / 15 deletions (tests included), above the
  ~400 advisory. It is one work unit under the accepted `feature-branch-chain` strategy (no PR flow);
  nothing was compressed or omitted to fit the number.

### Related checks

- `npx vitest run src/i18n/messages-parity.test.ts --maxWorkers=4` → `Test Files 1 passed (1) │ Tests 4 passed (4)`.
- `npx tsc --noEmit` → exit 0.
- `npx eslint src/components/resellers src/components/finanzas/revendedores-tab.tsx src/lib/resellers` → exit 0.
- `src/components/inbox/contact-sidebar.tsx` keeps its pre-existing lint warnings (`User` unused, an
  unused disable directive) untouched.

### Commits (slice 6)

- `6cc4926` — `feat(sdd): add reseller totals UI and Finanzas tab`

---

## Slice 7a (S7 reseller deposits, 398 DB) — tasks 3B.0–3B.3

Scope: `supabase/migrations/398_reseller_deposits.sql`,
`supabase/migrations/ROLLBACK-398-reseller-deposits.sql`,
`supabase/staging/assertions/reseller-deposits.sql`, plus a 398-only cutover shim in
`supabase/staging/assertions/reseller-totals.sql`. Migration number 398 (across every
branch/worktree the highest was 397; 398 was free). No n8n or Decisor change (slice 7b), no
panel change (slice 7c), no production access.

### Task Status

| Task | Status | Evidence |
|------|--------|----------|
| 3B.0 Read-only preconditions | done | Live staging bodies read with `pg_get_functiondef`; in-repo production snapshot confirms the wrapper call; Decisor `rutaAdminAccion` re-checks `ctx.es_admin` |
| 3B.1 Failing assertion | done | RED: `ERROR: relation "reseller_deposit_cutover" does not exist`; GREEN: 16 numbered PASS cases (plus the 1b fallback case) ending `ALL PASS (rolled back on purpose)` |
| 3B.2 Migration 398 + ROLLBACK-398 | done | `dry-run OK / apply OK / assertion OK / rollback OK (md5 igual al previo)` |
| 3B.3 Deposit-path regression + existing totals | done | Broad `relacionadas`: `TOTAL 100 | SAME 99 | DIFF 1` (only the known `delivery-feed-evidence` flake); `reseller-totals` and `registrar-deposito-admin` pass |
| 3B.4–3B.6 Decisor route, staging E2E, read model/UI | pending | Slice 7b/7c; not part of this SQL work unit |

### What 398 does

1. `reseller_deposits`: one row per receipt block read by the bot, pending until the
   MMG cross consumes the matching deposit. `reference_digits` is a generated column;
   unique `(account_id, trans_id)` and `(conversation_id, comp_id)` indexes make
   verification and retries idempotent. `reseller_deposits_guard()` allows only the
   pending -> verified transition and makes verified rows immutable. RLS SELECT for
   members; no write/delete grants.
2. `reseller_deposit_cutover`: one typed row `(true, now(), '398_reseller_deposits')`
   written in the same transaction as the wrapper switch.
3. `cerebro_registrar_deposito_si_cliente`: admin precedence unchanged (310); a reseller
   records pending claims under the per-conversation advisory lock
   (`hashtextextended('cerebro_servicio:'||conv, 0)`) from
   `cerebro_parsear_comprobantes(p_nota)` and returns
   `(NULL, 'deposito_revendedor', true, false)`; customers keep delegating to
   `cerebro_registrar_deposito` unchanged.
4. `reseller_deposits_attribute()`: `AFTER UPDATE OF consumido_en` trigger on
   `depositos_mmg` when the new row is consumed and `operation_id IS NULL`. Exact TransID
   match (oldest pending claim within `revendedor_reclamo_horas`, default 72 h), else a
   single approximate candidate within `cruce_ventana_horas` (default 6 h). Fail-open:
   any error is a `WARNING` and the consumption still succeeds.
5. `_reseller_period_counts()`: verified deposits (consumed, not annulled, not linked to
   an operation) + qualifying GYD operations created before the cutover + adjustments,
   half-open `[from, to)`.
6. The five 397 RPCs re-pointed with additive keys: `deposits_gyd`, `deposits_count`,
   `counted_gyd`, detail `pending_claims`, history `deposits_gyd`/`closed_deposits_gyd`.
   Reset snapshots store `closed_deposits_gyd` and the reset responses expose it in
   `closed`. All locks, error codes, audit actions and reset-all skip-zero behaviour are
   unchanged.

### Wrapper return contract (for n8n / slice 7b)

```sql
cerebro_registrar_deposito_si_cliente(p_conv uuid, p_monto numeric, p_moneda text,
                                      p_stage uuid, p_nota text, p_comp_id text)
  RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
-- admin    -> (NULL, 'verificacion_admin', false, false)
-- reseller -> (NULL, 'deposito_revendedor', true,  false)  + pending claims
-- customer -> cerebro_registrar_deposito(...) unchanged
```

### Work Unit Evidence

| Evidence | Required value |
|---|---|
| Focused test command and exact result | `infra/db/staging-migracion.sh aplicar supabase/migrations/398_reseller_deposits.sql supabase/staging/assertions/reseller-deposits.sql supabase/migrations/ROLLBACK-398-reseller-deposits.sql cerebro_registrar_deposito_si_cliente,crm_revendedores_resumen,crm_revendedor_detalle,crm_revendedor_ajustar,crm_revendedor_reiniciar,crm_revendedores_reiniciar_todos` → `dry-run OK / apply OK / assertion OK / rollback OK (md5 igual al previo)` |
| Runtime harness command/scenario and exact result | Same staging apply with the self-reverting assertion: real users/accounts/profiles, contacts/conversations, `depositos_mmg` PRUEBA rows and wrapper calls. It exercises no-operation reseller registration, claims per block, retry idempotence, admin precedence, customer delegation, exact/approximate/ambiguous/late attribution, resend, no-claim consumption, forced unique_violation fail-open, mismatch/annulled/old receipts, guard/grants/RLS, totals math with linked/annulled/freed exclusions, reset snapshot and reset-all |
| Rollback boundary | `ROLLBACK-398-reseller-deposits.sql` restores the 310 wrapper and the five 397 RPC bodies verbatim (md5 equal), drops the attribution trigger/function, `_reseller_period_counts`, the guard and both new tables, drops `closed_deposits_gyd` and the config key. Consumed deposits stay consumed with `operation_id` NULL; export `reseller_deposits` first |
| Applied function md5 | wrapper `da18b5ece6a0`, resumen `a4dd557b3255`, detalle `697f4117b167`, ajustar `48de8487e115`, reiniciar `fe2a4473f7c6`, reiniciar_todos `3551eb58b27f`; ACLs unchanged |

### TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 3B.0 | live `pg_get_functiondef` reads + snapshot | DB / static | 310/311/312/253/397 applied on staging | N/A (read-only) | Bodies equal the design assumptions | N/A | N/A |
| 3B.1 / 3B.2 | `supabase/staging/assertions/reseller-deposits.sql` | DB assertion | Staging with 395/396/397 applied; no 398 objects | `relation "reseller_deposit_cutover" does not exist` | 16 numbered PASS (plus 1b) -> `ALL PASS (rolled back on purpose)` | reseller/admin/customer; pending/verified/exact/approximate/ambiguous/late; resend; mismatch/annulled/old; fail-open; guard/grants/RLS; totals; reset; roles | SQL kept minimal; assertion kept as the GREEN target |
| 3B.3 | `staging-migracion.sh relacionadas` | DB regression | `--ya-aplicada ROLLBACK-398` on applied staging | N/A (verification) | Broad `TOTAL 100 | SAME 99 | DIFF 1` (only `delivery-feed-evidence`) | Targeted patterns on registrar/cross/deposit | The 397 assertion gained a 398-only cutover shim |

### Deviations from Design

- **`closed_deposits_gyd` column (prompt instruction).** Design Decision 18 preferred deriving
  the closed deposit part as `closed_total_gyd - closed_operations_gyd - closed_adjustments_gyd`
  and listed a `closed_deposits_gyd` column as a rejected alternative. The slice prompt
  explicitly requires `closed_deposits_gyd` in the reset snapshot, so 398 adds the column
  (additive, `NOT NULL DEFAULT 0`) and the reset RPCs write it. 397's migration is not edited;
  ROLLBACK-398 drops only the column. The derived value remains available if the owner prefers
  it.
- **`EXISTS` instead of `JOIN` in the deposit line.** `_reseller_period_counts` checks the
  consumed/not-annulled/not-linked state of the MMG deposit with `EXISTS`. `depositos_mmg.trans_id`
  is the primary key, so this equals the design's `JOIN`, without any risk of row multiplication.
- **Zero-reseller summary.** `crm_revendedores_resumen` builds `grand` from the `agg` CTE in a
  scalar subquery, so an account with no resellers returns `grand` zeros and `resellers: []`
  instead of NULL. Keys and ordering are otherwise unchanged.
- **Additive reset/detail keys.** The reset `closed` object also carries `counted_gyd`; the detail
  `current` and history periods expose `deposits_count`, `counted_gyd`, and the history period
  `closed_deposits_gyd`. All additive; the slice-5 API and slice-6 UI keep working.
- **397 assertion cutover shim.** `supabase/staging/assertions/reseller-totals.sql` now pins
  `reseller_deposit_cutover.cutover_at` to `+infinity` inside its own rolled-back transaction when
  the table exists (the 398-only branch). Its fixtures were written before the marker and create
  operations after the real apply time; without the shim, 398's cutover correctly excluded them
  and the 397 assertion failed at case 5. The base run with 398 rolled back skips the shim.
- **Fallback claim dedupe.** A note with no parsable block records one claim from `p_monto`/
  `p_moneda`/`p_comp_id`; when `p_comp_id` is NULL a retried call can add a second pending claim.
  Such a claim has no reference and can never be attributed, so it is harmless history; the design
  only guarantees idempotence through `comp_id`.

### Related checks

- Broad `relacionadas 398 'revendedor|reseller|deposito|cruzar|verificar|registrar_deposito' supabase/staging/assertions/reseller-deposits.sql --ya-aplicada ROLLBACK-398`:
  `TOTAL 100 | SAME 99 | DIFF 1`. The single DIFF is the known `delivery-feed-evidence` fixture
  flake (`fixture setup failed — no operation created for deal <uuid>`, both sides fail identically;
  the tool compares only the first 90 characters and the random UUID differs).
  Before the 397 shim the same run reported `TOTAL 100 | SAME 98 | DIFF 2`: the extra DIFF was
  `reseller-totals` failing at case 5 because 398's cutover excluded its post-reset fixtures.
- Targeted `relacionadas` for `cerebro_registrar_deposito_si_cliente` → `TOTAL 1 | SAME 1 | DIFF 0`;
  `cerebro_cruzar_deposito` → `TOTAL 20 | SAME 20 | DIFF 0`; `registrar_deposito` →
  `TOTAL 45 | SAME 45 | DIFF 0` (own assertion skipped, `--ya-aplicada ROLLBACK-398`).
  `registrar-deposito-admin`, `verificar-transid`, `cruce-sin-operacion`, `free-deposits`,
  `deposit-skips-stale-or-misfit-operation` all reach `ALL PASS (rolled back on purpose)`;
  `deposit-path-without-deals` and `n8n-repoint` keep their pre-existing fixture failure on both
  sides (SAME, not a new DIFF).
- `supabase/staging/assertions/reseller-totals.sql` with 398 applied and the shim:
  `ALL PASS (rolled back on purpose)`.

### Open Questions

- Design Decision 18 vs. the prompt on `closed_deposits_gyd`: implemented per the prompt; the
  derived alternative is still possible if the owner prefers it.
- No-comp-id fallback claims are not deduplicated on retry (see Deviations); harmless pending rows.
- Slice 7b must decide the Decisor reply route. `rutaAdminAccion` re-checks `ctx.es_admin`, so the
  existing `comando` path is admin-authorized; the reseller route needs a non-admin fixed reply.
- The live production n8n workflow re-check (newer than the 2026-10-28 snapshot) stays in Phase 4.6.

### Commits (slice 7a)

- `8446fbeb` — `feat(sdd): add reseller deposits without operations (398)`


---

## Slice 7b (S7 Decisor reseller route) — task 3B.4

Scope: `pruebas/decisor/decisor.jscode` (one deterministic route), the md5 pin in
`pruebas/decisor/correr.ts`, and the new harness suite `pruebas/decisor/decisor-revendedor.test.ts`.
No migration, no panel change, no n8n write, no production access. The production lineage
(`pruebas/decisor/produccion/`) was not touched; its baseline suite still passes.

### Task Status

| Task | Status | Evidence |
|------|--------|----------|
| 3B.4 Decisor reseller confirmation route | done | RED 18 failed / 7 passed on the new suite; GREEN 25/25; owner amendment (amount in the reply) RED 10 failed / 22 passed → GREEN 32/32; whole Decisor suite `3 files / 270 tests` pass; md5 pin `df39af349e48e210ffe5c4aabbd084c2` |

### What the route does

`rutaRevendedorDeposito(ctx, s, tel)` sits after the admin-action route and the pause / hidden /
assigned / human-recent guards, and before the admin silence. It fires only when:

1. `ctx.es_revendedor === true` (new `Contexto conversacion` field), and
2. this turn carries a receipt: `$('Snapshot final').json.comprobante` is present (or
   `comprobante_duplicado` is true), and
3. the sender is not an admin (`ctx.es_admin` false; the admin route already wins upstream).

It maps the `Cruzar deposito con MMG` verdict to fixed Spanish text and returns the existing
fixed-reply route `{ ruta: 'comando', comando: 'verificar', objetivo: <texto>, valor: null,
telefono_e164: tel }`. That route is the same one the admin cross verdict uses: the workflow's
`Es comando admin?` gate only checks `ruta === 'comando'`, and `Liberar chat` (SQL, returns
`$1 = objetivo` for `verificar`) plus `Confirmar al admin` (HTTP, sends to
`Decisor.telefono_e164`) do not re-check `es_admin` — verified read-only in
`infra/n8n/snapshots/produccion-cerebro-bb175eda-20261028.json`. Therefore the route sends the
fixed text to the reseller's own chat, never reaches the agent, opens no operation and asks for
no beneficiary, and needs no new n8n node or route type.

### Reply copy (owner wording, neutral professional Spanish)

| Cross verdict | Reply |
|---|---|
| `verificado`, `verificado_incompleto`, `verificado_de_mas` | `Depósito verificado por <monto> GYD. Ya lo sumé a tu total.` (without the amount when unavailable) |
| `ya_reclamado`, or `comprobante_duplicado` | `Ese depósito ya lo tenía registrado por <monto> GYD.` (without the amount when unavailable) |
| `sin_correo`, `sin_referencia` | `Todavía no aparece en el banco. En cuanto lo vea te lo confirmo.` |
| `monto_no_coincide`, `deposito_antiguo`, `deposito_anulado`, `no_aplica`, no cross | `Reviso ese comprobante y te confirmo.` |

The amount is the DEPOSIT amount only, never the running total (owner decision 2026-11-24).
Source, in order: `Cruzar deposito con MMG.total_verificado` (the cross's verified sum; it works
for reseller deposits because it does not need an operation), then
`Snapshot final.comprobantes_total` (burst), then `Snapshot final.comprobante.monto` (the receipt
read). `ya_reclamado` returns 0 in `total_verificado`, so it falls to the receipt amount.
Formatting is deterministic Spanish: dot thousands separators, comma decimals, no decimals when
whole (manual formatter, not ICU-dependent). Missing, non-numeric, zero or negative amounts fall
back to the text without amount; the route never prints `undefined`, `NaN` or `null`. No TransID
(owner decision), no emojis, one or two short lines.

### Signal contract for n8n (rollout, not done here)

The Decisor source now expects one new context field:

- `es_revendedor` (boolean) on `Contexto conversacion`, computed from the contact's tags with the
  same rule as `reseller_tag_name_matches` but **inline** so it works before 395 is applied:
  `EXISTS (SELECT 1 FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id
   WHERE ct.contact_id = v.contact_id AND lower(btrim(t.name)) = 'revendedor') AS es_revendedor`.
  Do NOT call `cerebro_es_revendedor` here: that function only exists after 395, and the Decisor
  route is published inert before 398 (4.5).

Rollout still needs, in the same environment and with the skill's backup + `--esperado` procedure:

1. Add `es_revendedor` to the `Contexto conversacion` node (staging first, then production).
2. Publish the Decisor code to n8n (`publicar-decisor`) and confirm `versionId == activeVersionId`.
3. Staging E2E with a PRUEBA reseller (3B.5) and the production go-ahead (4.5).

This executor did not publish anything (task constraint: repo source and tests only).

### Work Unit Evidence

| Evidence | Required value |
|---|---|
| Focused test command and exact result | `npx vitest run pruebas/decisor/decisor-revendedor.test.ts --maxWorkers=4` → RED `Tests 18 failed | 7 passed (25)`; after the route → `Tests 25 passed (25)` |
| Runtime harness command/scenario and exact result | Same suite runs the REAL node through `correrDecisor` (the node's `jsCode` wrapped with `new Function` and a stub of `$()`): reseller + receipt + each cross verdict, duplicate receipt, paused/hidden/assigned/human-recent guards, admin precedence, non-reseller customer branch, reseller without receipt, old context without the field. Whole suite `npx vitest run pruebas/decisor --maxWorkers=4` → `Test Files 3 passed (3) | Tests 270 passed (270)` |
| Rollback boundary | Revert this commit: the route, the harness suite and the md5 pin go away; the Decisor returns to its prior behaviour. The route is inert in any environment whose `Contexto conversacion` does not yet supply `es_revendedor`, so it can ship before the context change. No n8n state was changed |

### TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 3B.4 | `pruebas/decisor/decisor-revendedor.test.ts` | Node harness (real `.jscode`) | Existing `decisor-notas.test.ts` (staging copy) and `produccion/decisor-produccion.test.ts` (production lineage) | `expected 'agente' to be 'comando'` across the four verdicts, the duplicate case and the "never reaches the agent" cases (18 failed / 7 passed); amount amendment RED `expected 'Depósito verificado. Ya lo sumé a tu …' to be 'Depósito verificado por 1.234.567 GYD…'` (10 failed / 22 passed) | `32/32` pass; md5 test passes after the pin update; whole suite `270/270` | Four verdict families, duplicate, each guard (pause/hidden/assigned/human-recent), admin precedence, non-reseller branch, no-receipt reseller, missing context field; amount source priority, Spanish grouping, whole vs decimal, missing/non-numeric/zero fallback | Manual formatter replaced `toLocaleString('es-ES')` because the runtime did not group four-digit amounts consistently; production lineage untouched |

### Deviations from Design

- **Trigger signal.** Design Decision 20 read `$('Registrar deposito auto')` directly. The slice
  instruction preferred an incoming-context signal; the wrapper node does not run on a duplicate
  receipt (`Comprobante nuevo?` is false), so the node output alone could never answer "already
  registered". The route therefore uses the new `ctx.es_revendedor` identity field plus the
  snapshot receipt, and reads the verdict from `$('Cruzar deposito con MMG')` (already read by the
  admin route). This also matches the existing per-turn context pattern (`ctx.dup_etapa`,
  `ctx.es_admin`). Consequence: the n8n `Contexto conversacion` node must add `es_revendedor`.
- **Reply route.** Reused `comando`/`verificar` instead of adding `ruta: 'respuesta_fija'`,
  because the read-only workflow snapshot proves the downstream path does not re-check
  `es_admin`. No n8n node change beyond publishing the Decisor.
- **Copy (owner amendment 2026-11-24).** The verified and already-claimed replies include the
  deposit amount only, never the running total: `Depósito verificado por <monto> GYD. Ya lo sumé a
  tu total.` and `Ese depósito ya lo tenía registrado por <monto> GYD.` The not-found and review
  texts are unchanged. No TransID, per the same owner decision. Missing/non-numeric/zero amounts
  fall back to the text without amount.
- **Duplicate replies.** A resent reseller receipt replies "already registered" deterministically.
  The generic duplicate branch (`ctx.dup_etapa`) cannot see reseller claims: they live in
  `reseller_deposits`, not `remittance_operation_receipts`.

### Related checks

- `npx vitest run pruebas/decisor --maxWorkers=4` → `Test Files 3 passed (3) | Tests 270 passed (270)`
  (staging copy, production lineage and the new reseller suite).
- No file outside `pruebas/decisor/` was changed; no formatter was run on the `.jscode` (diff is
  +39 lines, no reflow).
- Read-only workflow check: `Es comando admin?` condition = `ruta === 'comando'`; `Liberar chat`
  for `verificar` returns `$1`; `Confirmar al admin` sends `$json.resultado` to
  `Decisor.telefono_e164`. No `es_admin` re-check downstream.

### Open Questions

- `Contexto conversacion` field name: `es_revendedor` is the minimal choice. If the owner prefers
  the deposit signal explicit, the same route can read `ctx.deposito_revendedor` instead; only
  the condition line changes.
- The owner decided amount only (no running total) and no TransID. The spec's richer variant
  (TransID) is deliberately not used; confirm nothing else is desired before the production
  publish (4.5).
- `comprobante_duplicado` is treated as "already registered". For a reseller whose first claim is
  still pending, a resend also answers "already registered"; this is accurate (it was recorded) but
  the owner may prefer "still checking" for pending claims. Not observable from the Decisor today
  without a new context field.

### Commit (slice 7b)

- `7e4396db` — `feat(sdd): add Decisor reseller deposit reply route`
- `6a5ccc15` — `docs(sdd): record slice 7b Decisor reseller route`
- `3c89d76d` — `feat(sdd): include reseller deposit amount in Decisor replies` (owner amendment)

---

## Slice 7c (S7 panel deposit line) — task 3B.6

Scope: `src/lib/resellers/read-model.ts` (+ test), the route tests' fixtures under
`src/app/api/revendedores/**` (route implementations untouched), `src/components/resellers/*`,
`src/components/finanzas/revendedores-tab.tsx` (+ test), `src/components/inbox/contact-sidebar.test.tsx`
(fixture only) and `messages/es.json` / `messages/en.json`. No migration, no database write, no n8n
change, no production access.

### Task Status

| Task | Status | Evidence |
|------|--------|----------|
| 3B.6 Read model and UI deposit line | done | RED: 8 files / 19 tests failing; GREEN: 24 files / 376 tests passing; `tsc` and `eslint` exit 0 |
| 3B.5 Decisor staging publish + staging E2E | pending, owner-gated | Not part of slice 7c; requires publishing the 3B.4 Decisor to staging n8n and the owner's staging login. No n8n write and no fixture created |

### What the slice does

- `read-model.ts` maps the 398 additive keys: `depositsGyd`, `depositsCount`, `countedGyd`
  (deposits + historical operations) and `historicalOperationsGyd` (explicit alias of the RPC's
  `operations_gyd`; `operationsGyd` is kept for the slice-5 contract). Detail adds `pendingClaims`;
  periods add `depositsGyd`, `depositsCount`, `countedGyd`, `closedDepositsGyd`; the reset `closed`
  snapshot adds `depositsGyd`/`historicalOperationsGyd`/`countedGyd`.
- Finanzas: the grand block shows Depositado (counted), verified deposits, adjustments, reseller
  count and historical operations (only when non-zero); rows replace the operations column with
  Depositado + a small deposits line and, only when non-zero, historical operations; the total stays
  `totalGyd`.
- Detail drawer: Depositado, verified deposits, adjustments and total; historical operations only
  when non-zero; a pending-claims badge with a short explanation (`pendingClaimsHint`).
- History: each closed period shows its deposits and, when it differs, the confirmed deposit snapshot.
- Sidebar: total, Depositado/deposits/historical (non-zero)/adjustments split and the pending-claims
  count.
- Reset dialog: shows the amount being closed (still `totalGyd`) plus the breakdown (deposits,
  historical operations only when non-zero, adjustments). The breakdown is informational; the
  request still sends only the expected total.
- Locales: new `Resellers.deposited`, `deposits`, `historicalOperations`, `adjustments`,
  `pendingClaims`, `pendingClaimsHint`; `columns.deposited`; `sidebar.*` additions; `history.deposits`,
  `history.closedDeposits` — neutral professional Spanish, ICU signatures mirrored.

### Work Unit Evidence

| Evidence | Required value |
|---|---|
| Focused test command and exact result | `npx vitest run src/lib/resellers src/app/api/revendedores src/components/resellers src/components/finanzas src/components/inbox/contact-sidebar.test.tsx src/i18n/messages-parity.test.ts --maxWorkers=4` → `Test Files 24 passed (24) │ Tests 376 passed (376)`; `npx tsc --noEmit` → exit 0; `npx eslint src/components/resellers src/components/finanzas/revendedores-tab.tsx src/lib/resellers src/app/api/revendedores` → exit 0 |
| Runtime harness command/scenario and exact result | Component tests run the real components in jsdom under a real `NextIntlClientProvider` with the Spanish catalog, a mocked auth role and a stubbed `fetch`; they exercise the rendered Depositado/deposits/historical lines, the non-zero-only historical label, the pending-claims note, the history deposit/snapshot lines and the reset-dialog breakdown. Route tests drive the real handlers in-process with 398-shaped jsonb fixtures (no live HTTP server; sibling pattern). `npx vitest run src/lib/finanzas 'src/app/(dashboard)/finanzas/page.test.tsx' --maxWorkers=4` → 8 files / 84 tests |
| Rollback boundary | Revert `3bac34ae`: the new read-model keys, UI lines and locale keys disappear; the additive keys leave the 397 contract and the migrations untouched. No database or n8n change |

### TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 3B.6 (read model) | `src/lib/resellers/read-model.test.ts` | Unit | 397 contract from slice 4; 398 jsonb shapes read from the migration | missing `depositsGyd`/`countedGyd`/`historicalOperationsGyd`/`pendingClaims`/period deposit keys | maps numbers and decimal strings; absent 398 keys default to 0 | summary+grand, detail+periods, reset closed, 397-shaped payload | none needed |
| 3B.6 (routes) | `src/app/api/revendedores/**/route.test.ts` | Route | Real handlers, mocked session/RPC | old expected shapes lacked the new keys (`toEqual` mismatches) | 398 fixtures map to the new wire shape | summary grand/row, detail `pendingClaims`, reset `closed` | none needed |
| 3B.6 (tab) | `src/components/finanzas/revendedores-tab.test.tsx` | Component (jsdom) | Slice-5 wire model; real `next-intl` | new lines and texts absent | 8/8 | grand vs row breakdown, historical non-zero only, pending note, reset breakdown | none needed |
| 3B.6 (sidebar/history/reset) | `reseller-sidebar-block.test.tsx`, `reseller-history.test.tsx`, `reseller-reset-dialog.test.tsx` | Component | Existing component suites | deposit lines, pending count and breakdown prop absent | sidebar 5/5, history 5/5, dialog 5/5 | counted vs deposits vs historical, zero-suppression, confirmed snapshot, 409 unchanged | none needed |

### Deviations from Design

- **`historicalOperationsGyd` is an explicit alias of `operationsGyd`.** Both map the RPC's
  `operations_gyd`, which after 398 is historical operations only. Keeping `operationsGyd` preserves
  the slice-5 wire contract; the UI reads the clearer name.
- **Pending claims are not shown per row in the Finanzas list.** `crm_revendedores_resumen` does not
  return `pending_claims` (only `crm_revendedor_detalle` does). Surfacing it per list row would need
  a new RPC key (a 398 amendment, out of this slice) or an N+1 detail fetch. The count is shown in
  the detail drawer and the contact sidebar, which read the detail RPC.
- **Absent 398 keys default to 0**, as the task requires. A 397-only payload therefore maps
  `countedGyd` to 0 even though `totalGyd` is non-zero; the panel ships after 398 (Phase 4.7), so no
  production payload reaches that branch.
- **Depositado = `counted_gyd`** (verified deposits + historical operations), matching the spec's
  deposited line; deposits and historical operations stay separate lines and the total is
  `counted + adjustments`.
- **Reset dialog breakdown is informational.** It is derived from the already-loaded summary/detail;
  the reset request still carries only `expectedTotalGyd`, so the RPC contract is unchanged.
- Authored size is 557 insertions / 63 deletions (620 lines, tests included), above the ~400
  advisory. It is delivered as one work unit under the accepted `feature-branch-chain` strategy
  (no PR flow); nothing was compressed or omitted to fit the number.

### Related checks

- `npx vitest run src/i18n/messages-parity.test.ts --maxWorkers=4` included in the full slice run:
  4/4, no missing/extra keys and matching ICU signatures.
- `src/components/inbox/contact-sidebar.test.tsx` reseller fixture updated to the new camelCase
  shape; the block still renders for a tagged contact and makes exactly one request, and an untagged
  contact renders nothing.
- Route implementations were not edited: the read model stays the single snake_case -> camelCase
  mapping point, so only their fixtures/expectations changed.

### Open Questions

- Owner wording for the new Spanish labels ("Depositado", "Operaciones históricas", pending-claims
  note) is neutral professional Spanish; confirm it in the staging E2E (3B.5).
- A per-row pending-claims badge in the Finanzas list needs `pending_claims` in
  `crm_revendedores_resumen` (398 amendment) or a batched detail call; left out of this slice.

### Commits (slice 7c)

- `3bac34ae` — `feat(sdd): show deposits-based reseller totals in the panel`

## Staging n8n rollout (3B.5 n8n half, 2026-11-24)

Applied to staging workflow `U52y1kSNvhgxvWeb` only; production `jEzlVLCLUaJhVwzs` was not
touched, no workflow was executed, and the API key was never printed.

### What changed

- `Contexto conversacion` (Postgres) returns one new inline boolean field, placed right after
  `es_recurrente`, so the node keeps its single-row flat-column shape and the Decisor reads it as
  `ctx.es_revendedor`:
  `EXISTS (SELECT 1 FROM contact_tags ct JOIN tags t ON t.id = ct.tag_id WHERE ct.contact_id = v.contact_id AND t.account_id = v.account_id AND lower(btrim(t.name)) = 'revendedor') AS es_revendedor`.
  It does not call `cerebro_es_revendedor`, so it works regardless of migration order. The rest of
  the query is byte-identical (`query_md5` `89084f7b`), `options.queryReplacement` is untouched and
  no other node, connection or setting changed.
- Decisor published from `pruebas/decisor/decisor.jscode` with
  `publicar-decisor staging --esperado d64e8009`.

### Evidence

| Item | Value |
|---|---|
| Backup before any write | `/home/onlinefreedom/cerebro-fase1/respaldos-n8n/staging-U52y1kSNvhgxvWeb-f0c0051d-b6e3-4a07-91d1-f303ef142b3a-20261124-210456.json` (a second pre-write backup, same versionId, at `...-20261124-210606.json`) |
| versionId before | `f0c0051d-b6e3-4a07-91d1-f303ef142b3a` |
| versionId after Contexto | `4fda4d70-7757-4791-94a2-65416c2e7f30` |
| versionId / activeVersionId after Decisor | `baaf643b-32be-4709-a229-f1bf241bf49f` (equal), active true |
| Node count | 133 before and after |
| Decisor md5 | `df39af34` live = `df39af34` repo (`repo_md5_match: yes`) |
| versionId trap | Not needed; every step ended with versionId == activeVersionId |

### Remaining

1. Staging E2E with a PRUEBA reseller (3B.5): receipt matching a PRUEBA `depositos_mmg` row →
   fixed confirmation with the deposit amount, no operation, total increases in Finanzas; resend →
   "already registered"; unknown reference → "not verified yet" and claim pending. Clean up
   fixtures. Needs the owner's staging login for the panel part (`wacrm-probar-staging`).
2. Production 4.5, only after an explicit owner go-ahead: add the same field to production's OWN
   `Contexto conversacion` (staging and production queries differ; never copy the staging node),
   back up, publish the Decisor and confirm versionId == activeVersionId.
