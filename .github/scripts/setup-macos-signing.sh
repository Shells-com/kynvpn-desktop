#!/bin/bash
# Sets up macOS signing and notarization for the GitHub Actions build.
#
# - Creates the 'macos-signing' environment, usable only from master and v*
#   tags
# - Exports the Developer ID Application certificate and its private key from
#   the login keychain (macOS asks to allow the export)
# - Checks the Apple ID credentials against the notary service
# - Stores everything as secrets of that environment
#
# Usage: .github/scripts/setup-macos-signing.sh <team ID> [<repo>]
#   e.g. .github/scripts/setup-macos-signing.sh BTXR2WSDG9
#
# Needs: gh (logged in, admin on the repo), Xcode command line tools, OpenSSL 3+
# (Homebrew).  Rerun it when the certificate or app-specific password change.

set -euo pipefail

TEAM_ID="${1:?usage: $0 <team ID> [<owner/repo>]}"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
ENV_NAME=macos-signing
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

OPENSSL=
for c in /opt/homebrew/bin/openssl /usr/local/bin/openssl openssl; do
    if "$c" version 2>/dev/null | grep '^OpenSSL [3-9]' >/dev/null; then OPENSSL="$c"; break; fi
done
[ -n "$OPENSSL" ] || { echo "OpenSSL 3+ is required (brew install openssl)" >&2; exit 1; }

# Find the certificate
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" |
    sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\"$/\1/p" | head -n1)"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate for team $TEAM_ID in the login keychain" >&2; exit 1; }
echo "Repository:  $REPO"
echo "Certificate: $IDENTITY"
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

# Apple ID credentials, checked before changing anything
# (APPLE_ID / APPLE_APP_PASSWORD can also be given in the environment)
APPLE_ID="${APPLE_ID:-}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-}"
[ -n "$APPLE_ID" ] || read -rp "Apple ID email (member of team $TEAM_ID): " APPLE_ID
if [ -z "$APPLE_APP_PASSWORD" ]; then
    echo "Create an app-specific password for it at https://account.apple.com"
    echo "(Sign-In and Security > App-Specific Passwords), then paste it here."
    read -rsp "App-specific password: " APPLE_APP_PASSWORD
    echo
fi
echo "Checking the credentials with the notary service..."
if ! xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" >/dev/null 2>"$TMP/notary.err"; then
    cat "$TMP/notary.err" >&2
    echo "The notary service rejected these credentials." >&2
    exit 1
fi
echo "OK"
echo

# Export only the chosen identity.  'security export' can only export every
# identity of the keychain (one prompt per private key), so use the Security
# framework directly to export just this one.
echo "Exporting the certificate..."
cat > "$TMP/export.swift" <<'EOF'
import CryptoKit
import Foundation
import Security

// export <keychain> <certificate SHA-1> <output .p12> (passphrase on stdin)
let args = CommandLine.arguments
let wanted = args[2].uppercased()
let passphrase = readLine() ?? ""
func fail(_ what: String, _ status: OSStatus) -> Never {
    let msg = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
    FileHandle.standardError.write("\(what): \(msg)\n".data(using: .utf8)!)
    exit(1)
}
var keychain: SecKeychain?
var status = SecKeychainOpen(args[1], &keychain)
if status != errSecSuccess { fail("Can't open the keychain", status) }
var result: CFTypeRef?
status = SecItemCopyMatching([
    kSecClass: kSecClassIdentity,
    kSecMatchSearchList: [keychain!],
    kSecMatchLimit: kSecMatchLimitAll,
    kSecReturnRef: true,
] as CFDictionary, &result)
if status != errSecSuccess { fail("Can't list the identities", status) }
for identity in result as! [SecIdentity] {
    var cert: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess else { continue }
    let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(cert!) as Data)
    guard hash.map({ String(format: "%02X", $0) }).joined() == wanted else { continue }
    var params = SecItemImportExportKeyParameters()
    params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    params.passphrase = Unmanaged.passUnretained(passphrase as CFString)
    params.alertTitle = Unmanaged.passUnretained("Export for GitHub Actions" as CFString)
    var data: CFData?
    status = SecItemExport(identity, .formatPKCS12, [], &params, &data)
    if status != errSecSuccess { fail("Export failed", status) }
    try! (data! as Data).write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}
FileHandle.standardError.write("Identity \(wanted) not found\n".data(using: .utf8)!)
exit(1)
EOF
swiftc -suppress-warnings -O -o "$TMP/export" "$TMP/export.swift"
CERT_SHA1="$(security find-identity -v -p codesigning "$KEYCHAIN" |
    awk -v id="\"$IDENTITY\"" 'substr($0, length($0) - length(id) + 1) == id { print $2; exit }')"
