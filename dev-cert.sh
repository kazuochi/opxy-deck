#!/bin/bash
# dev-cert.sh — create a stable self-signed code-signing identity ("opxy-deck-dev").
#
# Why: ad-hoc signing (codesign -s -) gives the app a NEW code identity on every
# rebuild, and macOS keys the Accessibility grant to that identity — so every
# `make gui` silently kills the grant while System Settings still shows it ticked.
# With a stable certificate the identity survives rebuilds and the grant sticks.
#
# Run once: make dev-cert
# EXPECT DIALOGS: macOS will ask for your login password to (a) change certificate
# trust settings and (b) let codesign use the new key ("Always Allow" is the right
# answer — it's your own key, created by this script, private key never leaves your
# login keychain). After this, one final: make gui → make ax-reset → Grant…, then
# the grant is permanent.
set -euo pipefail
NAME="opxy-deck-dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "identity '$NAME' already exists — nothing to do"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/ext.cnf" 2>/dev/null

# Import key + cert as PEM directly, pre-authorizing codesign to use the key.
# Deliberately NOT via PKCS12: OpenSSL 3.x p12 files use encryption macOS's
# `security import` cannot verify ("MAC verification failed") — PEM sidesteps
# the whole format negotiation and works with any openssl.
security import "$TMP/key.pem" -k "$HOME/Library/Keychains/login.keychain-db" \
  -T /usr/bin/codesign
security import "$TMP/cert.pem" -k "$HOME/Library/Keychains/login.keychain-db"

# Trust the cert for code signing (user trust domain → password dialog appears).
security add-trusted-cert -p codeSign "$TMP/cert.pem" || {
  echo ""
  echo "trust step failed or was cancelled. Manual fallback (once):"
  echo "  Keychain Access → login → Certificates → '$NAME' → open →"
  echo "  Trust → Code Signing: Always Trust → close (asks for password)"
}

echo ""
if security find-identity -v -p codesigning | grep "$NAME"; then
  echo "✓ identity ready. Finish with: make gui && make ax-reset, then Grant… once."
  echo "  (first sign may pop a keychain dialog — choose Always Allow)"
else
  echo "identity not yet valid — complete the trust step above, then re-run make dev-cert"
  exit 1
fi
