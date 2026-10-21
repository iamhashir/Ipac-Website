# IPAC Database — Rules & Workflow

This folder (`supabase/`) is the **single source of truth** for the IPAC database schema.
It is shared by two apps:

| App | Repo | Uses |
|---|---|---|
| Admin panel (web) | `admin-panel` | read/write |
| Tablet app (React Native / Expo) | `ipac-mobile` | read/write |

| Environment | Supabase project ref |
|---|---|
| Production | `fqynbudvpvpiljdrrvem` |
| Staging | `nkpfblyesgqpefdeiqjs` |

Owners: **Steve**, **Malik**. Every migration is reviewed by the other owner before production.

---

## 1. Golden rules

1. **No schema change outside a migration.** Tables, columns, constraints, indexes, functions, triggers, policies, types and grants are changed **only** through a migration file in `supabase/migrations/`. The SQL Editor is for **read-only** queries.
2. **Staging first, always.** A migration is applied to staging, tested, reviewed, and only then applied to production.
3. **Bulk data changes are scripts, not ad-hoc queries.** Any insert/update/delete touching more than a few rows lives in `supabase/scripts/`, has a **dry-run mode**, runs in **one transaction**, and is logged in `docs/db/changelog.md`.
4. **Never edit a migration that has already been applied.** Fix forward with a new migration.
5. **No secrets in the repo.** DB passwords, `service_role` keys and tokens stay in your local `.env` (git-ignored) or the CI secret store.

---

## 2. Daily workflow

```bash
# one-time setup (each developer, Docker Desktop running)
supabase login
supabase link --project-ref nkpfblyesgqpefdeiqjs   # default link = STAGING

# 1. create a migration
supabase migration new add_destination_fk_to_instances
#    -> edit supabase/migrations/<timestamp>_add_destination_fk_to_instances.sql

# 2. apply to staging
supabase db push                                  # linked project = staging

# 3. test (app on staging + SQL checks + tests)
# 4. open a PR, get it reviewed by the other owner

# 5. apply to production (deliberate, explicit URL)
supabase db push --db-url "$PROD_DB_URL"
```

`$PROD_DB_URL` lives only in your local `.env`. Pushing to production must always be an explicit act.

---

## 3. How we change the schema without breaking production

Every structural change follows **expand → migrate → contract**, each step in its own migration and release:

1. **Expand** — add the new structure next to the old one (new column/table/function). Nothing breaks.
2. **Migrate** — backfill data, then switch both apps to the new structure.
3. **Contract** — once no code uses the old structure (check `docs/db/usage-map.md`), remove it.

A change is **not done** until the contract step is merged.

Rules for the tablet app: a schema change must keep working with the app version currently installed on the tablets until the new version is deployed and `min_app_version` is raised.

---

## 4. Migration conventions

- One concern per migration; descriptive name (`add_item_identifiers_table`, not `fix`).
- Make it re-runnable where possible: `create table if not exists`, `create or replace function`, `drop ... if exists`.
- New constraints on existing data: add as `NOT VALID`, clean the data, then `VALIDATE CONSTRAINT` in a later migration.
- Add `comment on table / column` for every new object (used to generate the data dictionary).
- End each file with a commented **rollback** section describing how to undo it.
- Large data backfills go in `supabase/scripts/`, not in migrations.

---

## 5. Naming conventions

| Element | Rule | Example |
|---|---|---|
| Tables | `snake_case`, plural | `items`, `package_contents` |
| Primary key | `id uuid default gen_random_uuid()` | `id` |
| Foreign keys | `<singular_table>_id` | `item_id`, `order_id` |
| Booleans | `is_` / `has_` prefix | `is_confirmed` |
| Timestamps | `timestamptz`, `created_at`, `updated_at` | |
| Quantities, money, dimensions | `numeric` with a `CHECK` (≥ 0) | `quantity numeric check (quantity >= 0)` |
| Codes / statuses | lookup table + FK (or enum) — no free text | `destination_id`, not `destination text` |
| Functions | verb first | `generate_ipac_reference`, `sync_order_planned_items` |

---

## 6. Security rules

- **RLS enabled on every table**, with explicit policies per role. No `USING (true)` unless the table is genuinely public.
- **`SECURITY DEFINER` functions must fix their search path:** `set search_path = public, pg_temp` (or `''` with fully qualified names).
- No function callable by `anon` unless it is required before login — and then it must not reveal user data.
- No debug/test functions in production.
- RLS changes are covered by tests for each role (director, admin, project_lead, packer, sales, client).

---

## 7. Bulk data scripts (`supabase/scripts/`)

Template every script follows:

```sql
create temp table p on commit drop as select
  true as dry_run;            -- true = test (writes nothing), false = write

-- build the plan in temp tables
-- writes guarded by:  where not (select dry_run from p)

-- final SELECT = check table (counts before/after, examples)
```

- Run once with `dry_run = true`, check the numbers, then run with `false`.
- Log every production run in `docs/db/changelog.md`: date, script, who, result counts.

---

## 8. Emergency hotfix

If production must be fixed immediately in the SQL Editor:

1. Apply the fix and note exactly what you ran.
2. **The same day**, write the matching migration file and mark it as applied:
   `supabase migration repair --status applied <timestamp> --db-url "$PROD_DB_URL"`
3. Apply the same migration to staging.

An undocumented production change is treated as a bug.

---

## 9. Pull request checklist

- [ ] Migration applied and tested on staging
- [ ] Works with the tablet app version currently deployed
- [ ] `comment on` added for new tables/columns
- [ ] Rollback section written
- [ ] RLS / security rules respected (section 6)
- [ ] `docs/db/usage-map.md` updated if tables/columns were added or removed
- [ ] Reviewed by the other owner

---

## 10. Documentation

| File | Content |
|---|---|
| `docs/db/README.md` | Current state, findings, risks |
| `docs/db/usage-map.md` | Which app reads/writes which table, column and function |
| `docs/db/security-findings.md` | Open security issues |
| `docs/db/changelog.md` | Production data scripts log |
