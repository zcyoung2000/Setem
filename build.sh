#!/bin/bash
# 构建 OpenVoice.app（用固定证书签名，重建后辅助功能/麦克风授权不丢）
set -euo pipefail
cd "$(dirname "$0")"

./Scripts/opus.sh

# SwiftPM records the package's minimum platform as the Mach-O SDK version.
# Explicitly record the selected SDK so macOS 26+ applies its current controls/materials.
MACOS_MIN=15.0
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
PLATFORM_LINK_FLAGS=(
    -Xlinker -platform_version -Xlinker macos
    -Xlinker "$MACOS_MIN" -Xlinker "$SDK_VERSION"
)
# GitHub's Xcode 26 linker rejects -platform_version when SwiftPM invokes it.
# SwiftPM still links against the selected SDK without these local-only flags.
[[ -z "${CI:-}" ]] || PLATFORM_LINK_FLAGS=()

# 通用包：Apple 芯片与 Intel 共用一个 App
xcrun swift build -c release --arch arm64 --arch x86_64 "${PLATFORM_LINK_FLAGS[@]}"
BIN="$(xcrun swift build -c release --arch arm64 --arch x86_64 "${PLATFORM_LINK_FLAGS[@]}" --show-bin-path)/OpenVoice"

# 图标由 Scripts/icon.swift 生成，脚本未改动则复用
ICNS=build/AppIcon.icns
if [ ! -f "$ICNS" ] || [ docs/icon.png -nt "$ICNS" ] || [ Scripts/icon.swift -nt "$ICNS" ]; then
    SET=build/AppIcon.iconset
    rm -rf "$SET" && mkdir -p "$SET"
    xcrun swift Scripts/icon.swift build/icon_1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon_1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o "$ICNS"
    rm -rf "$SET" build/icon_1024.png
fi

APP=build/OpenVoice.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp "$ICNS" "$APP/Contents/Resources/"
VERSION="${VERSION:-0.1}"
BUILD="${BUILD:-1}"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>do.j3.openvoice</string>
    <key>CFBundleName</key><string>OpenVoice</string>
    <key>CFBundleExecutable</key><string>OpenVoice</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>长按快捷键时录音并发送到所选渠道识别。</string>
</dict>
</plist>
EOF
SIGN_LOG=$(mktemp)
if IDENTITY=$(./Scripts/ensure-signing-cert.sh 2>"$SIGN_LOG"); then
    if ! codesign --force --sign "$IDENTITY" "$APP" 2>>"$SIGN_LOG"; then
        cat "$SIGN_LOG" >&2
        echo "固定证书签名失败，回退 ad-hoc 签名" >&2
        codesign --force --sign - "$APP"
        IDENTITY=""
    fi
else
    cat "$SIGN_LOG" >&2
    echo "固定证书不可用，回退 ad-hoc 签名" >&2
    codesign --force --sign - "$APP"
    IDENTITY=""
fi
rm -f "$SIGN_LOG"
echo "built $APP (signed: ${IDENTITY:-adhoc})"
