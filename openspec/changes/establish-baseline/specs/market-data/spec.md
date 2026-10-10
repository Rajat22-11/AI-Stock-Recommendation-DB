## Purpose

Store the daily OHLCV bars that the ledger and outcome views replay against, one row per symbol per trading date, with the source of each bar recorded so provisional quote-based bars can be told apart and replaced.

## ADDED Requirements

### Requirement: One bar per symbol per date
The system SHALL store at most one daily bar per (symbol, bar_date). Writers SHALL upsert on that key so a later, better bar replaces an earlier one.

#### Scenario: Duplicate insert rejected
- **WHEN** a plain insert adds a second bar for (SKYGOLD, 2026-10-09)
- **THEN** it fails with a primary-key violation

#### Scenario: Upsert replaces a quote-based bar
- **WHEN** a bar with source `tapetide_quote` exists and an official bar for the same key is upserted
- **THEN** one row remains, holding the official values and source

### Requirement: Bar completeness
Every bar SHALL have open, high, low and close. Volume SHALL be optional. Each bar SHALL record its `source` (e.g. `tapetide`, `tapetide_quote`, `kite`) and its insert time.

#### Scenario: Missing close rejected
- **WHEN** a bar is inserted without `close`
- **THEN** the insert fails with a not-null violation

### Requirement: Bars drive the replay calendar
The ledger SHALL treat the set of distinct bar dates as trading sessions. A symbol with no bar on a session SHALL get no fill, management action, stop check or mark that day.

#### Scenario: Missing bar day
- **WHEN** an open position has no bar on 2026-10-07 but other symbols do
- **THEN** that position has no event or mark dated 2026-10-07

### Requirement: Symbol identity matches signals
Bars SHALL be keyed by the exact `symbol` string used in signals. The system SHALL apply no normalisation (e.g. NSE `BOSCH-HCIL` is stored as `BOSCH_HCIL` in both tables).

#### Scenario: Mismatched symbol spelling
- **WHEN** a signal uses `BOSCH_HCIL` and bars are stored as `BOSCH-HCIL`
- **THEN** the ledger finds no bars for the position and it never fills
