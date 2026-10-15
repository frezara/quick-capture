#!/usr/bin/env bash
# Install a per-user, loopback-only SSH tunnel that reconnects after network loss.
set -euo pipefail
host="${1:-remote}"
port="${2:-8788}"
if [[ ! "$host" =~ ^[a-zA-Z0-9_.@-]+$ || ! "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
  echo 'Usage: install-organiser-tunnel.sh [ssh-host-alias] [local-port 1024–65535]' >&2
  exit 1
fi
label='com.quickcapture.organiser-tunnel'
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/QuickCapture/organiser-tunnel.log"
mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
# Verify key-based access and the remote listener before replacing an existing service.
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'curl --fail --silent --max-time 5 http://127.0.0.1:8787/health >/dev/null'
python3 - "$plist" "$log" "$host" "$port" <<'PY'
import os, plistlib, sys
path, log, host, port = sys.argv[1:]
config = {
    'Label': 'com.quickcapture.organiser-tunnel',
    'ProgramArguments': ['/usr/bin/ssh', '-N', '-T', '-o', 'BatchMode=yes',
        '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
        '-L', f'127.0.0.1:{port}:127.0.0.1:8787', host],
    'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
    'StandardOutPath': log, 'StandardErrorPath': log,
    'ProcessType': 'Background',
}
with open(path + '.tmp', 'wb') as stream:
    plistlib.dump(config, stream)
    stream.flush()
    os.fsync(stream.fileno())
os.chmod(path + '.tmp', 0o600)
os.replace(path + '.tmp', path)
PY
plutil -lint "$plist"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
launchctl kickstart "gui/$(id -u)/$label"
for attempt in {1..20}; do
  if curl --fail --silent --max-time 2 "http://127.0.0.1:$port/health" >/dev/null; then
    echo "Organiser tunnel installed: http://127.0.0.1:$port (restarts at login and after disconnects)."
    exit 0
  fi
  sleep 1
done
echo "Tunnel did not become healthy. Inspect $log and check whether the local port is already in use." >&2
exit 1
