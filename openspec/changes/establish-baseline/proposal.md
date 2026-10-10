# Proposal

## Why

The Breakout Tracker database (Supabase project `moqyzjrnqzqzrxiuqyuf`) is live and used every week, but nothing that defines its behaviour is in version control. The 11 applied migrations exist only in prod. Worse, the ledger simulator itself (`process_ledger`, `_ledger_manage`) was installed outside migration history, so replaying the migrations from zero today gives a database without its core function. Every schema change since 2 Oct 2026 has gone straight to production with no review or tests, and nothing can detect drift. This needs fixing now, before the first rule changes (ledger stop, real-fill sync, paper/real book split) start changing P&L-critical code.

## What Changes

- Create the repo structure: `supabase/` (CLI project, migrations, tests), `openspec/specs/` (baseline specs), `agent/` (read-only copies of strategy and prompt text), `.github/workflows/`.
- **Recover the 11 prod migrations exactly** from `supabase_migrations.schema_migrations.statements`, keeping their version numbers, so `supabase db push` treats them as already applied.
- Add **one reconcile migration** that records live objects that never went through a migration: at least `process_ledger` and `_ledger_manage`, plus anything else the replay-vs-prod schema diff finds. Its definitions are copied from prod, so applying it on the first deploy changes nothing.
- Write the **baseline specs** describing today's behaviour exactly as it is, including known quirks: ledger stop = `max(pivot × 0.99, fill × 0.92)`, a 6-step protocol text, and leftover `REFERENCES`/`TRIGGER` grants for anon. They are recorded, not fixed.
- Add **pgTAP tests**: schema and contract tests, the signals append-only guard, access control, and **golden ledger replays** (hand-built scenarios plus a snapshot of real prod signals and bars).
- Add **GitHub Actions**: PR checks (validate specs, guard against edits to existing migrations, replay all migrations from zero, run tests, lint, push dry-run), a **nightly drift check** that opens an issue, and a **weekly encrypted data backup**. **Deploy on merge to `main`** is done by Supabase's own GitHub integration ("Deploy to production"), made safe by branch protection that requires the PR checks.
- Config policy changes (the `config` table, protocol text) ship only as idempotent migrations from now on.
- No change to production behaviour, data, or the public read surface.

## Capabilities

### New Capabilities
- `signal-log`: the immutable decision log: signals (append-only, supersede-to-correct), exclusions, rationale, skill-version linkage, and run records.
- `paper-ledger`: the deterministic paper-trade simulator: rebuild from inputs, fill/skip/expire rules, stop and trim mechanics, management verdicts, costs, marks.
- `market-data`: daily price bars: storage key, sources, upsert-before-process rule.
- `run-protocol`: how an agent run writes to the tracker: run lifecycle, write order, protocol text stored in config, fallback when the DB is unavailable.
- `trade-review`: post-trade and periodic review: per-trade tags, periodic reviews, and the evidence gate on rule changes.
- `performance-analytics`: the read-only views (positions, equity curve, P&L, book risk, signal checklist/plan/suggestions, outcomes, trade review, stats, rule effectiveness, run log, activity).
- `access-control`: RLS, grants and function execute rights; anon/authenticated are read-only, privileged role writes.
- `delivery-pipeline`: how changes reach prod: migrations-only schema changes, PR checks, deploy on merge via the Supabase GitHub integration, merge gate, drift detection, backups, secrets handling.

### Modified Capabilities
- None (no specs exist yet).

## Impact

- **Production DB:** one migration runs that recreates two functions with identical bodies, plus any other no-op reconcile statements. No data changes. The `archive_20261002` schema is left alone and kept out of all diffs.
- **Agent runs:** unchanged. The agent keeps writing data through the Supabase MCP. Schema changes by the agent are only *detected* (nightly drift issue, failing `db push`), not blocked.
- **Website** (separate repo, `paper-pnl.onrender.com`): unaffected. The anon read surface (all public tables + 15 views) is pinned by access-control tests so later changes can't break it by accident.
- **New dependencies:** Supabase CLI (local + CI), Docker (local stack), the Supabase GitHub integration (production deploys), and GitHub Actions secrets `SUPABASE_DB_URL` and `BACKUP_PASSPHRASE`.
- **Public repo:** contains only schema, specs, tests and a strategy-text snapshot. No secrets, no prod data dumps (backups are encrypted, and test fixtures hold only price/signal data that the anon key already exposes).
- **Out of scope** (each a later change): ledger stop rule, real-fill feature, paper/real `book` dimension, symbol normalisation, protocol v2 text (7-step with RATIONALE), agent DDL lockdown, archive-schema cleanup, advisor index fixes, run/review data cleanup.
