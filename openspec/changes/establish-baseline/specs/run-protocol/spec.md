## Purpose

Define how each scheduled or ad hoc agent run records itself and writes to the tracker, and where the shared configuration and the written run protocol live, so every run follows the same audited, repeatable sequence.

## ADDED Requirements

### Requirement: Run records
Every agent run SHALL be recorded in `runs` with a `run_type` (weekly_scan, midweek_checkin, adhoc, backfill, processing). Status SHALL be one of running, succeeded, partial or failed, and SHALL default to `running` with `started_at` defaulting to now. Optional fields: trigger id, session id, data_as_of, model, skill_version, data_calls (jsonb), summary, report_ref, notes.

#### Scenario: Run opened
- **WHEN** a run row is inserted with only `run_type = 'weekly_scan'`
- **THEN** it has `status = 'running'`, a `started_at`, and no `finished_at`

#### Scenario: Invalid status rejected
- **WHEN** a run's status is set to `done`
- **THEN** the statement fails with a check-constraint violation

### Requirement: Run closure
A run SHALL be closed by setting `finished_at`, a final status, `data_calls` and `summary`. The system SHALL NOT close stale runs automatically.

#### Scenario: Stale run stays open
- **WHEN** a run started 5 days ago still has `status = 'running'`
- **THEN** it stays `running` until a writer closes it

### Requirement: Tracker configuration registry
The system SHALL keep tracker settings as key → jsonb value rows in `config`, with a description and `updated_at`. Policy keys (paper_capital, position_cap_pct, risk_per_trade_pct, reduced_size_multiple, stop_cap_pct, trim_multiple, trim_fraction, max_open_positions, both cost haircuts, min_closed_trades_before_rule_change, fill_rules, protocol) SHALL come only from migrations.

#### Scenario: Baseline policy values
- **WHEN** the migrations are applied to an empty database
- **THEN** config holds paper_capital 1000000, position_cap_pct 10, risk_per_trade_pct 1, reduced_size_multiple 0.5, stop_cap_pct 8, trim_multiple 1.25, trim_fraction 0.30, max_open_positions 10, cost_roundtrip_pct_liquid 0.5, cost_roundtrip_pct_thin 1.5, min_closed_trades_before_rule_change 30

### Requirement: Runtime configuration keys
Keys `processed_through` (written by ledger processing) and `book_started_on` (the current book's start date) SHALL be runtime state. Migrations SHALL never overwrite them.

#### Scenario: Deploy keeps the watermark
- **WHEN** a migration that changes policy config is deployed to prod with processed_through = 2026-10-09
- **THEN** processed_through is still 2026-10-09 afterwards

### Requirement: Numeric config lookup
The system SHALL provide a lookup that returns a config value as a number, readable by all roles.

#### Scenario: Read capital
- **WHEN** the numeric lookup is called with `paper_capital`
- **THEN** it returns 1000000

### Requirement: Stored run protocol
Config key `protocol` SHALL hold the authoritative run instructions (currently "TRACKER PROTOCOL v1", 6 steps: RUN, SIGNALS, PRICES, PROCESS, REVIEW, CLOSE, plus a Google Drive backlog fallback). Key `fill_rules` SHALL hold a plain-language summary of the ledger rules. Both SHALL match the copy in the repo.

#### Scenario: Protocol text matches repo
- **WHEN** the drift check compares prod `config.protocol` with the repo's baseline text
- **THEN** they are identical

### Requirement: Write order within a run
The protocol SHALL require this order: open the run; insert signals (never update); upsert price bars for pending/open positions and new entries; process the ledger through the last completed session; write reviews; close the run. Positions, events and marks SHALL never be written directly by a run.

#### Scenario: Agent does not hand-write positions
- **WHEN** a run needs P&L for its report
- **THEN** it processes the ledger and reads the views instead of inserting positions or events
