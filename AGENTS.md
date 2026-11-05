# AGENTS.md

## Dictation regression baseline

- Run `./Scripts/test.sh` after changing dictation hotkeys, recording lifecycle,
  completion/partial callbacks, timeouts, or text insertion. Releases run the same gate.
- Follow `docs/dictation-baseline.md`: continuing while finalizing must preserve pending
  finals; an old task must never stop a newer recording or change its text/UI/timeout.
- Follow `docs/dictation-parity.md` against its pinned upstream commit. Keep the
  meeting and hold-to-send extensions; do not silently change upstream transcript rules.
- Route single-channel completion through `DictationSession`, candidate selection
  through `DictationPicker`, and hardware ownership/pre-roll through `DictationCapture`.
  Do not put shared recorder/UI cleanup in an engine task's catch/defer.
- Lease engines exclusively through `DictationEnginePool`; await preparation before
  recognition and return only successful, uncancelled engines. Cancel and join old
  socket readers before reusing a connection.
- Candidate confirmation must wait for a final row. Keep partial speech activity,
  cancellation/timeouts, synthetic key filtering and empty-final semantics covered.
- For new missing-text bugs, add a controlled-timing regression with exact expected
  final text before changing the implementation.

## Settings UI regression baseline

- Follow docs/settings-ui-baseline.md. Keep native controls and disable decorative
  focus rings at the settings and comparison sheet roots with focusEffectDisabled().
- Do not remove keyboard focus, Tab/arrow navigation, shortcut recording, editable
  text focus, or accessibility to suppress a visual ring. Do not change global
  AppKit classes or the user's system keyboard navigation settings.
- Run ./Scripts/test.sh after changing settings, tabs, buttons, sheets, or focus
  behavior. SettingsWindowTests is part of the local, CI, and release gate.
- Verify focused native toolbar controls in a key window after page changes and
  reopening. Inactive/offscreen previews alone cannot detect this regression;
  inspect an active window capture when changing focus appearance.
- Align the visible trailing edges of controls within each settings group.
  Fixed-width control containers must use trailing alignment; verify the actual
  native controls in a release window, not only their layout frames.

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
