#!/bin/bash
# Generate a long-lived self-signed code-signing certificate for local builds.
# Usage: Scripts/gen-cert.sh <output-dir>
set -euo pipefail
OUT="${1:?usage: gen-cert.sh <dir>}"
NAME="OpenVoice Self-Signed"
mkdir -p "$OUT"
cd "$OUT"
if [[ -e openvoice.p12 ]]; then
    echo "openvoice.p12 已存在，拒绝覆盖" >&2
    exit 1
fi
PASS=$(openssl rand -hex 16)
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" \
  -keyout key.pem -out cert.pem 2>/dev/null
# macOS security import does not accept OpenSSL 3's default PKCS#12 encryption.
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "$NAME" \
  -passout "pass:$PASS" -out openvoice.p12
rm key.pem
printf '%s' "$PASS" > openvoice.p12.password
chmod 600 openvoice.p12 openvoice.p12.password
echo "已生成 $OUT/openvoice.p12（密码在 openvoice.p12.password），请备份。"
