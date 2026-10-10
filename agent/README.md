# agent/ — read-only reference copies

These files are **copies** of text that lives and runs elsewhere. They are kept here so changes
can be reviewed in PRs and so `skill_version` ids can be reproduced. Nothing in this folder is
deployed by the pipeline, and editing a copy here changes nothing in the running system.

| Folder | Source of truth | Who updates the copy |
|---|---|---|
| `skill/` | Claude skill `breakout-with-volume-strategy` (`SKILL.md`, `references/`, `scripts/`) | Rajat, after a strategy change has been applied in Claude |
| `prompts/` | Claude scheduled tasks: Friday weekly scan (`trig_01HAFpWG929SAYtBykPMBpdr`), Tuesday mid-week check-in | Rajat, whenever a scheduled-task prompt is edited |

Rules:
- Agents never edit the skill directly. Rule changes start as `reviews.proposed_change`, are gated by
  `min_closed_trades_before_rule_change`, and are applied in Claude by Rajat. The copy here follows.
- Name prompt files after the run they drive, e.g. `prompts/weekly-scan.md`, `prompts/midweek-checkin.md`.
- Compute the version id that runs record in `skill_versions` / `signals.skill_version`:

  ```bash
  scripts/skill-version.sh agent/skill/SKILL.md                    # date = file's modified date
  scripts/skill-version.sh --date 2026-10-02 agent/skill/SKILL.md  # reproduce a recorded id
  ```

**Before the repo goes public:** decide whether `skill/` is committed or added to `.gitignore`.
The version script works on a local, uncommitted copy either way.
