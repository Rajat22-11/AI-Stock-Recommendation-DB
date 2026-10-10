# Design

## Context

For motivation see proposal.md (Why). The facts below, observed read-only on 2026-10-10, shape the approach:

- **Migration history:** prod has 11 rows in `supabase_migrations.schema_migrations`. Each stores its full SQL as a single statement, between 327 and 11,626 characters.
- **Functions created by migrations:** `block_signal_mutation`, `cfg_num`, `_ledger_sell`, `_ledger_pending`. The live `_ledger_pending`, `_ledger_sell`, `cfg_num` and `block_signal_mutation` bodies match their migration text exactly.
- **Functions created outside migrations:** `process_ledger` (3,804 characters) and `_ledger_manage` (3,929 characters). No migration contains `create function` for either. Their ACLs are `postgres` + `service_role` only, which means someone also revoked or granted privileges outside migration history.
- **Views:** all 15 are defined in migrations and are `security_invoker=true`. Whether their *current* definitions equal the *last* migration that defined them is unverified, and the spike decides it.
- **Grants and RLS:** RLS is on for all 12 tables. anon and authenticated have SELECT, REFERENCES and TRIGGER on every table and view. Every public function has `search_path=public`.
- **Archive schema:** `archive_20261002` has 8 tables, no RLS, and is not reachable by anon. No migration creates it.
- **Config text:** the live `protocol` text starts with the same text as the seed migration. An earlier exact-match check failed, most likely because of quote escaping in the migration literal. The spike will settle it.
- **Local machine:** Windows 11, Docker 28, OpenSpec 1.14.1. No Supabase CLI, and the folder is not a git repo yet. Rajat makes all commits and pushes, and the repo may become public.

### Spike results (tasks 2.1–2.5, 2026-10-10)

- **History:** `supabase migration fetch` recovered all 11 migrations. Each matches prod's stored SQL by md5. The only change is that the CLI appends `;\n` to each file.
- **Replay:** all 11 apply cleanly from an empty database. Afterwards, the only differences from prod are:
  - `process_ledger` and `_ledger_manage` are missing;
  - EXECUTE on `_ledger_pending` had also been revoked from PUBLIC/anon/authenticated outside migrations.

  Tables, views, policies, triggers, indexes and all 13 policy-config values (including the `protocol` text) match. The earlier protocol-drift suspicion was a false alarm.
- **CRLF in prod:** `process_ledger`'s body has CRLF line endings (64 CR bytes; it was created from a Windows client). The reconcile migration keeps them byte for byte, and `.gitattributes` marks it and the `prod_*.sql` fixtures `-text`. Checked: a commit and checkout with `core.autocrlf=true` keeps the bytes.
- **Verification method:** a `pg_dump` text diff that strips `--` lines hides changes to comments inside function bodies, so it is not trusted on its own. The gates are `supabase db diff` (empty) plus an md5 comparison of `prosrc` / `pg_get_functiondef` / ACLs for every public function.
- **CLI behaviour:** when stdout is not a terminal (CI), `migration list` and `db diff` print JSON. `drift.yml` parses the JSON with `jq .diff`.
- **CLI loads `.env`:** the CLI automatically loads `.env` from the project root, and `SUPABASE_PROJECT_ID` there overrides `config.toml`'s `project_id`. Local containers are therefore named after the prod ref. This is harmless, but it is documented in the README.

## Goals / Non-Goals

**Goals:**
- A repo-built database whose public schema is identical to prod, proven by a diff, before anything is deployed.
- The first deploy to prod changes nothing observable.
- Every rule in the `paper-ledger` spec is checked by a test that runs on every PR.

**Non-Goals:**
- Changing any behaviour, including recorded quirks: the pivot-leg stop, exclusions being ignored by the ledger, leftover REFERENCES/TRIGGER grants, and no unique constraint on (signal, tag) reviews.
- Blocking the agent's direct DDL. Detection only.
- Cleaning up data (stale runs 5/6/8, `trade_reviews.id=10`) or the archive schema.
- Changes to the website repo.

