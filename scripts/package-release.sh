#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/version.sh
bash build-app.sh
APP_DIR="$PWD/dist/本地音频播放器.app"
codesign --verify --deep --strict "$APP_DIR"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$APP_VERSION" ]] || { printf '应用版本与 VERSION 不一致。\n' >&2; exit 1; }
RELEASE_ARCH="$(lipo -archs "$APP_DIR/Contents/MacOS/LocalAudioPlayer")"
case "$RELEASE_ARCH" in
  arm64|x86_64) ;;
  *) printf '暂不支持打包架构：%s\n' "$RELEASE_ARCH" >&2; exit 1 ;;
esac
ARCHIVE_NAME="LocalAudioPlayer-v${APP_VERSION}-macOS-${RELEASE_ARCH}.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$PWD/dist/$ARCHIVE_NAME"
cd dist
shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
printf '下载包：%s\n校验文件：%s.sha256\n' "$ARCHIVE_NAME" "$ARCHIVE_NAME"
