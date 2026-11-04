# AGENTS.md

## Local build signing

- For local development builds intended for installation on this Mac, sign with an available local Apple Development certificate instead of falling back to an ad-hoc signature. This keeps macOS Accessibility authorization stable across app upgrades.
- Select the identity dynamically; do not store personal certificate details in repository files:

  ```bash
  identity=$(security find-identity -v -p codesigning |
    awk -F '"' '/Apple Development:/ { print $2; exit }')
  [[ -n "$identity" ]] || { echo 'No local Apple Development certificate found' >&2; exit 1; }
  SIGN_IDENTITY="$identity" ./build.sh
  ```

- Verify the installed bundle is not ad-hoc before replacing `/Applications/OpenVoice.app`:

  ```bash
  codesign -dv --verbose=4 /Applications/OpenVoice.app 2>&1 | grep -E 'Authority=|TeamIdentifier=|Signature='
  ```
