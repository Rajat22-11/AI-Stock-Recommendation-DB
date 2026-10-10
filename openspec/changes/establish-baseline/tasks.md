# Tasks

All prod access in groups 1–5 is **read-only** (fetch, dump, diff, dry-run). Nothing is applied to prod and nothing is committed: Rajat commits and pushes (see Workflow follow-up).

## 1. Tooling and project scaffold

- [x] 1.1 Install the Supabase CLI on Windows (scoop `supabase` or `npm i -D supabase`), pin the version, and verify that `supabase --version` prints it and Docker is running.
- [x] 1.2 Run `supabase init` and set `supabase/config.toml` (`project_id`, `[db] major_version = 17`, unused services such as studio/inbucket/realtime/storage/edge-runtime disabled); verify `supabase db start` boots a local Postgres 17.
- [x] 1.3 Create `.gitignore` (`.env*`, `supabase/.temp/`, `supabase/.branches/`, `*.gpg`, `drift.sql`) and a local untracked `.env` holding `SUPABASE_DB_URL` (session pooler URI incl. password, provided by Rajat; template in `.env.example`); verify `git check-ignore .env supabase/.temp` reports both (after `git init`, or with `git check-ignore --no-index`).
- [x] 1.4 Verify `supabase migration list --db-url "$SUPABASE_DB_URL"` reaches prod and shows 11 remote versions and 0 local (all prod access uses `--db-url`, design D6).

## 2. Recover the baseline (spike — decides D1/D2)

- [x] 2.1 Run `supabase migration fetch --db-url "$SUPABASE_DB_URL"` (or export `statements` with a read-only query if fetch reformats) and verify each file's md5 matches prod: 101914 `ba8839be…`, 102329 `e18774cc…`, 103650 `2c6a2359…`, 104210 `bc427bee…`, 162529 `7eb4a6d3…`, 162622 `4bf8efec…`, 162658 `a3f6bab7…`, 162718 `e036b313…`, 182633 `ec678af4…`, 183036 `47d43b7f…`, 183201 `20442f23…` (full hashes from `md5(array_to_string(statements, E'\n'))`).
- [x] 2.2 Save the prod public-schema dump (`supabase db dump --db-url "$SUPABASE_DB_URL" --schema public`) and the live `pg_get_functiondef` of all 6 public functions to `supabase/snapshots/prod_schema_2026-10-10.sql` and `prod_functions_2026-10-10.sql`; verify both files are non-empty and contain `process_ledger` and `_ledger_manage`.
- [x] 2.3 Replay the 11 recovered migrations on the local DB (`supabase db reset`), dump the local public schema the same way, and record the normalised diff against 2.2; verify the replay itself succeeds. If it fails, stop and switch to the squash fallback described in design.md Risks.
- [x] 2.4 Write `supabase/migrations/<ts>_baseline_reconcile_live_drift.sql`: `create or replace` for `process_ledger` and `_ledger_manage` copied byte-for-byte from 2.2, explicit revoke/grant of EXECUTE matching the prod ACLs, and statements for every other difference found in 2.3 (views, grants, protocol text only if it really differs). Verify by re-running 2.3: the normalised diff is empty.
- [x] 2.5 Verify `supabase db diff --db-url "$SUPABASE_DB_URL" --schema public` prints no changes and `supabase db push --db-url "$SUPABASE_DB_URL" --dry-run` lists only the reconcile migration.

## 3. Schema, access and signal-log tests

- [x] 3.1 Write `supabase/tests/00_schema_contract.test.sql` (12 tables with columns and constraints, 15 views with exact baseline column lists, `security_invoker=true`) and verify it passes with `supabase test db`.
- [x] 3.2 Write `01_access_control.test.sql` (RLS on every table, SELECT allowed and INSERT/UPDATE/DELETE/TRUNCATE denied for anon and authenticated, function EXECUTE ACLs, `search_path=public` on all functions) and verify it passes.
- [x] 3.3 Write `02_signal_log.test.sql` (append-only error text, `tracker.allow_signal_edit` escape hatch, enum checks, defaults, not-null identity fields, FKs to runs/skill_versions, exclusions and rationale PKs, confidence range) and verify it passes.
- [x] 3.4 Write `03_config.test.sql` (baseline policy values and numeric lookup; trade_reviews and reviews check constraints and author default) and verify it passes.

## 4. Ledger tests

- [x] 4.1 Write `supabase/tests/10_ledger_rules.test.sql` with one minimal fixture per paper-ledger spec scenario (rebuild determinism, entry selection incl. provisional and superseded, size rules, costs, priority order, window and expiry, fill at open, out of zone, skip order incl. `size_below_1_share`, cash, both stop legs incl. NULL pivot, trim price, EXIT/REDUCE/TRIM/HOLD timing, ADD cap, stop ratchet, gap through stop, stop beats trim, trim on gap up, P&L and close, marks, watermark and `open_without_recent_bars`); verify every case passes.
- [x] 4.2 Export the golden snapshot read-only from prod (all signals, price_bars, referenced runs and skill_versions, policy config, plus expected positions and events processed through 2026-10-09, without ids or `days_held`) into `supabase/tests/fixtures/snapshot_2026-10-09.psql` (non-`.sql` so the test runner does not execute it); verify the expected rows match prod's 6 positions and 5 events.
- [x] 4.3 Write `11_ledger_golden_snapshot.test.sql` loading 4.2 and comparing `process_ledger('2026-10-09')` output with `results_eq`; verify it passes, and that changing `stop_cap_pct` in the test makes it fail.

