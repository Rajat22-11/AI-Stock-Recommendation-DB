## Purpose

Expose read-only views over the signal log and the derived ledger — positions, equity curve, P&L, book risk, signal checklists and plans, suggestions, forward outcomes, trade reviews and rule statistics — as the stable reporting contract used by agent reports and the external website.

## ADDED Requirements

### Requirement: Stable view contract
The system SHALL provide these views, each with at least the columns it has at baseline: v_positions, v_open_positions, v_equity_daily, v_book_risk, v_pnl_monthly, v_pnl_yearly, v_signal_checklist, v_signal_plan, v_suggestions, v_signal_outcomes, v_trade_review, v_trade_stats, v_rule_effectiveness, v_run_log, v_activity. Removing or renaming a view or column SHALL be a breaking change.

#### Scenario: Contract test on columns
- **WHEN** the test suite runs against a database built from migrations
- **THEN** every listed view exists with every baseline column name, in the baseline order

### Requirement: Views respect caller permissions
Every view SHALL run with the caller's privileges (security invoker), so row-level security on the tables underneath applies.

#### Scenario: Invoker security
- **WHEN** the view options are inspected
- **THEN** every listed view has `security_invoker = true`

### Requirement: Position returns
`v_positions` SHALL add to each position its signal's verdict, grade, setup, source, skill version and measurements, plus `realized_return_pct` (realised ÷ gross bought), `r_multiple` (realised ÷ qty_initial × (fill − stop_at_fill)) and `days_held` (to exit date, or to today while open). `v_open_positions` SHALL restrict this to open positions and add the latest mark, distance to stop % and distance to trim %.

#### Scenario: Open position row
- **WHEN** a position is open with a mark on 2026-10-09
- **THEN** v_open_positions shows it with mark_date 2026-10-09 and last_close equal to that mark's close

### Requirement: Daily equity curve
`v_equity_daily` SHALL give one row per session from the day before the first fill up to `processed_through` (or a single row at `processed_through` when nothing has filled), with cash = capital + realised to date − invested, equity = capital + realised + unrealised, day P&L against the previous row (or capital), and return %.

#### Scenario: No fills yet
- **WHEN** no position has a fill date
- **THEN** v_equity_daily returns exactly one row, dated processed_through, with equity equal to paper_capital

### Requirement: Book risk snapshot
`v_book_risk` SHALL return one row: capital, equity, cash, invested, open positions vs maximum, open risk in ₹ and %, average distance to stop and to trim, pending entry count, cash committed to pending entries, and cash left after pending.

#### Scenario: Single row
- **WHEN** v_book_risk is queried
- **THEN** exactly one row is returned

### Requirement: Period P&L
`v_pnl_monthly` and `v_pnl_yearly` SHALL report per period: ending equity, P&L, return %, and trades closed (monthly also realised P&L and winners).

#### Scenario: Month with a closed trade
- **WHEN** one position closed in October 2026
- **THEN** the October 2026 row of v_pnl_monthly shows trades_closed = 1

### Requirement: Signal rule checklist
`v_signal_checklist` SHALL return nine ordered rule rows per signal (close above pivot, breakout volume, 13w SMA rising, distance above SMA, correction depth, close location, why grade, risk to stop, liquidity). Each row has measured value, target text and a status of pass, weak, fail, pending or n/a, using the baseline thresholds.

#### Scenario: Volume thresholds
- **WHEN** an ENTRY signal has vol_mult 6 and req_vol_mult 2
- **THEN** the breakout-volume rule status is `weak`

#### Scenario: Watch names are pending, not failed
- **WHEN** a WAIT_ALERT signal has signal_close below pivot
- **THEN** the close-above-pivot rule status is `pending`

#### Scenario: Missing measurement
- **WHEN** a signal has no `dist_sma_pct`
- **THEN** the distance-above-SMA rule status is `n/a`

### Requirement: Signal trade plan
`v_signal_plan` SHALL give each signal its entry/stop/trim references, size, planned risk and reward %, reward-to-risk, position value, ₹ risk and ₹ reward at trim, capital risk %, checklist pass/weak/fail counts with failed rule names, exclusion flag, and the ledger's book status, reason and fill.

#### Scenario: Plan links to book
- **WHEN** an ENTRY signal has a filled position
- **THEN** its plan row shows book_status `open` and the fill price and date

### Requirement: Suggestions
`v_suggestions` SHALL list, per symbol, the latest live, non-excluded signal dated within 31 days of processed_through (or today) whose verdict is ENTRY/ENTRY_REDUCED (bucket `entry`) or WAIT/WAIT_ALERT (bucket `watch`). Each row joins the plan and rationale, shows book cash and `fundable_now` (position value ≤ cash), and is ordered entry first, then priority, then reward-to-risk.

#### Scenario: Newer verdict replaces older
- **WHEN** a symbol had WAIT_ALERT last week and ENTRY this week
- **THEN** v_suggestions shows only the ENTRY row, in bucket `entry`

#### Scenario: Old signal dropped
- **WHEN** a symbol's latest signal is 40 days before processed_through
- **THEN** it does not appear in v_suggestions

### Requirement: Signal forward outcomes
`v_signal_outcomes` SHALL report, for each live signal, the first date the alert trigger was hit, the first date the stop was touched, 1-week, 4-week and 13-week returns, max rise and max fall within 4 weeks, and the last bar date used.

#### Scenario: Outcome for a watch name
- **WHEN** the first bar after a WAIT_ALERT signal's date with high > alert_trigger is 6 sessions later
- **THEN** trigger_hit_date is that bar's date

#### Scenario: Return horizon uses the first bar on or after the horizon
- **WHEN** no bar exists exactly 28 days after signal_date but one exists 29 days after
- **THEN** ret_4w_pct is computed from the 29-day bar's close against signal_close

### Requirement: Trade review metrics
`v_trade_review` SHALL report per position: MFE % and MAE %, worst move since fill, the strategy stop (fill × 0.92), whether that stop is still intact, ledger risk %, the run after exit within 30 days, the latest human/agent review, and an `auto_tag`.

#### Scenario: Whipsaw auto-tag
- **WHEN** a position closed by stop_hit at or above its stop, and the lowest low since fill is still above fill × 0.92
- **THEN** auto_tag is `whipsaw_tight_stop`

### Requirement: Trade statistics and rule effectiveness
`v_trade_stats` SHALL aggregate positions (closed, open, not filled, win rate, average return, average R, average days held, realised P&L) overall and by verdict, why grade, setup, skill version, and verdict × grade. `v_rule_effectiveness` SHALL give win rate and average R of closed trades for each checklist rule and status.

#### Scenario: Overall row present
- **WHEN** v_trade_stats is queried
- **THEN** it includes exactly one row with dimension `overall`

### Requirement: Run log and activity feed
`v_run_log` SHALL list runs with verdict counts and their latest review. `v_activity` SHALL merge signals and ledger events into one timeline (timestamp, date, kind, symbol, description, price, qty, P&L, links to signal and position).

#### Scenario: Event appears in activity
- **WHEN** the ledger writes a stop_hit event
- **THEN** v_activity contains a row for it with the position id and P&L
