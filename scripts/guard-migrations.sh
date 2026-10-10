#!/usr/bin/env bash
# Fails a PR that rewrites migration history (delivery-pipeline: "Applied migrations are immutable").
#   - any modified, deleted or renamed file under supabase/migrations/ that exists on the base branch
#   - any added migration whose name is not <14-digit version>_<snake_name>.sql
#   - any added migration whose version does not sort after the latest version on the base branch
# Usage: scripts/guard-migrations.sh [base-ref]   (default: origin/main)
set -euo pipefail

BASE="${1:-origin/main}"
DIR="supabase/migrations"
fail=0

err() { echo "::error::$*"; fail=1; }

# Files that existed on the base branch and were changed, deleted or renamed.
while IFS=$'\t' read -r status path rest; do
  [ -z "${status:-}" ] && continue
  case "$status" in
    M*|D*|T*) err "applied migration must not be modified or deleted: $path ($status)" ;;
    R*)       err "applied migration must not be renamed: $path -> $rest" ;;
  esac
done < <(git diff --name-status --find-renames "$BASE"...HEAD -- "$DIR")

latest_base="$(git ls-tree --name-only "$BASE" "$DIR/" 2>/dev/null \
  | xargs -r -n1 basename | grep -E '^[0-9]{14}_' | sort | tail -n1 | cut -c1-14 || true)"

while read -r path; do
  [ -z "$path" ] && continue
  name="$(basename "$path")"
  if ! [[ "$name" =~ ^[0-9]{14}_[a-z0-9_]+\.sql$ ]]; then
    err "migration name must be <YYYYMMDDHHMMSS>_<snake_case>.sql: $name"
    continue
  fi
  version="${name:0:14}"
  if [ -n "$latest_base" ] && [[ ! "$version" > "$latest_base" ]]; then
    err "new migration $name must have a version later than the latest on $BASE ($latest_base)"
  fi
done < <(git diff --name-only --diff-filter=A "$BASE"...HEAD -- "$DIR")

if [ "$fail" -eq 0 ]; then
  echo "migration guard: OK (latest on $BASE: ${latest_base:-none})"
fi
exit "$fail"
