# Breakout Tracker — database

Schema, ledger simulator, views, tests and CI/CD for the paper-trading audit trail of the
breakout-with-volume strategy. Production is the Supabase project `moqyzjrnqzqzrxiuqyuf`
(Postgres 17, `ap-northeast-1`). The read-only website lives in a separate repo.

This repo is the **only** way schema, functions, views, grants and policy config change.
The agent still writes *data* (signals, bars, runs, reviews) directly; that is never deployed from here.

## How a change reaches production

```
openspec change (proposal -> specs -> design -> tasks)
  -> branch + new migration in supabase/migrations/ + tests
  -> PR: specs validated, migration history guarded, DB rebuilt from zero, pgTAP tests, lint, prod dry-run
  -> review + merge to main (blocked until PR checks pass)
  -> Supabase GitHub integration ("Deploy to production") applies the new migrations to the project
nightly drift.yml: prod vs repo schema + policy config -> GitHub issue labelled "drift"
weekly backup.yml: encrypted public-schema data dump -> workflow artifact (90 days)
```

Rules:
- **Never edit or rename an existing migration.** Add a new one with a later version. CI enforces this.
- **Policy config** (`paper_capital`, stop/trim settings, `protocol`, `fill_rules`, …) changes only through
  a migration using `insert … on conflict (key) do update`. Never write the runtime keys
  `processed_through` and `book_started_on` from a migration.
- **Every commit on `main` is deployed**, and the integration does not wait for GitHub Actions. That is
  why `main` is protected: pull request required, `PR checks` required, direct pushes blocked.
- **Timing is up to you:** there is no CI freeze. Avoid merging on Fridays 15:00–23:59 IST (weekly scan)
  or during a Tuesday check-in. Read any migration containing DROP, TRUNCATE or ALTER … TYPE twice.
- **Never run `supabase db reset --linked`** or point any destructive command at production.
- Changing ledger behaviour means updating the golden expected rows in
  `supabase/tests/fixtures/snapshot_2026-10-09.psql` in the same PR, so the P&L effect is reviewed.

## Layout

| Path | What |
|---|---|
| `openspec/` | Specs (`specs/`) and changes in flight (`changes/`) |
| `supabase/migrations/` | Every schema change, in version order (11 recovered from prod + reconcile) |
| `supabase/tests/` | pgTAP tests run by `supabase test db` (`fixtures/*.psql` are loaded by tests, never run on their own) |
| `supabase/snapshots/` | Read-only reference dumps of production taken for the baseline (not loaded by tests) |
| `scripts/` | CI helpers: migration guard, config drift, backup, skill version |
| `agent/` | Read-only copies of the strategy skill and scheduled-run prompts (see `agent/README.md`) |
| `.github/workflows/` | `pr.yml`, `drift.yml`, `backup.yml` (deploys are done by the Supabase integration, not a workflow) |

## Local development

Needs Node 22+ and Docker Desktop (running). The Supabase CLI and OpenSpec are pinned in
`package.json`, so no global installs are needed.

```bash
npm install
npm run db:start        # local Postgres 17 with all migrations applied
npm run db:test         # all pgTAP tests
npm run db:lint         # schema lint (fails on errors)
npm run specs:validate  # OpenSpec validation
npm run db:rebuild      # throw the local DB away and replay every migration from zero
```

Working with production (read-only commands) needs `.env` (git-ignored; template in `.env.example`):

```bash
set -a; . ./.env; set +a
npx supabase migration list --db-url "$SUPABASE_DB_URL"
npx supabase db diff --db-url "$SUPABASE_DB_URL" --schema public           # empty .diff = no drift
npx supabase db push --db-url "$SUPABASE_DB_URL" --dry-run                  # what a deploy would apply
```

`SUPABASE_DB_URL` must be the **session pooler** URI
(`postgresql://postgres.<ref>:<password>@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres`,
password percent-encoded). The direct `db.<ref>.supabase.co` host is IPv6-only and unreachable from
GitHub runners and most home networks.

Note: the Supabase CLI auto-loads `.env`. If `.env` contains `SUPABASE_PROJECT_ID`, local containers are
named after it instead of `project_id` in `config.toml`. This is harmless, and `.env.example` leaves it out.

## GitHub and Supabase setup (owner)

1. GitHub secrets: `SUPABASE_DB_URL` (session pooler URI; used by the PR dry-run, drift and backup jobs)
   and `BACKUP_PASSPHRASE` (backup encryption).
2. Branch protection on `main`: pull request required, `PR checks` required, direct pushes blocked.
3. Push the baseline to `main` first. Then, in Supabase: **Project Settings → Integrations → GitHub**,
   authorize, choose this repository, working directory `.`, turn **Deploy to production** on and
   **Automatic branching** off (branching needs the Pro plan). Only the contents of `supabase/` are
   deployed; `seed.sql` and API/Auth settings in `config.toml` are ignored.
4. After the next merge: `supabase migration list --db-url "$SUPABASE_DB_URL"` should show every
   migration on both sides, and a manual run of the `Nightly drift check` workflow should find nothing.
5. Restore a backup: `gpg --batch --pinentry-mode loopback --passphrase "$BACKUP_PASSPHRASE" -d <file>.sql.gpg | psql <url>`.

## Known baseline quirks (recorded by specs and tests, deliberately not fixed here)

- Ledger stop is `max(pivot × 0.99, fill × 0.92)`, tighter than the strategy's `fill × 0.92`, and it is
  checked on the fill day too.
- The ledger ignores `signal_exclusions`; withdrawn entries must also be superseded.
- Duplicate `(signal, tag)` trade reviews are not blocked by the database.
- anon/authenticated still hold REFERENCES and TRIGGER on public tables (no write path).
- `process_ledger` has CRLF line endings in production; the reconcile migration keeps them byte for
  byte and `.gitattributes` stops git from normalising them.

Left for follow-up changes: paper/real book split, real-fill sync, symbol normalisation, protocol v2,
agent DDL lockdown, archive-schema cleanup, advisor index fixes, and data hygiene (runs 5/6/8 still
`running`, stale `trade_reviews.id = 10`).
