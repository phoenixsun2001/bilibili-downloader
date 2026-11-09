#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/build/Bili 音频.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONSET="$(mktemp -d -t bili-icon).iconset"
trap 'rm -rf "$ICONSET"' EXIT
swift scripts/create-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/BiliDesktop" "$APP/Contents/MacOS/BiliDesktop"
cp -R Sources/BiliDesktop/Resources "$APP/Contents/Resources/DownloadScripts"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Bili 音频</string>
<key>CFBundleDisplayName</key><string>Bili 音频</string>
<key>CFBundleIdentifier</key><string>local.bili.audio</string>
<key>CFBundleExecutable</key><string>BiliDesktop</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '已生成：%s\n' "$APP"
