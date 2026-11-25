# Apply Progress: reseller-totals — slices 1 and 3

Change: `reseller-totals`. This artifact is cumulative: slice 1 (S1 identity DB) and slice 3 (S2 reports,
recorded by an earlier attempt) are both reflected here.

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
