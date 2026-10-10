## Purpose

Keep the tracker publicly readable and privately writable: anonymous and authenticated API clients (such as the website) may read every table and view, while only the privileged role used by the agent and the deploy pipeline may write data or run the ledger.

## ADDED Requirements

### Requirement: Row-level security on every table
Every table in the `public` schema SHALL have row-level security enabled.

#### Scenario: New table without RLS fails tests
- **WHEN** a migration adds a public table without enabling RLS
- **THEN** the access-control test fails in the PR

### Requirement: Public read access
The anon and authenticated roles SHALL be able to SELECT every row of every public table and every public view. Each table SHALL have a permissive SELECT policy with `using (true)` that applies to those roles (directly or via `public`).

#### Scenario: Anonymous read of a view
- **WHEN** an anon client selects from v_suggestions
- **THEN** the query succeeds and returns the same rows a privileged client sees

#### Scenario: Anonymous read of a table
- **WHEN** an anon client selects from signals
- **THEN** all signals are returned

### Requirement: No public writes
The anon and authenticated roles SHALL hold no INSERT, UPDATE, DELETE or TRUNCATE privilege on any public table or view. At baseline they still hold REFERENCES and TRIGGER, which is recorded as-is and is not a write path.

#### Scenario: Anonymous insert rejected
- **WHEN** an anon client inserts into price_bars
- **THEN** the statement fails with a permission error

### Requirement: Ledger execution is privileged
Only the database owner and the service role SHALL be able to execute ledger processing and its internal steps. The numeric config lookup and the signal-mutation guard SHALL stay executable by anon and authenticated, because views and triggers depend on them.

#### Scenario: Anonymous ledger run rejected
- **WHEN** an anon client calls ledger processing through the API
- **THEN** it fails with a permission error and no derived rows change

### Requirement: Fixed function search path
Every function in the public schema SHALL set `search_path = public`.

#### Scenario: Function without search_path fails tests
- **WHEN** a migration adds a public function without a fixed search_path
- **THEN** the access-control test fails in the PR

### Requirement: Archive schema stays private and untracked
The legacy `archive_20261002` schema SHALL NOT be exposed to anon or authenticated, and SHALL be excluded from repo-managed schema, diffs and lints.

#### Scenario: Archive not visible to anon
- **WHEN** an anon client queries archive_20261002.signals
- **THEN** it fails with a permission error
