#!/usr/bin/env bash
# Restore into a uniquely named temporary database; never overwrite organiser.
set -euo pipefail
cd "$(dirname "$0")"
backup="${1:?Pass a backup path relative to organiser/ or an absolute path}"
[[ -f "$backup" ]]
database="restore_check_$(openssl rand -hex 8)"
docker compose exec -T postgres createdb -U organiser "$database" < /dev/null
trap 'docker compose exec -T postgres dropdb -U organiser "$database"' EXIT
docker compose exec -T postgres pg_restore -U organiser -d "$database" --no-owner --exit-on-error < "$backup"
docker compose exec -T postgres psql -U organiser -d "$database" -v ON_ERROR_STOP=1 <<'SQL'
SELECT (SELECT count(*) FROM items) AS items,
       (SELECT count(*) FROM operations) AS operations,
       (SELECT count(*) FROM attachments) AS attachments;
DO $verify$
BEGIN
    IF (SELECT max(version) FROM organiser_schema) >= 2 THEN
        IF to_regclass('public.item_changes') IS NULL THEN
            RAISE EXCEPTION 'Missing change feed in restored database';
        END IF;
        IF EXISTS (
            SELECT 1 FROM items i LEFT JOIN item_changes c ON c.item_id = i.id
            WHERE c.item_id IS NULL OR c.revision <> i.revision
        ) THEN
            RAISE EXCEPTION 'Restored change feed does not match item revisions';
        END IF;
    END IF;
END $verify$;
SQL
echo 'Backup restored successfully into an isolated temporary database.'
