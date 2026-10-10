## Purpose

Keep a durable record of every verdict the strategy agent gives — including WAIT and NO_GO — with its measured inputs, so that calls can be audited and the ledger can be replayed deterministically from them.

## ADDED Requirements

### Requirement: Signals are append-only
The system SHALL reject any UPDATE or DELETE on a signal with an error telling the caller to insert a new row with `supersedes` set to the old id. This protection SHALL apply to every role, including the privileged role.

#### Scenario: Update is rejected
- **WHEN** a client runs `update signals set stop = 100 where id = 5`
- **THEN** the statement fails with an error containing `signals are append-only: insert a new row with supersedes = 5`
- **AND** the row is unchanged

#### Scenario: Delete is rejected
- **WHEN** a client deletes a signal
- **THEN** the statement fails with the same append-only error and the row still exists

### Requirement: Admin escape hatch for signal edits
The system SHALL allow UPDATE or DELETE on signals only when the session setting `tracker.allow_signal_edit` is `on`.

#### Scenario: Edit allowed with the session flag
- **WHEN** a privileged session runs `set tracker.allow_signal_edit = 'on'` and then updates a signal
- **THEN** the update succeeds

### Requirement: Corrections by supersession
A signal SHALL count as live only while no other signal has `supersedes` equal to its id. Superseded signals SHALL be ignored by the ledger, suggestions and outcome reporting, but stay stored.

#### Scenario: Superseding a signal
- **WHEN** signal 126 is inserted with `supersedes = 4`
- **THEN** signal 4 is no longer live
- **AND** the ledger builds a position from signal 126 and not from signal 4

### Requirement: Verdict and enumerated field vocabulary
The system SHALL accept only these values. `verdict`: ENTRY, ENTRY_REDUCED, WAIT, WAIT_ALERT, NO_GO, TRIM, ADD, HOLD, REDUCE, EXIT. `source`: weekly_scan, midweek_checkin, adhoc, backfill. `setup`: A_base, B_flag, holding, other. `why_grade`: A–D. `stop_basis`: structural, cap8, higher_low, sma, other. `liquidity_tier`: liquid, thin (default liquid). `stage`: 1–4.

#### Scenario: Unknown verdict rejected
- **WHEN** a signal is inserted with `verdict = 'BUY'`
- **THEN** the insert fails with a check-constraint violation

#### Scenario: Defaults applied
- **WHEN** a signal is inserted without `exchange`, `provisional`, `liquidity_tier` or `retro_seeded`
- **THEN** they default to `NSE`, `false`, `liquid` and `false`

### Requirement: Mandatory signal identity fields
Every signal SHALL have `symbol`, `signal_date`, `source` and `verdict`. All measurement fields (pivot, stop, entry zone, vol_mult, sma13, …) SHALL be optional, so that real-fill signals can leave out `pivot`.

#### Scenario: Missing signal_date
- **WHEN** a signal is inserted without `signal_date`
- **THEN** the insert fails with a not-null violation

### Requirement: Signal provenance
A signal MAY reference the run that produced it (`run_id`) and the strategy version (`skill_version`). Both references SHALL be checked by foreign keys against `runs` and `skill_versions`.

#### Scenario: Unknown skill version rejected
- **WHEN** a signal is inserted with `skill_version = '2099-01-01-deadbeef'` and no such row exists in `skill_versions`
- **THEN** the insert fails with a foreign-key violation

### Requirement: Skill version registry
The system SHALL store each strategy version once, keyed by `version` in the form `YYYY-MM-DD-<first 8 hex of sha256(SKILL.md)>`, with `effective_from`, full `sha256` and a `summary`.

#### Scenario: Duplicate version
- **WHEN** a skill version that already exists is inserted with `on conflict do nothing`
- **THEN** no error occurs and exactly one row remains

### Requirement: Signal exclusions
The system SHALL let a signal be withdrawn from the current book by inserting a `signal_exclusions` row (one per signal) with a mandatory `batch` label and `reason`, without deleting the signal. Excluded signals SHALL be flagged `excluded` in checklist/plan views and left out of suggestions.

#### Scenario: Signal excluded twice
- **WHEN** a second exclusion row is inserted for an already-excluded signal
- **THEN** the insert fails with a primary-key violation

#### Scenario: Excluded signal hidden from suggestions
- **WHEN** a recent WAIT_ALERT signal has a row in `signal_exclusions`
- **THEN** it does not appear in the suggestions view
- **AND** it still appears in the checklist view with `excluded = true`

### Requirement: Signal rationale
The system SHALL store at most one rationale per signal (thesis, catalyst, risks, invalidation, alternatives, data_gaps, confidence 1–5), linked to the signal and optionally to the run. `thesis` SHALL be mandatory.

#### Scenario: Confidence out of range
- **WHEN** a rationale is inserted with `confidence = 6`
- **THEN** the insert fails with a check-constraint violation

#### Scenario: Second rationale for the same signal
- **WHEN** a second rationale row is inserted for a signal that already has one
- **THEN** the insert fails with a primary-key violation

#### Scenario: Rationale without a thesis
- **WHEN** a rationale is inserted without `thesis`
- **THEN** the insert fails with a not-null violation
