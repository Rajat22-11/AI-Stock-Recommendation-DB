## Purpose

Capture what each trade and each period taught — per-trade tags and lessons, periodic self-reviews with statistics — and gate any strategy rule change behind a minimum amount of closed-trade evidence.

## ADDED Requirements

### Requirement: Per-trade review tags
The system SHALL store per-trade reviews linked to a signal (and optionally a run), each with one tag from: good_call, winner, valid_stop, whipsaw_tight_stop, gap_through_stop, missed_runner, avoided_loser, bad_entry, rule_violation, data_gap, removed_fresh_start, other. Each review has a mandatory symbol, an optional short lesson, and an author (`agent` or `rajat`, default `agent`).

#### Scenario: Unknown tag rejected
- **WHEN** a trade review is inserted with tag `lucky`
- **THEN** the insert fails with a check-constraint violation

#### Scenario: Default author
- **WHEN** a trade review is inserted without an author
- **THEN** its author is `agent`

#### Scenario: Missing symbol
- **WHEN** a trade review is inserted without `symbol`
- **THEN** the insert fails with a not-null violation

### Requirement: Review writing conventions
Writers SHALL NOT insert a second review with the same (signal, tag), and agents SHALL NOT modify reviews authored by `rajat`. The database does not currently enforce either rule. Both are protocol obligations.

#### Scenario: Duplicate is not blocked by the database
- **WHEN** a second (signal 29, whipsaw_tight_stop) review is inserted
- **THEN** the insert succeeds, and the duplicate is a protocol violation to catch in review

### Requirement: Latest review shown per trade
Reporting SHALL show, for each position, the review tag, lesson and author of the highest-id trade review for that signal.

#### Scenario: Newer review wins
- **WHEN** signal 29 has reviews id 8 (rule_violation) and id 9 (whipsaw_tight_stop)
- **THEN** the trade review view shows `whipsaw_tight_stop` for that position

### Requirement: Counterfactual tagging of non-entries
WAIT and NO_GO signals at least 4 weeks old SHALL be reviewed using their forward outcome: `missed_runner` when the max rise within 4 weeks is ≥ 15%, `avoided_loser` when the max fall within 4 weeks is ≤ −10%.

#### Scenario: Missed runner
- **WHEN** a WAIT signal from 5 weeks ago has max_up_4w_pct = 18
- **THEN** the next review run tags it `missed_runner`

### Requirement: Periodic reviews
The system SHALL store periodic reviews with review_date (required), period (weekly, monthly, quarterly, adhoc), stats (jsonb), observations, lessons, proposed_change, and proposal_status (none, proposed, approved, rejected, applied; default none), optionally linked to a run.

#### Scenario: Invalid period rejected
- **WHEN** a review is inserted with period `daily`
- **THEN** the insert fails with a check-constraint violation

#### Scenario: Proposal status default
- **WHEN** a review is inserted without proposal_status
- **THEN** its proposal_status is `none`

### Requirement: Evidence gate for rule changes
A review SHALL propose a strategy rule change (`proposal_status = 'proposed'`) only when the group concerned has at least `min_closed_trades_before_rule_change` (30) closed trades. Agents SHALL NOT edit the strategy text directly.

#### Scenario: Too little evidence
- **WHEN** the stop-rule group has 5 closed trades
- **THEN** the review records observations only, with `proposal_status = 'none'`
