## Purpose

Make the repository the single source of truth for the tracker's schema, functions, views, grants and policy configuration, and move every such change through review and automated checks before it is deployed automatically to the production project.

## ADDED Requirements

### Requirement: Migrations are the only schema path
Every change to public-schema tables, functions, views, triggers, policies, grants or policy config SHALL arrive in production as a new migration file merged to `main`. Runtime data (signals, bars, runs, reviews, exclusions, rationale, derived ledger rows, runtime config keys) SHALL NOT be deployed by the pipeline.

#### Scenario: Data is not deployed
- **WHEN** a commit is merged to `main`
- **THEN** no signals, price bars, runs or reviews are inserted, updated or deleted by the pipeline

### Requirement: Baseline matches production history
The repo SHALL contain one migration for each migration already applied in production, with the same version number and identical SQL. A database built from all repo migrations SHALL have the same public-schema definition as production at baseline.

#### Scenario: Recognised as applied
- **WHEN** the first deploy runs against production
- **THEN** none of the 11 pre-existing migrations is executed again

#### Scenario: Replay equals prod
- **WHEN** all repo migrations are applied to an empty database and its public schema is compared with production's
- **THEN** the comparison shows no differences

### Requirement: Applied migrations are immutable
A pull request SHALL fail if it modifies, renames or deletes a migration file that exists on `main`, or adds a migration whose version is not later than the latest on `main`.

#### Scenario: Editing an old migration
- **WHEN** a PR changes `20261002101914_tracker_core_schema.sql`
- **THEN** the PR check fails, naming that file

### Requirement: Pull request checks
Every pull request SHALL validate the OpenSpec changes and specs, build a fresh database from all migrations, run the full database test suite, lint the public schema, and show which migrations would be applied to production. Any failure SHALL block merging.

#### Scenario: Failing ledger replay blocks merge
- **WHEN** a PR changes ledger behaviour without updating the golden expected results
- **THEN** the golden replay test fails and the PR cannot be merged

### Requirement: Golden ledger replays
The test suite SHALL include ledger replay cases with fixed signals and bars and exact expected positions, events and realised P&L. These SHALL include hand-built rule cases and a frozen snapshot of production inputs. Changing expected results SHALL require editing the golden files in the same PR.

#### Scenario: Snapshot regression
- **WHEN** the frozen production snapshot is replayed through its recorded date
- **THEN** positions, events and realised P&L equal the recorded expected output exactly

### Requirement: Automatic deploy on merge
When a commit lands on `main`, pending migrations SHALL be applied to the production project in version order by the Supabase GitHub integration, with "Deploy to production" enabled for `main`. The repository SHALL NOT hold production deploy credentials in its own workflows.

#### Scenario: Clean deploy
- **WHEN** a PR adding one migration is merged to `main`
- **THEN** that migration is applied to production and recorded in its migration history

#### Scenario: No data deployed on first connection
- **WHEN** the baseline is first pushed and the integration deploys it
- **THEN** only the reconcile migration is applied, with no seed data and no change to any data table

### Requirement: Merge gate protects production
Because every commit on `main` is deployed, `main` SHALL only receive changes through a pull request whose checks have passed. Direct pushes to `main` SHALL be blocked by branch protection that requires the PR checks.

#### Scenario: Failing tests block merge
- **WHEN** a PR's database tests fail
- **THEN** the PR cannot be merged and nothing is deployed

#### Scenario: Direct push rejected
- **WHEN** someone pushes a commit straight to `main`
- **THEN** the push is rejected by branch protection

### Requirement: Nightly drift detection
A scheduled job SHALL compare production's public schema and policy config (including the protocol and fill-rules text) with the repo once a day. When they differ, it SHALL open (or update) one GitHub issue containing the difference.

#### Scenario: Out-of-band function change
- **WHEN** a function in production was replaced directly through SQL
- **THEN** the next nightly run opens a drift issue showing the changed definition

#### Scenario: No drift
- **WHEN** production matches the repo
- **THEN** no issue is opened

### Requirement: Encrypted weekly backup
A scheduled job SHALL export production data weekly, encrypted with a key held only in repository secrets, and keep it as a workflow artifact. No unencrypted production data SHALL be committed or published.

#### Scenario: Backup is not readable without the key
- **WHEN** someone downloads the backup artifact from the public repository
- **THEN** they cannot read it without the backup passphrase

### Requirement: Secrets never in the repository
Database passwords, access tokens, service-role keys, broker tokens and backup keys SHALL exist only as CI secrets or local untracked files. The repository SHALL ignore local environment and Supabase temp files.

#### Scenario: Ignored local secrets
- **WHEN** a developer has a local `.env` with the DB password
- **THEN** git status does not list it as a file to commit

### Requirement: Strategy and prompt text snapshots
The repo SHALL hold read-only copies of the strategy skill files and the scheduled-run prompts, plus a script that computes the skill version id (`YYYY-MM-DD-<first 8 hex of sha256(SKILL.md)>`) from the copy. The copies are reference only and SHALL NOT be deployed anywhere by the pipeline.

#### Scenario: Version id from snapshot
- **WHEN** the version script runs on the snapshot of SKILL.md last modified 2026-10-02
- **THEN** it prints an id of the form `2026-10-02-xxxxxxxx` matching sha256 of that file