## Decisions

### D1. Recover the history exactly, rather than pull or squash
Use `supabase migration fetch --db-url`, which writes `supabase/migrations/<version>_<name>.sql` from the remote history table. Then check every file against prod with `md5(array_to_string(statements, E'\n'))` (expected hashes are in tasks.md). If `fetch` reformats anything, export the statements with a read-only query instead.

- *Rejected: `supabase db pull`.* It generates a fresh diff-based migration, not the original SQL, and needs `migration repair` to reconcile versions.
- *Rejected: squashed baseline.* It loses the provenance we already have, and still needs a repair.

### D2. One reconcile migration for objects created outside migrations
Add `supabase/migrations/<ts>_baseline_reconcile_live_drift.sql` containing:

- `create or replace function` for `process_ledger(date)` and `_ledger_manage(bigint, date)`, taken from prod `pg_get_functiondef` and kept byte-for-byte.
- Explicit `revoke execute … from public, anon, authenticated` and `grant execute … to service_role` statements, so a fresh replay ends up with the prod ACLs. Supabase's default privileges would otherwise grant anon EXECUTE on new public functions.
- Any further statements needed to make the replay-vs-prod diff empty, for example view redefinitions, grants, or a protocol-text upsert if the text really did drift.

The first deploy applies it to prod. Because every statement reproduces the current prod state, nothing changes, and the pipeline gets exercised end to end on a harmless migration.

- *Rejected: marking it applied with `migration repair` and never running it.* It saves one deploy, but the first real deploy would then be a meaningful change going through an untested pipeline.

### D3. The diff is the acceptance gate
The baseline is accepted only when the local replay (`supabase db start` + all migrations) and prod produce identical public-schema dumps (`supabase db dump --schema public`, normalised: comment lines and `SET` lines stripped), and `supabase db diff --db-url "$SUPABASE_DB_URL" --schema public` prints nothing. The same command is reused by the nightly drift job.

### D4. Policy config ships as migrations, with no seed step
Policy keys change only through `insert … on conflict (key) do update set value = excluded.value, description = excluded.description, updated_at = now()`. Runtime keys (`processed_through`, `book_started_on`) are never touched by migrations. `supabase/seed.sql` is not used for prod (the CLI never runs it on push). It stays empty, because tests load their own fixtures. The drift job compares prod policy config with the config in a fresh replay. Both are produced from migrations, so no separate text file is needed.

### D5. Tests: pgTAP via `supabase test db`
Layout under `supabase/tests/`:

| File | Covers |
|---|---|
| `00_schema_contract.test.sql` | tables, columns, constraints, the 15 views with exact column lists, security_invoker |
| `01_access_control.test.sql` | RLS on, SELECT policies, anon/authenticated privileges, function ACLs, search_path; uses `set local role anon` |
| `02_signal_log.test.sql` | append-only trigger, escape hatch, check constraints, defaults, FKs |
| `03_config.test.sql` | baseline policy values, numeric lookup |
| `10_ledger_rules.test.sql` | one small fixture per paper-ledger scenario (fill at open, out of zone, expiry, skip order, below one share, cash, stop formula both legs, management verdicts, ADD cap, ratchet, gap through stop, stop beats trim, trim on gap up, marks, watermark, determinism) |
| `11_ledger_golden_snapshot.test.sql` | prod snapshot replay |
| `20_views.test.sql` | checklist thresholds, suggestions selection, outcomes horizons, trade-review auto tags, trade-stats overall row |

Each file runs in its own transaction and rolls back. Fixtures insert runs, skill_versions, signals and price_bars, then call `process_ledger(<date>)` and compare with `results_eq` against literal `VALUES` (ids excluded, ordered by symbol/date/type).

**Golden snapshot:** a read-only export, taken at implementation time, of all `signals`, `price_bars`, the `runs` and `skill_versions` they reference, and the policy config. It is stored as `supabase/tests/fixtures/snapshot_2026-10-09.psql` (a non-`.sql` extension, so `supabase test db` does not execute it as a test; reference dumps that tests never load live in `supabase/snapshots/`), with the expected output from prod's current `positions`/`events` (processed through 2026-10-09). This data is already readable by anon through the public API, so committing it publishes nothing new. Columns that depend on `current_date` (`days_held`) are excluded from comparisons.

