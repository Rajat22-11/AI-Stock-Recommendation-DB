#!/usr/bin/env bash
# Compares prod policy config (incl. protocol and fill_rules text) with a database built
# from the repo's migrations (delivery-pipeline: "Nightly drift detection").
# Runtime keys are ignored: they are written by runs, never by migrations.
#
# Env: SUPABASE_DB_URL  prod connection string (required)
#      LOCAL_DB_URL     replayed database (default: local Supabase on 54322)
# Exit: 0 = identical, 1 = drift (unified diff on stdout), 2 = usage/connection error
set -euo pipefail

: "${SUPABASE_DB_URL:?SUPABASE_DB_URL is required}"
LOCAL_DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

RUNTIME_KEYS="'processed_through','book_started_on'"
Q="select key || E'\t' || value::text || E'\t' || coalesce(description, '')
     from public.config where key not in ($RUNTIME_KEYS) order by key"

dump() { psql "$1" -X -v ON_ERROR_STOP=1 -qtAc "$Q"; }

repo="$(mktemp)"; prod="$(mktemp)"
dump "$LOCAL_DB_URL"   > "$repo" || exit 2
dump "$SUPABASE_DB_URL" > "$prod" || exit 2

if diff -u --label repo-migrations --label production "$repo" "$prod"; then
  echo "config drift: none ($(wc -l < "$repo") policy keys compared)" >&2
  exit 0
fi
exit 1
