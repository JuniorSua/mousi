#!/bin/zsh
# Creates a local self-signed "Mousi Dev" code-signing identity in a dedicated keychain.
# Run once; build.sh then signs with it so the Accessibility permission survives rebuilds.
set -euo pipefail
KC=~/Library/Keychains/mousi-dev.keychain-db
# Throwaway password for a local, self-signed dev cert. Saved outside the repo so build.sh can
# unlock the keychain unattended instead of popping a password dialog mid-build.
PWFILE="$HOME/Library/Application Support/Mousi/signing-keychain.pw"
mkdir -p "$(dirname "$PWFILE")"
PW=$(openssl rand -hex 16)
printf '%s' "$PW" > "$PWFILE"
chmod 600 "$PWFILE"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/ext.cnf" <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Mousi Dev
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -config "$D/ext.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout pass:tmp -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout pass:tmp
security import "$D/id.p12" -k "$KC" -P tmp -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$D/cert.pem"
security list-keychains -d user -s $(security list-keychains -d user | tr -d '" ' | tr '\n' ' ') "$KC"
echo "✓ 'Mousi Dev' identity ready in $KC (password saved to $PWFILE)"
