# Apply Progress: reseller-totals — slice 3 (S2 reports)

Change: `reseller-totals`. Slice 3 scope: tasks 2.1–2.4 (read-only pre-apply reports and the
automation tag check). No migration, no `src/` code, no database write.

## Task Status

| Task | Status | Evidence |
|------|--------|----------|
| 2.1 Create `supabase/staging/check-reseller-identity.sql` | done | Read-only script validated on staging (results below) |
| 2.2 Run reports on staging and reconcile with 395 | pending (owner-gated; blocked on 1.2) | Exact commands prepared below; not run |
| 2.3 Production report + owner tag decision | pending (owner go-ahead required) | Exact command and template prepared below; not run |
| 2.4 Verify no automation changes the "Revendedor" tag | done | Read-only inspection (findings below) |

## Work Unit Evidence

| Evidence | Required value |
|---|---|
| Focused test command and exact result | `bash -c 'source infra/db/lib-migracion.sh && psql_staging < supabase/staging/check-reseller-identity.sql'` → exit 0; `A_count: 0`, `B_count: 0`, `C_contact_count: 0`, `C_account_count: 0`, `D_count: 0` |
| Runtime harness command/scenario and exact result | Same command against staging. The script opens `BEGIN; SET TRANSACTION READ ONLY;` and ends `ROLLBACK;`; staging baseline (0 allow-list rows, 0 active; 3 contacts, 3 contact_tags, 4 tags, none `%revend%`) explains the zeros. Production read-only config query: `automation_steps` add_tag/remove_tag = 0, `flow_nodes` set_tag = 0 |
| Rollback boundary | Delete `supabase/staging/check-reseller-identity.sql`; no schema or data change |

## TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 2.1 | `supabase/staging/check-reseller-identity.sql` (run, not a test file) | DB read-only harness | N/A (new file) | N/A — no production behavior added | Ran on staging, exit 0 | N/A — single read-only report | N/A |
| 2.4 | read-only inspection commands | Static/DB read-only | N/A | N/A — investigation only, no code change | Findings recorded | N/A | N/A |

Rationale: Strict TDD applies to behavior changes. Tasks 2.1 and 2.4 add no production code and
no behavior; they add a human-run read-only report and a read-only investigation. The report was
executed on staging (observed result above) instead of a RED/GREEN unit cycle.

## Report Sizes Observed on Staging

| List | Meaning | Count |
|------|---------|-------|
| A | Active allow-list phones with no matching contact (stop being resellers) | 0 |
| B | Contacts tagged "Revendedor" not on the active allow-list (become resellers) | 0 |
| C contact | Contacts the 395 backfill will tag | 0 |
| C account | Accounts where a new "Revendedor" tag will be created | 0 |
| D | Near-miss tag names the rule will not match | 0 |

Close-but-unmatched tag names (D): none on staging. Staging has only 4 tags and none contains
`revend`, so list D is empty there; production list D is still unknown until the owner runs 2.3.

## Task 2.4 — Automation Findings (read-only)

- **n8n production** `jEzlVLCLUaJhVwzs` (126 nodes, versionId `a3d439e9-380f-41fe-bdb2-832e48e84e82`,
  Decisor md5 `d64e8009` matching the repo): no `contact_tags`/`tags` writes. `Contexto conversacion`
  only reads `contact_tags`/`tags` for admin/assignee; `Registrar deposito auto` consumes the
  `es_revendedor` value returned by `cerebro_registrar_deposito`. No node calls `/api/v1/contacts`.
- **Decisor** `pruebas/decisor/decisor.jscode`: zero references to `revend`, `es_revendedor` or `tags`.
- **`infra/ia/`**: read-only tag reads only (`colectar_dia.py` report; `mejora_nocturna.py` prompt
  text mentions Admin/Revendedor as internal tags). No inserts, updates or deletes.
- **Panel automations/flows (production config, read-only)**: 0 `automation_steps` of type
  `add_tag`/`remove_tag` and 0 `flow_nodes` of type `set_tag`; 0 target the reseller tag.
- **DB-side writers**: `sync_tags_cliente` writes only `nuevo`/`cliente`/`recurrentes`;
  `merge_duplicate_contacts()` can move/drop `contact_tags` during contact dedup (not reseller-specific).
- **Residual by-design exposure**: `POST/PATCH /api/v1/contacts` with the `contacts:write` API-key
  scope uses a service-role client (`auth.uid()` NULL), so it can set arbitrary tag names including
  "Revendedor" and bypass the 396 guard. No n8n node uses that path today.
- **Verdict**: no automation adds or removes the "Revendedor" tag today. Future automation/flow
  configs and external API keys must be reviewed because no-session callers bypass the guard by design.

## Prepared Commands — Not Run

Task 2.2 (after 395 is applied on staging):

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

## Commits

- `dc5b4297` — `feat(sdd): add read-only reseller identity pre-apply report`
