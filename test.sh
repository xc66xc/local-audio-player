#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/checks
swiftc -parse-as-library -o .build/checks/PlayerChecks \
  Sources/LocalAudioPlayer/PlaylistItem.swift \
  Sources/LocalAudioPlayer/AudioPlayerController.swift \
  Sources/LocalAudioPlayer/WindowKeyboardHandler.swift \
  Tests/LocalAudioPlayerTests/PlayerTests.swift \
  Tests/LocalAudioPlayerTests/CheckRunner.swift
.build/checks/PlayerChecks
