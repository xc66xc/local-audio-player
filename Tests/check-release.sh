#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/version.sh
for valid in 0.1.0 1.0.0 2.12.34; do
  is_release_version "$valid" || { printf '有效版本被拒绝：%s\n' "$valid" >&2; exit 1; }
done
for invalid in 01.0.0 1.01.0 1.0 1.0.0-beta.1 v1.0.0 '1.0.0;echo'; do
  if is_release_version "$invalid"; then
    printf '无效版本被接受：%s\n' "$invalid" >&2
    exit 1
  fi
done
release_version_greater_than 1.0.1 1.0.0
release_version_greater_than 1.10.0 1.9.9
release_version_greater_than 2.0.0 1.99.99
if release_version_greater_than 1.0.0 1.0.0 || release_version_greater_than 1.9.0 1.10.0; then
  printf '版本递增判断失败。\n' >&2
  exit 1
fi
[[ -s "releases/v${APP_VERSION}.md" ]] || { printf '缺少发布说明。\n' >&2; exit 1; }
RELEASE_ARCH="$(lipo -archs 'dist/本地音频播放器.app/Contents/MacOS/LocalAudioPlayer')"
ARCHIVE_NAME="LocalAudioPlayer-v${APP_VERSION}-macOS-${RELEASE_ARCH}.zip"
(cd dist && shasum -a 256 -c "$ARCHIVE_NAME.sha256")
EXTRACTED_DIR="$(mktemp -d "${TMPDIR:-/tmp/}MiniAudioRelease.XXXXXX")"
trap 'rm -rf "$EXTRACTED_DIR"' EXIT
ditto -x -k "dist/$ARCHIVE_NAME" "$EXTRACTED_DIR"
EXTRACTED_APP="$EXTRACTED_DIR/本地音频播放器.app"
[[ -x "$EXTRACTED_APP/Contents/MacOS/LocalAudioPlayer" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$EXTRACTED_APP/Contents/Info.plist")" == "$APP_VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$EXTRACTED_APP/Contents/Info.plist")" == "$APP_VERSION" ]]
codesign --verify --deep --strict "$EXTRACTED_APP"
printf 'PASS 版本规则、发布说明、压缩包结构、可执行权限、版本一致性与签名校验\n'
