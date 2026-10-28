#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
command -v ffmpeg >/dev/null || { echo '测试样本生成需要 ffmpeg（brew install ffmpeg）。应用运行不需要安装它。' >&2; exit 1; }
mkdir -p .build/checks
bash build-decoder.sh
swiftc -parse-as-library -o .build/checks/PlayerChecks \
  Sources/LocalAudioPlayer/AudioPlayback.swift \
  Sources/LocalAudioPlayer/PlaylistItem.swift \
  Sources/LocalAudioPlayer/AudioPlayerController.swift \
  Sources/LocalAudioPlayer/WindowKeyboardHandler.swift \
  Tests/LocalAudioPlayerTests/PlayerTests.swift \
  Tests/LocalAudioPlayerTests/CheckRunner.swift
.build/checks/PlayerChecks
