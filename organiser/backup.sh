#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
umask 077
mkdir -p backups
backup="backups/organiser-$(date -u +%Y%m%dT%H%M%SZ).dump"
docker compose exec -T postgres pg_dump -U organiser -d organiser -Fc > "$backup.partial"
mv "$backup.partial" "$backup"
printf 'Backup saved: %s\n' "$backup"
