#!/usr/bin/env bash
set -euo pipefail
umask 077

signing_name="Ghostty Sidebar Local"
signing_keychain="$HOME/Library/Keychains/login.keychain-db"

signing_identities=$(/usr/bin/security find-identity -v -p codesigning "$signing_keychain")
if [[ "$signing_identities" == *"\"$signing_name\""* ]]; then
    printf 'Signing identity already available: %s\n' "$signing_name"
    exit 0
fi

signing_tmp=$(mktemp -d -t ghostty-agents-signing)
trap 'rm -rf "$signing_tmp"' EXIT

if ! /usr/bin/security find-certificate -c "$signing_name" -p "$signing_keychain" \
    > "$signing_tmp/certificate.pem" 2>/dev/null; then
    cat > "$signing_tmp/openssl.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = subject
x509_extensions = codesign
[subject]
CN = Ghostty Sidebar Local
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    /usr/bin/openssl req -new -newkey rsa:3072 -x509 -sha256 -days 3650 -nodes \
        -config "$signing_tmp/openssl.cnf" \
        -keyout "$signing_tmp/private-key.pem" -out "$signing_tmp/certificate.pem"
    signing_passphrase=$(/usr/bin/openssl rand -hex 24)
    /usr/bin/openssl pkcs12 -export -name "$signing_name" -passout fd:3 \
        -inkey "$signing_tmp/private-key.pem" -in "$signing_tmp/certificate.pem" \
        -out "$signing_tmp/identity.p12" 3<<< "$signing_passphrase"
    /usr/bin/security import "$signing_tmp/identity.p12" -k "$signing_keychain" \
        -P "$signing_passphrase" -x -T /usr/bin/codesign
    unset signing_passphrase
fi

/usr/bin/security add-trusted-cert -r trustRoot -p codeSign \
    -k "$signing_keychain" "$signing_tmp/certificate.pem"
signing_identities=$(/usr/bin/security find-identity -v -p codesigning "$signing_keychain")
if [[ "$signing_identities" != *"\"$signing_name\""* ]]; then
    printf 'Certificate exists, but its signing identity is unavailable: %s\n' "$signing_name" >&2
    exit 1
fi
printf 'Signing identity available: %s\n' "$signing_name"
