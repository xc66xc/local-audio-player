#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source scripts/version.sh
swift build -c release
APP_DIR="$PWD/dist/本地音频播放器.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp .build/release/LocalAudioPlayer "$APP_DIR/Contents/MacOS/LocalAudioPlayer"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalAudioPlayer</string>
<key>CFBundleIdentifier</key><string>local.miniaudio.player</string>
<key>CFBundleName</key><string>本地音频播放器</string>
<key>CFBundleDisplayName</key><string>本地音频播放器</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$APP_VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf '已构建：%s\n' "$APP_DIR"
