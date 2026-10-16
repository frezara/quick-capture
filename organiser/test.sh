#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# A separate Compose project owns the disposable test database.
docker compose -p quick-capture-organiser-test -f compose.test.yml up -d --wait postgres
docker compose -p quick-capture-organiser-test -f compose.test.yml run --build --rm tests
