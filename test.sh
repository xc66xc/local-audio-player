#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
command -v ffmpeg >/dev/null || { echo '测试样本生成需要包含 libvorbis/libopus/libmp3lame 的 ffmpeg。可安装 brew install ffmpeg-full，并将其 bin 目录加入 PATH。应用运行无需安装它。' >&2; exit 1; }
ffmpeg -hide_banner -encoders 2>/dev/null | grep 'libvorbis' >/dev/null || { echo '当前 ffmpeg 缺少 libvorbis 编码器，请使用 ffmpeg-full 的 bin 目录运行测试。' >&2; exit 1; }
mkdir -p .build/checks
bash build-decoder.sh
swiftc -parse-as-library -o .build/checks/PlayerChecks \
  Sources/LocalAudioPlayer/AudioPlayback.swift \
  Sources/LocalAudioPlayer/PlaylistItem.swift \
  Sources/LocalAudioPlayer/SessionStore.swift \
  Sources/LocalAudioPlayer/AudioPlayerController.swift \
  Sources/LocalAudioPlayer/WindowKeyboardHandler.swift \
  Tests/LocalAudioPlayerTests/PlayerTests.swift \
  Tests/LocalAudioPlayerTests/CheckRunner.swift
.build/checks/PlayerChecks
