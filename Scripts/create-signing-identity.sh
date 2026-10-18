#!/bin/sh
# Creates "Apple Mail MCP Local Signing", a self-signed code-signing certificate in the login keychain.
# build-app.sh signs with it when present, so macOS keeps the Full Disk Access and Automation grants across
# rebuilds (an ad-hoc signature changes with every build and loses the grant).
# Remove it later with Keychain Access, or:
#   security delete-identity -c "Apple Mail MCP Local Signing" ~/Library/Keychains/login.keychain-db
set -eu
NAME="Apple Mail MCP Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists."
    exit 0
fi
# macOS's own LibreSSL, not whichever openssl is first on the PATH: OpenSSL 3 (Homebrew's) writes
# PKCS#12 files with AES and a SHA-256 MAC, which `security import` rejects as a wrong password.
OPENSSL=/usr/bin/openssl
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/id.p12" -passout "pass:$PASS"
# -T lets codesign use the key without a keychain prompt.
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". It shows as not trusted, which is expected and doesn't stop signing."
