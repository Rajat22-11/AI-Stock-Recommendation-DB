#!/usr/bin/env bash
# Prints the skill_versions id for a SKILL.md: YYYY-MM-DD-<first 8 hex of sha256(file)>.
# The date is the file's modified date (as TRACKER PROTOCOL v1 specifies). A git checkout resets
# mtimes, so pass --date to reproduce the id recorded for an older copy.
#
# Usage: scripts/skill-version.sh [--date YYYY-MM-DD] [path/to/SKILL.md]
#        (default path: agent/skill/SKILL.md)
set -euo pipefail

date_override=""
if [ "${1:-}" = "--date" ]; then
  date_override="${2:?--date needs YYYY-MM-DD}"
  shift 2
fi
file="${1:-agent/skill/SKILL.md}"
[ -f "$file" ] || { echo "no such file: $file" >&2; exit 1; }

if [ -n "$date_override" ]; then
  [[ "$date_override" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "bad date: $date_override" >&2; exit 1; }
  day="$date_override"
else
  day="$(date -r "$file" +%Y-%m-%d)"
fi
sha8="$(sha256sum "$file" | cut -c1-8)"
echo "${day}-${sha8}"
