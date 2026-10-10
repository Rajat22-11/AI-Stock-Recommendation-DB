## Purpose

Simulate paper trades deterministically from the signal log and daily price bars — fills, skips, stops, trims, management actions, costs, daily marks and P&L — so strategy results are computed by rules, never by hand.

## ADDED Requirements

### Requirement: Ledger is rebuilt from inputs on every run
Each time the ledger is processed through a date, the system SHALL discard all positions, events and marks and rebuild them only from signals, price bars and config. The same inputs SHALL always produce the same positions, events, marks and P&L. Position ids are not stable between rebuilds.

#### Scenario: Idempotent replay
- **WHEN** the ledger is processed through 2026-10-09 twice with no input changes in between
- **THEN** both runs produce identical positions, events and marks (ignoring surrogate ids and timestamps)

#### Scenario: Durable data must not reference derived rows
- **WHEN** the ledger is processed again
- **THEN** no non-derived table holds a reference to a position id or event id

### Requirement: Positions come from live non-provisional entry signals
The system SHALL create one pending position for each signal with verdict ENTRY or ENTRY_REDUCED that is not provisional and not superseded, and for no other signals. The exclusions table SHALL NOT be checked (current behaviour): to withdraw an entry, it must be superseded.

#### Scenario: Provisional entry ignored
- **WHEN** a mid-week signal has verdict ENTRY and `provisional = true`
- **THEN** no position is created for it

#### Scenario: Superseded entry ignored
- **WHEN** signal 1 (ENTRY) is superseded by signal 125 (ENTRY)
- **THEN** exactly one position exists, built from signal 125

### Requirement: Planned position size
Planned size (% of capital) SHALL be the signal's `size_pct` when present. Otherwise it SHALL be `min(position_cap_pct, risk_per_trade_pct / risk_pct × 100)` (or `position_cap_pct` when `risk_pct` is missing or ≤ 0), multiplied by `reduced_size_multiple` for ENTRY_REDUCED.

#### Scenario: Explicit size wins
- **WHEN** an ENTRY_REDUCED signal has `size_pct = 5`
- **THEN** planned size is 5 (the reduced multiple is not applied again)

#### Scenario: Risk-based fallback
- **WHEN** an ENTRY signal has no `size_pct` and `risk_pct = 8`, with risk_per_trade 1 and cap 10
- **THEN** planned size is 10 (min(10, 12.5))

### Requirement: Transaction cost haircut
Each position SHALL carry a round-trip cost of `cost_roundtrip_pct_thin` for thin-liquidity signals and `cost_roundtrip_pct_liquid` otherwise. Half SHALL be charged on each buy and each sell, as `round(qty × price × cost_pct / 200, 2)`, and subtracted from realised P&L.

#### Scenario: Liquid fill cost
- **WHEN** 100 shares fill at ₹200 with cost_pct 0.5
- **THEN** the fill event records cost 50.00 and pnl −50.00

### Requirement: Replay order
The system SHALL step through every distinct price-bar date from the earliest position window start up to the requested date. On each date it SHALL process pending and open positions in signal `priority_rank` order (missing ranks last, then position order), trying a fill first and then position management.

#### Scenario: Priority decides who gets the last slot
- **WHEN** two pending positions can both fill on the same day and only one open slot remains
- **THEN** the one with the lower `priority_rank` fills and the other is skipped for max open positions

### Requirement: Entry window
A pending position SHALL only fill on sessions from `window_start` to `window_end` inclusive. A session after `window_end` SHALL expire it. Days with no bar for the symbol SHALL be skipped. At the end of processing, any position still pending whose `window_end` is before the processed-through date SHALL be expired.

#### Scenario: No fill in window
- **WHEN** no session in the window has low ≤ entry_high
- **THEN** the position becomes `expired` with an `expire` event

#### Scenario: Symbol without bars still expires on the next session
- **WHEN** a pending position's symbol has no bars, its window ends 2026-01-06, and another symbol has a bar on 2026-01-07
- **THEN** the position expires on 2026-01-07 with reason "no fill in window"

#### Scenario: No session after the window at all
- **WHEN** no symbol has any bar after window_end and processing runs past window_end
- **THEN** the position expires dated window_end with reason "no fill in window (no price data)"

### Requirement: Fill rule
A pending position SHALL fill on the first in-window session whose low ≤ `entry_high`, at `min(open, entry_high)`. Quantity SHALL be `floor(min(capital × planned_size% , available cash) / fill)`.

#### Scenario: Gap-down open fills at open
- **WHEN** entry_high is 300 and the session opens at 290 with low 285
- **THEN** the position fills at 290

#### Scenario: Price above zone
- **WHEN** the session low is 305 and entry_high is 300
- **THEN** no fill occurs that day and the position stays pending

### Requirement: Pre-fill skip rules
Before filling, the system SHALL skip the position (status `skipped` plus a `skip` event with a reason) if: the session opens at or below the signal stop; the symbol is already held open; open positions have reached `max_open_positions`; the planned budget buys under one share; or available cash buys under one share. Checks SHALL run in that order.

#### Scenario: Open below stop
- **WHEN** a session opens at or below `stop_initial` before any fill
- **THEN** the position is skipped with reason "opened at/below stop"

#### Scenario: Budget below one share
- **WHEN** planned budget is ₹4,000 and the fill price is ₹5,000
- **THEN** the position is skipped with exit_reason `size_below_1_share`

