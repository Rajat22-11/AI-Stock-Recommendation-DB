#!/usr/bin/env bash
# Dumps public-schema data and writes it AES-256 encrypted (delivery-pipeline: "Encrypted weekly backup").
# The plaintext dump only exists in a private (umask 077) temp dir that is deleted on exit.
#
# Usage: scripts/backup.sh <output.sql.gpg>
# Env:   BACKUP_PASSPHRASE (required)
#        SUPABASE_DB_URL   source database (omit, or set DUMP_LOCAL=true, to dump the local stack)
# Restore: gpg --batch --pinentry-mode loopback --passphrase "$BACKUP_PASSPHRASE" -d <file> | psql <url>
set -euo pipefail

out="${1:?usage: scripts/backup.sh <output.sql.gpg>}"
: "${BACKUP_PASSPHRASE:?BACKUP_PASSPHRASE is required}"

if [ "${DUMP_LOCAL:-false}" = "true" ] || [ -z "${SUPABASE_DB_URL:-}" ]; then
  src=(--local)
else
  src=(--db-url "$SUPABASE_DB_URL")
fi

umask 077
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
supabase db dump "${src[@]}" --data-only --schema public -f "$tmp/data.sql" >&2
gpg --batch --yes --pinentry-mode loopback --passphrase "$BACKUP_PASSPHRASE" \
    --symmetric --cipher-algo AES256 -o "$out" "$tmp/data.sql"
echo "wrote $out ($(wc -c < "$out") bytes, encrypted)"