## 5. View behaviour tests

- [x] 5.1 Write `supabase/tests/20_views.test.sql` covering the checklist thresholds (volume `weak` > 5×, watch names `pending`, `n/a` on missing), suggestions selection (latest per symbol, 31-day window, exclusions, bucket ordering, `fundable_now`), outcome horizons (first bar on/after +7/+28/+91, `high > alert_trigger`), trade-review auto tags (whipsaw, gap through stop, valid stop), the single `overall` row in v_trade_stats, the one-row v_book_risk, and the no-fill v_equity_daily row; verify the whole suite passes with `supabase test db`.
- [x] 5.2 Run `supabase db lint --schema public --level error` on the local replay and verify it reports no errors.

## 6. CI/CD workflows and scripts

- [x] 6.1 Write `scripts/guard-migrations.sh` (fail on M/D/R of existing migration files vs `origin/main`, and on new versions not sorting after the latest on main); verify with a throwaway local branch that editing an old migration fails and adding a new one passes.
- [x] 6.2 Decide the deploy mechanism: use Supabase's GitHub integration ("Deploy to production" on `main`) instead of a custom workflow, so no deploy workflow, freeze/approval classifier or verify script is kept; verify with `grep -r "deploy.yml\|classify-migrations\|verify-deploy" . --exclude-dir=node_modules` that nothing references them outside the design's rationale (D9).
- [x] 6.3 Write `.github/workflows/pr.yml` (openspec validate --strict, guard, `supabase db start`, `supabase test db`, lint, dry-run push only when secrets exist), pinning the CLI version; verify with `actionlint` (or `act -n`) that it parses.
- [x] 6.4 Document the integration setup and the merge gate (branch protection requiring `PR checks`, direct pushes blocked) in the README, and verify `.github/workflows/` holds only `pr.yml`, `drift.yml` and `backup.yml`, all passing `actionlint`.
- [x] 6.5 Write `scripts/config-drift.sh` and `.github/workflows/drift.yml` (nightly 02:00 IST: `db diff --db-url --schema public` + policy-config compare, create or update one `drift` issue); verify locally that `scripts/config-drift.sh` against prod reports no drift, and `actionlint` passes.
- [x] 6.6 Write `.github/workflows/backup.yml` (weekly + manual: data-only public dump, `gpg --symmetric`, upload-artifact 90 days); verify locally that the dump → encrypt → decrypt round-trip gives a readable file, and `actionlint` passes.

## 7. Agent text snapshots and docs

- [x] 7.1 Create `agent/skill/` and `agent/prompts/` with a README explaining they are read-only copies supplied by Rajat (skill files and scheduled-task prompts), and write `scripts/skill-version.sh`; verify that running it on a sample SKILL.md prints `YYYY-MM-DD-<8 hex>` matching `sha256sum`.
- [x] 7.2 Write the root `README.md` (purpose, layout, local commands `supabase db start` / `supabase test db`, deploy model and merge gate, the rule "never `db reset --linked`", required secrets and environments, data-hygiene items deliberately left out); verify every command in it runs as written locally.

## 8. Integration check

- [x] 8.1 From a clean clone of the working tree: `supabase db reset` → `supabase test db` → `openspec validate --all --strict` → `supabase db push --db-url "$SUPABASE_DB_URL" --dry-run`; verify all pass and the dry run lists only the reconcile migration.

## Workflow follow-up

- Rajat: decide whether `agent/skill/` is committed or git-ignored before the repo goes public.
- Rajat: create the GitHub repo and add secrets `SUPABASE_DB_URL` (session pooler URI) and `BACKUP_PASSPHRASE`; protect `main` (PR required, `PR checks` required, direct pushes blocked). The password in the old `.env` appeared in a chat transcript, so reset it first and use the new one.
- Rajat: take a pre-deploy backup locally (`BACKUP_PASSPHRASE=… bash scripts/backup.sh backup/pre-baseline.sql.gpg`), rename the branch to `main` and push the baseline **before** connecting the Supabase integration. Then connect it (Project Settings > Integrations > GitHub, working directory `.`, Deploy to production on, Automatic branching off). On the next merge to `main` it applies only the reconcile migration: confirm `supabase migration list --db-url "$SUPABASE_DB_URL"` shows 12/12, run `drift.yml` manually (expect no issue), check row counts are unchanged, and check https://paper-pnl.onrender.com/ still loads.
- Archive the change (`/opsx:archive`) after the first clean deploy and drift run.
- Follow-up changes queued from this baseline: ledger stop rule, ledger honouring exclusions, real-fill sync, paper/real `book` split, symbol normalisation, protocol v2 (7-step with RATIONALE), unique (signal, tag) reviews, advisor index fixes, archive-schema export and cleanup, data hygiene (runs 5/6/8, trade_reviews 10).
