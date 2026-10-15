#!/usr/bin/env bash
# Deploy committed feature-branch code through SSH without server GitHub credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
host="${1:-remote}"
destination="${2:-/home/fahad/apps/organiser}"
if [[ ! "$host" =~ ^[a-zA-Z0-9_.@-]+$ || ! "$destination" =~ ^/[a-zA-Z0-9_./-]+$ || "$destination" == *..* || "$destination" == / ]]; then
  echo 'Use an SSH alias and an absolute deployment path without spaces.' >&2
  exit 1
fi
branch="$(git branch --show-current)"
if [[ "$branch" != feat/home-organiser ]]; then
  echo 'Deploy from feat/home-organiser.' >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit repository changes before deploying.' >&2
  exit 1
fi
bundle="$(mktemp /tmp/organiser-deploy.XXXXXX)"
trap 'rm -f "$bundle"' EXIT
# mktemp reserves a private path; git bundle writes its contents atomically.
git bundle create "$bundle" "refs/heads/$branch"
parent="${destination%/*}"
remote_bundle="$parent/.organiser-deploy.bundle"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "mkdir -p '$parent'"
scp -q "$bundle" "$host:$remote_bundle"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" bash -s -- "$destination" "$remote_bundle" "$branch" <<'REMOTE'
set -euo pipefail
destination="$1"
bundle="$2"
branch="$3"
if [[ ! -e "$destination" ]]; then
  git clone --branch "$branch" "$bundle" "$destination"
else
  cd "$destination"
  [[ "$(git branch --show-current)" == "$branch" ]]
  [[ -z "$(git status --porcelain)" ]]
  bash organiser/backup.sh
  git fetch "$bundle" "refs/heads/$branch"
  git merge --ff-only FETCH_HEAD
fi
cd "$destination"
bash organiser/setup.sh
git rev-parse HEAD
REMOTE
