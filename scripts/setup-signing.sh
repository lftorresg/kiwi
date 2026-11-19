#!/bin/bash
# One-time setup: creates a local code signing identity named "Kiwi Local".
#
# macOS ties the Screen Recording grant to an app's code signature. An ad hoc
# signature is different on every build, so the grant is lost each time. With a
# stable identity the signature stays the same and the grant survives rebuilds.
#
# What this does:
#   1. Generates a self-signed certificate and private key, valid for code
#      signing only. The key never leaves this Mac.
#   2. Stores both in your login keychain. No app is pre-authorised to use the
#      key, so macOS asks before codesign may sign with it.
#   3. Trusts the certificate for code signing only, for your user only.
#      macOS asks for your password to confirm this step.
#
# Security trade-off: anything that can sign with this key can produce an app
# that macOS treats as Kiwi, Screen Recording grant included. When the build
# asks to use the key, "Allow" keeps that decision with you on every build;
# "Always Allow" is more convenient but lets codesign use the key unprompted.
#
# The Makefile picks the identity up automatically on the next build.
# To undo: delete "Kiwi Local" (certificate and key) in Keychain Access.
set -euo pipefail

CERT="Kiwi Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT\""; then
    echo "\"$CERT\" is already set up. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
chmod 700 "$WORK"

cat > "$WORK/cert.tmpl" <<EOF
[ req ]
default_bits       = 2048
encrypt_key        = no
default_md         = sha256
distinguished_name = codesign_dn
prompt             = no
[ codesign_dn ]
commonName         = $CERT
[ codesign_reqext ]
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

echo "Generating the certificate..."
/usr/bin/openssl req -new -newkey rsa:2048 -x509 -days 3650 -nodes \
    -config "$WORK/cert.tmpl" -extensions codesign_reqext -batch \
    -out "$WORK/cert.cer" -keyout "$WORK/cert.key" >/dev/null 2>&1

echo "Adding it to your login keychain..."
security import "$WORK/cert.key" -k "$KEYCHAIN" >/dev/null
security import "$WORK/cert.cer" -k "$KEYCHAIN" >/dev/null

echo "Trusting it for code signing (macOS will ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.cer"

if security find-identity -v -p codesigning | grep -q "\"$CERT\""; then
    echo
    echo "Done. \"$CERT\" is ready."
    echo "Next: run 'make run', then allow Kiwi under Screen & System Audio Recording"
    echo "one last time. Each build asks to let codesign use the key: choose Allow"
    echo "to keep approving builds yourself, or Always Allow to stop being asked."
else
    echo
    echo "The identity was created but macOS does not list it as valid for code signing."
    echo "Open Keychain Access, find \"$CERT\", and set Code Signing to Always Trust."
    exit 1
fi
