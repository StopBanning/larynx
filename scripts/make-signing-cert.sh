#!/bin/zsh
# One time: creates a free self-signed code-signing certificate "Larynx Local Signing" in your login keychain,
# so rebuilds keep the same signature and macOS keeps Larynx's permissions.
set -euo pipefail
NAME="Larynx Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "Already set up: $NAME"; exit 0; fi
TMP=$(mktemp -d)
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout pass:larynx -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout pass:larynx
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P larynx -T /usr/bin/codesign
rm -rf "$TMP"
echo "Created $NAME. Rebuild with ./scripts/make-app.sh, then allow Larynx one last time."