### Requirement: Available cash
Available paper cash SHALL be `paper_capital + sum of all event P&L − sum(qty_open × avg_cost) over open positions`.

#### Scenario: Cash after a loss
- **WHEN** capital is 1,000,000, total event P&L is −20,000, and open cost basis is 300,000
- **THEN** available cash is 680,000

### Requirement: Stop at fill (current rule)
At fill, the stop SHALL be `max(round(pivot × 0.99, 2), round(fill × (1 − stop_cap_pct/100), 2))`. When the signal has no pivot, the signal's own stop SHALL replace the pivot leg. This deliberately differs from the strategy's `fill × 0.92` and is kept as-is until the evidence gate allows a change.

#### Scenario: Pivot leg is tighter
- **WHEN** pivot is 289.65 and fill is 300 with stop_cap 8
- **THEN** stop is max(286.75, 276.00) = 286.75

#### Scenario: Real-fill signal without pivot
- **WHEN** pivot is NULL, signal stop is 259.44, fill is 282.00
- **THEN** stop is max(259.44, 259.44) = 259.44

### Requirement: Trim level
At fill, the trim price SHALL be `round(fill × trim_multiple, 2)`, and the position SHALL be trimmable only once.

#### Scenario: Trim price set
- **WHEN** a position fills at 400 with trim_multiple 1.25
- **THEN** trim_price is 500.00 and trimmed is false

### Requirement: Management verdicts
On each session after fill, the system SHALL apply, once each and at that session's open, every live non-provisional TRIM/ADD/REDUCE/EXIT/HOLD signal for the same symbol dated on or after the fill date and before the session. Effects: EXIT sells all; REDUCE sells max(1, floor(qty/2)); TRIM sells max(1, floor(qty × trim_fraction)) if not yet trimmed; HOLD changes no quantity.

#### Scenario: EXIT applies next session
- **WHEN** an EXIT signal dated Friday exists for an open position
- **THEN** on the next session the whole position is sold at the open, with an `exit` event linked to that signal

#### Scenario: Same-day signal waits
- **WHEN** a management signal is dated on the fill date
- **THEN** it is applied on the next session, not on the fill date

### Requirement: ADD verdict within cap
An ADD signal SHALL buy at the open `floor(min(capital × (size_pct or cap/2)%, capital × cap% − current qty × open, cash) / open)` shares, only if at least one. The average cost SHALL be re-weighted and a buy-side cost charged.

#### Scenario: ADD blocked at cap
- **WHEN** the position's value at the open is already ≥ 10% of capital
- **THEN** no shares are added and no `add` event is written

### Requirement: Stops only ratchet up
When a management signal carries a stop above the position's current stop, the system SHALL raise the current stop to that value and write a `stop_raise` event. The system SHALL never lower a stop.

#### Scenario: Lower stop ignored
- **WHEN** a HOLD signal carries stop 250 and the current stop is 259.44
- **THEN** the stop stays 259.44 and no event is written

### Requirement: Stop execution
After management, if the session low is at or below the current stop, the system SHALL sell the whole remaining quantity at `min(open, stop)` with exit reason `stop_hit`. When the stop and the trim level are both reached on the same day, the stop SHALL take precedence.

#### Scenario: Gap through stop
- **WHEN** the stop is 423.72 and the session opens at 410
- **THEN** the position closes at 410 with rule "gapped through stop: filled at open"

#### Scenario: Stop beats trim
- **WHEN** a session's low ≤ stop and high ≥ trim_price
- **THEN** only the stop exit happens

#### Scenario: Stop checked on the fill day
- **WHEN** a position fills at 100 with stop 98.51 and that same session's low is 98
- **THEN** the position is stopped out on the fill day at 98.51

### Requirement: Automatic one-time trim
If the stop is not hit and the position is not yet trimmed, then when the session high reaches the trim price the system SHALL sell max(1, floor(qty × trim_fraction)) at `max(open, trim_price)` and mark the position trimmed.

#### Scenario: Trim on gap up
- **WHEN** trim_price is 500 and the session opens at 510
- **THEN** the trim sells at 510

### Requirement: Realised P&L and closing
Each sale SHALL book `round(qty × (price − avg_cost), 2) − sell cost` to the position and the event. When the open quantity reaches zero, the position SHALL become `closed` with exit date, price and reason from that sale.

#### Scenario: Full exit closes position
- **WHEN** a sale's quantity equals qty_open
- **THEN** status is `closed`, and exit_date and exit_price equal the sale's date and price

### Requirement: Daily marks
For each processed session, the system SHALL write one mark per position that is open, or closed on that session, holding close, qty_open, cost basis, market value, unrealised P&L and %, realised to date, current stop and distance to stop %.

#### Scenario: Mark for an open position
- **WHEN** an open position has a bar on 2026-10-09
- **THEN** a mark exists for (that position, 2026-10-09) with market_value = qty_open × close

### Requirement: Processing result and watermark
Processing SHALL save the processed-through date in config key `processed_through`. It SHALL return a summary with the date, position counts by status, the event count, total realised P&L, and the open symbols with no bar in the 4 days up to that date.

#### Scenario: Stale-data warning
- **WHEN** an open position's latest bar is 7 days before the processed-through date
- **THEN** its symbol appears in `open_without_recent_bars`
