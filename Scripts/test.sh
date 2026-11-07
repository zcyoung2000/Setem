#!/bin/bash
# Dictation/capture and settings UI baseline, shared by local, PR and release checks.
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/opus.sh
if [[ $# -gt 0 ]]; then
    swift test "$@"
else
    swift test --filter 'Dictation.*Tests|QwenInboxTests|ConnectionLifetimeTests|SettingsWindowTests'
fi
