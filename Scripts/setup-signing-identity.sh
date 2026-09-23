#!/usr/bin/env bash
# Creates a persistent, self-signed "Code Signing" identity in the login
# keychain (idempotent). Without this, every `swift build` produces a
# differently-signed (ad-hoc) binary, and macOS revokes the Accessibility
# permission grant on every rebuild. Signing every build with the SAME
# identity keeps the grant across rebuilds.
set -euo pipefail

IDENTITY_NAME="${1:-TaskbarReplacement Local Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "Identité de signature déjà présente : $IDENTITY_NAME"
    exit 0
fi

CONFIG="$WORKDIR/codesign.cnf"
cat > "$CONFIG" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no
[req_distinguished_name]
CN = $IDENTITY_NAME
[codesign_reqext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORKDIR/key.pem" \
    -out "$WORKDIR/cert.pem" \
    -days 3650 -nodes \
    -config "$CONFIG" \
    -extensions codesign_reqext

openssl pkcs12 -export \
    -out "$WORKDIR/cert.p12" \
    -inkey "$WORKDIR/key.pem" \
    -in "$WORKDIR/cert.pem" \
    -passout pass:temporary

security import "$WORKDIR/cert.p12" -k "$KEYCHAIN" -P temporary -T /usr/bin/codesign -T /usr/bin/security

# Trusting it in the (user-scoped) login keychain doesn't require sudo.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORKDIR/cert.pem"

echo "Identité de signature créée : $IDENTITY_NAME"
echo "Utilisez-la avec: Scripts/build-app.sh --identity \"$IDENTITY_NAME\""
