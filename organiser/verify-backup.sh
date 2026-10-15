#!/usr/bin/env bash
# Restore into a uniquely named temporary database; never overwrite organiser.
set -euo pipefail
cd "$(dirname "$0")"
backup="${1:?Pass a backup path relative to organiser/ or an absolute path}"
[[ -f "$backup" ]]
database="restore_check_$(openssl rand -hex 8)"
docker compose exec -T postgres createdb -U organiser "$database"
trap 'docker compose exec -T postgres dropdb -U organiser "$database"' EXIT
docker compose exec -T postgres pg_restore -U organiser -d "$database" --no-owner --exit-on-error < "$backup"
docker compose exec -T postgres psql -U organiser -d "$database" -v ON_ERROR_STOP=1 -c 'SELECT (SELECT count(*) FROM items) AS items, (SELECT count(*) FROM operations) AS operations, (SELECT count(*) FROM attachments) AS attachments;'
echo 'Backup restored successfully into an isolated temporary database.'
