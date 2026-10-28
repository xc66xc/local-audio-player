#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != '--package' ) ]]; then
  printf '用法：bash build-app.sh [--package]\n' >&2
  exit 1
fi
APP_VERSION="$(cat VERSION)"
if ! [[ "$APP_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'VERSION 必须是无前导零的 X.Y.Z 版本号。\n' >&2
  exit 1
fi
bash build-decoder.sh
swift build -c release
APP_DIR="$PWD/dist/本地音频播放器.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Helpers"
cp .build/decoder/bin/ffmpeg .build/decoder/bin/ffprobe "$APP_DIR/Contents/Helpers/"
cp .build/decoder/FFmpeg-LICENSE.txt "$APP_DIR/Contents/Resources/"
codesign --force --sign - "$APP_DIR/Contents/Helpers/ffmpeg"
codesign --force --sign - "$APP_DIR/Contents/Helpers/ffprobe"
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
for ICON_SIZE in 16 32 128 256 512; do
  sips -z "$ICON_SIZE" "$ICON_SIZE" assets/app-icon.png --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
  ICON_RETINA=$((ICON_SIZE * 2))
  sips -z "$ICON_RETINA" "$ICON_RETINA" assets/app-icon.png --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
cp .build/release/LocalAudioPlayer "$APP_DIR/Contents/MacOS/LocalAudioPlayer"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE"
cp assets/player-wave.png "$APP_DIR/Contents/Resources/player-wave.png"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalAudioPlayer</string>
<key>CFBundleIdentifier</key><string>local.miniaudio.player</string>
<key>CFBundleName</key><string>本地音频播放器</string>
<key>CFBundleDisplayName</key><string>本地音频播放器</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$APP_VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf '已构建：%s\n' "$APP_DIR"

if [[ "${1:-}" == '--package' ]]; then
  RELEASE_ARCH="$(lipo -archs "$APP_DIR/Contents/MacOS/LocalAudioPlayer")"
  case "$RELEASE_ARCH" in
    arm64|x86_64) ;;
    *) printf '暂不支持打包架构：%s\n' "$RELEASE_ARCH" >&2; exit 1 ;;
  esac
  ARCHIVE_NAME="LocalAudioPlayer-v${APP_VERSION}-macOS-${RELEASE_ARCH}.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$PWD/dist/$ARCHIVE_NAME"
  (cd dist && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256" && shasum -a 256 -c "$ARCHIVE_NAME.sha256")
  EXTRACTED_DIR="$(mktemp -d "${TMPDIR:-/tmp/}MiniAudioRelease.XXXXXX")"
  trap 'rm -rf "$EXTRACTED_DIR"' EXIT
  ditto -x -k "dist/$ARCHIVE_NAME" "$EXTRACTED_DIR"
  EXTRACTED_APP="$EXTRACTED_DIR/本地音频播放器.app"
  test -x "$EXTRACTED_APP/Contents/MacOS/LocalAudioPlayer"
  test -s "$EXTRACTED_APP/Contents/Resources/LICENSE"
  test -s "$EXTRACTED_APP/Contents/Resources/player-wave.png"
  test -s "$EXTRACTED_APP/Contents/Resources/AppIcon.icns"
  test -s "$EXTRACTED_APP/Contents/Resources/FFmpeg-LICENSE.txt"
  test -x "$EXTRACTED_APP/Contents/Helpers/ffmpeg"
  test -x "$EXTRACTED_APP/Contents/Helpers/ffprobe"
  "$EXTRACTED_APP/Contents/Helpers/ffmpeg" -version >/dev/null
  "$EXTRACTED_APP/Contents/Helpers/ffprobe" -version >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$EXTRACTED_APP/Contents/Info.plist")" == "$APP_VERSION" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$EXTRACTED_APP/Contents/Info.plist")" == "$APP_VERSION" ]]
  codesign --verify --deep --strict "$EXTRACTED_APP"
  printf '已打包并验证：dist/%s\n' "$ARCHIVE_NAME"
fi