EXPORT_PASS="$("$OPENSSL" rand -hex 16)"
echo "(macOS asks for your login keychain password once: enter it and click Allow)"
printf '%s\n' "$EXPORT_PASS" | "$TMP/export" "$KEYCHAIN" "$CERT_SHA1" "$TMP/export.p12"
for legacy in "" -legacy; do
    if "$OPENSSL" pkcs12 $legacy -in "$TMP/export.p12" -passin "pass:$EXPORT_PASS" \
            -nocerts -nodes -out "$TMP/key.pem" 2>/dev/null; then break; fi
done
[ -s "$TMP/key.pem" ] || { echo "Can't read the exported .p12" >&2; exit 1; }
KEY="$TMP/key.pem"
security find-certificate -Z -a -c "$IDENTITY" -p "$KEYCHAIN" |
    awk -v h="$CERT_SHA1" '/^SHA-1 hash:/ { on = ($3 == h) } on && /BEGIN CERTIFICATE/,on && /END CERTIFICATE/' |
    "$OPENSSL" x509 -out "$TMP/cert.pem"
[ "$("$OPENSSL" pkey -in "$KEY" -pubout)" = "$("$OPENSSL" x509 -in "$TMP/cert.pem" -pubkey -noout)" ] ||
    { echo "The exported key doesn't match the certificate" >&2; exit 1; }

# Include the issuing Developer ID CA if the keychain has it
ISSUER="$("$OPENSSL" x509 -in "$TMP/cert.pem" -noout -issuer -nameopt RFC2253)"
: > "$TMP/chain.pem"
security find-certificate -a -c "Developer ID Certification Authority" -p |
    awk -v dir="$TMP" '/BEGIN CERTIFICATE/ { n++ } n { print > (dir "/ca" n ".pem") }'
for ca in "$TMP"/ca*.pem; do
    [ -f "$ca" ] || continue
    if [ "subject=${ISSUER#issuer=}" = "$("$OPENSSL" x509 -in "$ca" -noout -subject -nameopt RFC2253)" ]; then
        cat "$ca" >> "$TMP/chain.pem"; break
    fi
done

# 3DES/SHA-1 so any 'security import' can read it
P12_PASS="$("$OPENSSL" rand -hex 24)"
CHAIN_ARGS=()
[ -s "$TMP/chain.pem" ] && CHAIN_ARGS=(-certfile "$TMP/chain.pem")
"$OPENSSL" pkcs12 -export -inkey "$KEY" -in "$TMP/cert.pem" ${CHAIN_ARGS[@]+"${CHAIN_ARGS[@]}"} \
    -name "$IDENTITY" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$P12_PASS" -out "$TMP/ci.p12"

# Check it imports and signs in a throwaway keychain
TEST_KC="$TMP/test.keychain-db"
security create-keychain -p test "$TEST_KC"
security unlock-keychain -p test "$TEST_KC"
security import "$TMP/ci.p12" -k "$TEST_KC" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
security find-identity -p codesigning "$TEST_KC" | grep -F "$IDENTITY" >/dev/null ||
    { echo "The exported .p12 doesn't contain a usable identity" >&2; security delete-keychain "$TEST_KC"; exit 1; }
security delete-keychain "$TEST_KC"
echo "OK"
echo

# Environment limited to master and v* tags
echo "Creating the '$ENV_NAME' environment..."
gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input - >/dev/null <<'EOF'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
existing="$(gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
    -q '.branch_policies[] | "\(.type):\(.name)"')"
for policy in branch:master tag:v*; do
    if ! grep -qxF "$policy" <<<"$existing"; then
        gh api -X POST "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
            -f "type=${policy%%:*}" -f "name=${policy#*:}" >/dev/null
    fi
done

echo "Storing the secrets..."
set_secret() { gh secret set "$1" -R "$REPO" --env "$ENV_NAME"; }
base64 -i "$TMP/ci.p12" | tr -d '\n' | set_secret MACOS_CERT_P12
printf '%s' "$P12_PASS" | set_secret MACOS_CERT_PASSWORD
printf '%s' "$IDENTITY" | set_secret MACOS_CODESIGN_IDENTITY
printf '%s' "$APPLE_ID" | set_secret APPLE_ID
printf '%s' "$APPLE_APP_PASSWORD" | set_secret APPLE_APP_PASSWORD
printf '%s' "$TEAM_ID" | set_secret APPLE_TEAM_ID
echo
echo "Done.  The next build of master or of a v* tag will be signed and notarized."
