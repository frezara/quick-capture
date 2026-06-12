#!/bin/bash
# One-time setup for local Debug builds.
#
# Creates a persistent self-signed code-signing identity "QuickCapture Dev" in
# your login keychain. Debug builds sign with it (see project.yml) so the macOS
# TCC grant for Desktop/Files access (used by the ⌥⌘S screenshot picker) SURVIVES
# rebuilds. Ad-hoc signing gives every build a fresh cdhash, which makes macOS
# treat each rebuild as a new app and re-prompt for access (#77).
#
# A real (non-ad-hoc) signature gives the app a stable *designated requirement*
#   identifier "com.quickcapture.app" and certificate leaf = H"<cert hash>"
# which is what TCC keys on — constant across rebuilds, so the grant sticks.
#
# Run once per machine:  bash scripts/make-signing-cert.sh
# Idempotent: re-running just reports the existing cert. No admin/sudo needed.
#
# GUI alternative: Keychain Access → Certificate Assistant → Create a Certificate
#   → Name "QuickCapture Dev", Identity Type "Self-Signed Root", Type "Code Signing".
set -euo pipefail

NAME="QuickCapture Dev"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Identity '$NAME' already exists — nothing to do."
  echo "codesign sees it as: $(codesign --sign "$NAME" --dryrun /usr/bin/true 2>&1 || true)"
  exit 0
fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

cat > "$DIR/c.cnf" <<'CONF'
[req]
distinguished_name = dn
x509_extensions     = ext
prompt              = no
[dn]
CN = QuickCapture Dev
[ext]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
CONF

echo "1/3 generating key + self-signed code-signing cert…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$DIR/k.pem" -out "$DIR/c.pem" -config "$DIR/c.cnf"

echo "2/3 packaging into .p12 (legacy SHA-1 MAC so 'security import' accepts it)…"
# OpenSSL 3 defaults to an AES-256 / SHA-256 MAC that macOS `security import`
# rejects ("MAC verification failed"). Force legacy SHA-1 PBE + MAC with a
# throwaway password. `-legacy` is OpenSSL-3 only; fall back without it.
P12PASS="qcdev-tmp-pass"
P12_COMMON=(-export -out "$DIR/id.p12" -inkey "$DIR/k.pem" -in "$DIR/c.pem"
            -name "$NAME" -passout "pass:$P12PASS"
            -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES)
if ! openssl pkcs12 "${P12_COMMON[@]}" -legacy 2>/dev/null; then
  openssl pkcs12 "${P12_COMMON[@]}"
fi

echo "3/3 importing into login keychain (codesign access, no per-build prompts)…"
security import "$DIR/id.p12" -k "$LOGIN_KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign -A

echo
echo "Done. Debug builds will now sign as '$NAME'."
echo "Verify after a build with:  codesign -dvv '<path to>/Quick Capture.app'"
echo "  → Authority=QuickCapture Dev, and a stable 'designated' requirement."
