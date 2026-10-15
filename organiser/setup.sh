#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
umask 077
mkdir -p secrets backups
if [[ ! -f .env ]]; then
  printf 'POSTGRES_PASSWORD=%s\nORGANISER_PORT=8787\n' "$(openssl rand -hex 32)" > .env
fi
if [[ ! -f secrets/organiser_token ]]; then
  openssl rand -hex 32 > secrets/organiser_token
fi
# Docker secrets must be readable by the unprivileged app user. The parent
# directory remains private to the deploying user on the host.
chmod 700 secrets backups
chmod 600 .env
chmod 644 secrets/organiser_token
docker compose up -d --build --wait
