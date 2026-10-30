#!/bin/sh
# Creates a local code-signing certificate, "Tether Local Signing", in your login keychain.
# Builds signed with it are the same app to macOS from one version to the next, so permissions
# (Documents, Downloads …) and the keychain's "Always Allow" are not asked for again after every
# update. It is self-signed, stays on this Mac and is used for nothing but signing Tether.
set -eu
NAME="Tether Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists."
    exit 0
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tether-signing.XXXXXX")
# The private key never stays on disk outside the keychain.
cleanup() { case "$WORK" in */tether-signing.*) rm -rf -- "$WORK";; esac; }
trap cleanup EXIT
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
openssl req -x509 -newkey rsa:3072 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 7300 -config "$WORK/cert.cnf" 2>/dev/null
PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$PASS" -legacy 2>/dev/null \
    || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$PASS"
security import "$WORK/id.p12" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". The next 'make app' / 'make install' signs with it; macOS asks for permissions once more, then keeps them."
