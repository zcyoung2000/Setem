#!/bin/bash
# Return a persistent local signing identity, creating/importing it when needed.
set -euo pipefail
NAME="VoiceKey Self-Signed"
STORE="$(cd "$(dirname "$0")/.." && pwd)/build/signing"
KEYCHAIN="$STORE/voicekey.keychain-db"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "$SIGN_IDENTITY"
    exit 0
fi

if [[ ! -f "$STORE/voicekey.p12" ]]; then
    "$(dirname "$0")/gen-cert.sh" "$STORE" >&2
fi

if [[ ! -f "$KEYCHAIN" ]]; then
    KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >&2
    security set-keychain-settings -lut 21600 "$KEYCHAIN" >&2
    printf '%s' "$KEYCHAIN_PASSWORD" >"$KEYCHAIN.password"
    chmod 600 "$KEYCHAIN.password"
else
    KEYCHAIN_PASSWORD="$(<"$KEYCHAIN.password")"
fi

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >&2
if ! security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    security import "$STORE/voicekey.p12" -P "$(<"$STORE/voicekey.p12.password")" \
        -k "$KEYCHAIN" -T /usr/bin/codesign >&2
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# codesign can use this self-signed leaf even though find-identity omits it.
SEARCH_LIST=$(security list-keychains -d user | tr -d '"' |
    awk -v keychain="$KEYCHAIN" '$0 != keychain && !seen[$0]++')
security list-keychains -d user -s "$KEYCHAIN" $SEARCH_LIST >&2
echo "$NAME"