### D6. Workflows

```
pr.yml (pull_request -> main)
  openspec validate --all --strict
  guard-migrations.sh   (git diff --name-status origin/main: M/D/R under supabase/migrations -> fail;
                         new versions must sort after the latest on main)
  supabase db start  ->  supabase test db  ->  supabase db lint --schema public --fail-on error
  supabase db push --db-url --dry-run   (only when the secret is available)

Deploy: no workflow in this repo. The Supabase GitHub integration ("Deploy to production" on branch
        main, working directory ".") applies new migrations when a commit lands on main (design D9).

drift.yml (cron 30 20 * * *  = 02:00 IST)
  supabase db start (replay) ; supabase db diff --db-url $SUPABASE_DB_URL --schema public > schema-drift.sql
  scripts/config-drift.sh: policy config, prod vs replay (runtime keys excluded)
  non-empty -> gh issue create/edit, label "drift" (one open issue, body replaced); job fails

backup.yml (cron Sunday 02:30 IST, workflow_dispatch)
  scripts/backup.sh: supabase db dump --db-url --data-only --schema public -> gpg --symmetric AES256
  upload-artifact (retention 90 days)
```

The Supabase CLI version is pinned in every workflow via `supabase/setup-cli` with a fixed `version`, so local and CI behave the same.

All database access in CI and locally goes through one connection string, `SUPABASE_DB_URL` (session pooler URI; it embeds the DB password), via `--db-url`. This avoids `supabase link` state and access tokens. GitHub Actions secrets:
- `SUPABASE_DB_URL`: PR dry-run, drift and backup jobs.
- `BACKUP_PASSPHRASE`: backup encryption.

`SUPABASE_DB_PASSWORD`, `SUPABASE_ACCESS_TOKEN` and `SUPABASE_PROJECT_ID` are not needed in GitHub. The deploy credentials live inside Supabase's own GitHub integration.

### D9. Deploy through the Supabase GitHub integration, not our own workflow
Connect the repo under Project Settings > Integrations > GitHub, with working directory `.`, **Deploy to production** on, and **Automatic branching** off (branching is Pro-only; this project is on Free). Per Supabase's docs this works on all plans and applies new migrations on a push or merge to the production branch. Only `supabase/` content is deployed; `config.toml` API/Auth settings and `seed.sql` are ignored.

What this replaces: the earlier draft had `deploy.yml` plus `classify-migrations.sh` and `verify-deploy.sh`. Dropping them removes about 200 lines of CI to maintain and the extra secrets.

What is given up, and why that is acceptable here:
- *Friday-evening freeze:* enforced by habit now (README), not by CI. Rajat is the only person merging.
- *Manual approval for destructive migrations:* the PR review is the gate. A second approver would be Rajat himself.
- *Post-deploy view check:* the nightly drift job and the next agent run catch a broken view within a day. The tests already prove every view works before merge.

Consequence: the integration deploys whatever lands on `main`, so the tests protect production only if merging is blocked until `PR checks` pass. Branch protection with that required check is therefore part of the setup, not optional.

Not verified: how the integration behaves if production has a migration version that the repo lacks (the custom workflow failed without applying anything in that case). The nightly drift job would surface the difference either way.

- *Rejected: keep a custom `deploy.yml`.* It gave the freeze and approval gates, but those protect against team mistakes that don't apply to a single owner.
- *Rejected: a "wait until the run is finished" guard.* Stale `running` rows (runs 5, 6, 8) would block it forever.

### D7. Repository layout

