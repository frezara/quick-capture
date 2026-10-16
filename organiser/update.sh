#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit or stash repository changes before updating.' >&2
  exit 1
fi
bash backup.sh
git pull --ff-only
bash setup.sh