```
/
+- .github/workflows/      pr.yml drift.yml backup.yml
+- .gitignore              .env*, supabase/.temp/, supabase/.branches/, *.gpg, drift.sql
+- openspec/               (existing)
+- supabase/
|  +- config.toml          project_id, [db] major_version = 17; unused services disabled
|  +- migrations/          11 recovered + reconcile
|  +- seed.sql             empty (see D4)
|  +- tests/               *.test.sql, fixtures/
+- scripts/                guard-migrations.sh, config-drift.sh, backup.sh, skill-version.sh
+- agent/
|  +- skill/               read-only copy of SKILL.md + references/ + scripts/ (supplied by Rajat)
|  +- prompts/             scheduled-task prompts (supplied by Rajat)
+- README.md               how to run locally, deploy model, never `db reset --linked`
```

### D8. Scope of every comparison is `public`
Every dump, diff and lint command passes `--schema public`, so `archive_20261002`, `auth`, `storage` and other Supabase-managed schemas never show up as drift.

## Risks / Trade-offs

- **[Replay fails or diverges]** Out-of-band changes may have happened *between* migrations (e.g. a column added by hand that a later view relies on). → The spike (tasks 2.x) finds this before anything else is built. If the replay can't be made faithful with a single trailing reconcile migration, fall back to a squashed baseline: `db dump` the schema as one migration, then `migration repair --status applied`. Keep the 11 recovered files under `supabase/history/` for reference.
- **[Local Postgres image differs from prod 17.11]** → Pin `major_version = 17` and the CLI version. Small catalog differences show up in the diff and are accepted only if they're outside `public`.
- **[Supabase default privileges differ between local and hosted]** → The access-control tests assert explicit ACLs, and the reconcile migration states grants explicitly instead of relying on defaults.
- **[Deploy collides with an agent run]** → No CI freeze any more (D9). Avoid merging Fridays 15:00–23:59 IST (weekly scan) and during a Tuesday check-in. The first deploy replaces two functions with identical bodies, so the risk is a momentary lock. Revisit with a CI freeze if ledger-changing migrations start shipping often.
- **[Agent applies DDL via MCP]** → Caught by the nightly drift issue, whether it used `apply_migration` or `execute_sql`. Prevention is out of scope (user decision).
- **[Public repo exposes the strategy text]** → `agent/` holds a copy of the strategy skill. Before the repo goes public, Rajat decides whether to commit it or add `agent/skill/` to `.gitignore`. The version script works either way locally.
- **[Golden snapshot freezes current quirks]** → Intended. A later change to stop rules must update the expected output, which makes the P&L effect visible in the PR diff.
- **[Merge deploys without passing tests]** → The integration doesn't wait for GitHub Actions. Branch protection must require `PR checks` on `main` (D9), and direct pushes to `main` must be blocked, or the tests protect nothing.

## Migration Plan

1. Local only: install the CLI, `supabase init`, fetch the history, replay it, and diff against prod (read-only on prod). Iterate the reconcile migration until the diff is empty.
2. Write tests and workflows. Run `supabase test db` locally until it passes.
3. Rajat: creates the GitHub repo, adds secrets `SUPABASE_DB_URL` and `BACKUP_PASSPHRASE`, and protects `main` (PR required, `PR checks` required).
4. Rajat takes a pre-deploy backup locally with `scripts/backup.sh` (the workflow can't run before it exists on `main`), then pushes the baseline to `main` **before** enabling the Supabase integration, so the first push deploys nothing.
5. Rajat connects the Supabase GitHub integration (D9). The first later push to `main` applies only the reconcile migration, which changes nothing. Verify: `supabase migration list --db-url "$SUPABASE_DB_URL"` shows 12/12, a manual `drift.yml` run reports no drift, row counts are unchanged, and the website still loads.

**Rollback:** the reconcile migration is a no-op, so there is nothing to undo. If it unexpectedly changed a function, re-apply the previous body captured in the spike (`supabase/snapshots/prod_functions_2026-10-10.sql`) through a new forward migration. No down-migrations are used anywhere. Every fix goes forward through a PR.

## Open Questions

- The exact session-pooler host for `SUPABASE_DB_URL` (from the dashboard's Connect panel). It only fills a secret.
- Whether to add a `CODEOWNERS` file. It only matters if anyone else ever gets write access.
