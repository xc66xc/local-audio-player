import AVFAudio
import AppKit

final class PlayerTests: CheckSuite {
    private func fixture(_ name: String = "01.m4a", seconds: Double = 12,
                         codec: AudioFormatID = kAudioFormatMPEG4AAC) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiniAudioTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let frames = AVAudioFrameCount(44100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
        var settings: [String: Any] = [
            AVFormatIDKey: codec, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1
        ]
        if codec == kAudioFormatMPEG4AAC { settings[AVEncoderBitRateKey] = 64000 }
        if codec == kAudioFormatAppleLossless { settings[AVEncoderBitDepthHintKey] = 16 }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }

    func testSeekBoundsAndTimeLabels() {
        expectEqual(PlaybackRules.position(-5, duration: 10), 0)
        expectEqual(PlaybackRules.position(15, duration: 10), 10)
        expectEqual(PlaybackRules.position(.nan, duration: 10), 0)
        expectEqual(PlaybackRules.timeLabel(65), "01:05")
        expectEqual(PlaybackRules.timeLabel(3661), "1:01:01")
    }

    @MainActor func testM4AAACLoadsAndPausedSeekMovesFiveSeconds() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture()])
        expectTrue(controller.load(controller.items[0].id, autoplay: false))
        expectGreaterThan(controller.duration, 11)
        controller.seek(by: 5)
        expectEqual(controller.position, 5, accuracy: 0.05)
        expectFalse(controller.isPlaying)
        controller.seek(by: -5)
        expectEqual(controller.position, 0, accuracy: 0.05)
        controller.seek(by: -5)
        expectEqual(controller.position, 0)
        controller.togglePlayback()
        expectTrue(controller.isPlaying)
        controller.togglePlayback()
        expectFalse(controller.isPlaying)
    }

    @MainActor func testM4AALACPlaysAndSeeks() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture(codec: kAudioFormatAppleLossless)])
        expectTrue(controller.load(controller.items[0].id, autoplay: true))
        expectTrue(controller.isPlaying)
        controller.seek(by: 5)
        expectEqual(controller.position, 5, accuracy: 0.15)
        controller.togglePlayback()
        expectFalse(controller.isPlaying)
    }

    @MainActor func testPlaylistSortDedupeAndRemoval() async throws {
        let a = try fixture("02.m4a")
        let b = try fixture("01.m4a")
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([a, b, a])
        expectEqual(controller.items.map(\.name), ["01.m4a", "02.m4a"])
        expectEqual(controller.selectedID, controller.items[0].id)
        expectNil(controller.currentID)
        controller.load(controller.items[0].id, autoplay: true)
        controller.selectedID = controller.items[1].id
        controller.removeSelected()
        expectEqual(controller.items.count, 1)
        expectTrue(controller.isPlaying)
        controller.removeSelected()
        expectTrue(controller.items.isEmpty)
        expectNil(controller.currentID)
        expectFalse(controller.isPlaying)
        expectTrue(FileManager.default.fileExists(atPath: b.path))
    }

    @MainActor func testSameNameDifferentPathsAreKept() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture(), try fixture()])
        expectEqual(controller.items.count, 2)
    }

    @MainActor func testBadFilePreservesCurrentPlayback() async throws {
        let good = try fixture()
        let bad = good.deletingLastPathComponent().appendingPathComponent("02-broken.m4a")
        try Data("broken".utf8).write(to: bad)
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([good, bad])
        let first = controller.items[0].id
        expectTrue(controller.load(first, autoplay: true))
        expectFalse(controller.load(controller.items[1].id, autoplay: true))
        expectEqual(controller.currentID, first)
        expectTrue(controller.isPlaying)
        expectNotNil(controller.errorMessage)
    }

    @MainActor func testNaturalEndWithoutAutoAdvance() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture("01.m4a", seconds: 0.25), try fixture("02.m4a")])
        let first = controller.items[0].id
        controller.load(first, autoplay: true)
        try await Task.sleep(nanoseconds: 900_000_000)
        expectFalse(controller.isPlaying)
        expectEqual(controller.currentID, first)
        expectEqual(controller.position, controller.duration)
        controller.togglePlayback()
        expectTrue(controller.isPlaying)
        expectLessThan(controller.position, controller.duration)
    }

    @MainActor func testNaturalEndAdvancesOnlyWhenChecked() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture("01.m4a", seconds: 0.25), try fixture("02.m4a")])
        controller.load(controller.items[0].id, autoplay: true)
        controller.autoAdvance = true
        try await Task.sleep(nanoseconds: 900_000_000)
        expectEqual(controller.currentID, controller.items[1].id)
        expectTrue(controller.isPlaying)
    }

    @MainActor func testUncheckDuringPlaybackStopsAtEnd() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture("01.m4a", seconds: 0.25), try fixture("02.m4a")])
        controller.autoAdvance = true
        let first = controller.items[0].id
        controller.load(first, autoplay: true)
        controller.autoAdvance = false
        try await Task.sleep(nanoseconds: 900_000_000)
        expectEqual(controller.currentID, first)
        expectFalse(controller.isPlaying)
    }

    @MainActor func testFinalTrackNeverLoops() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture(seconds: 0.25)])
        controller.autoAdvance = true
        controller.load(controller.items[0].id, autoplay: true)
        try await Task.sleep(nanoseconds: 900_000_000)
        expectFalse(controller.isPlaying)
        expectEqual(controller.position, controller.duration)
    }

    @MainActor func testManualEndDoesNotAdvanceAndCanSeekBack() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture("01.m4a"), try fixture("02.m4a")])
        controller.autoAdvance = true
        let first = controller.items[0].id
        controller.load(first, autoplay: true)
        let duration = controller.duration
        controller.seek(to: duration + 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        expectEqual(controller.currentID, first)
        expectFalse(controller.isPlaying)
        controller.seek(by: -5)
        expectEqual(controller.position, duration - 5, accuracy: 0.05)
        expectFalse(controller.isPlaying)
        controller.togglePlayback()
        expectTrue(controller.isPlaying)
        controller.seek(to: duration)
        controller.playItem(first)
        expectTrue(controller.isPlaying)
        expectEqual(controller.position, 0, accuracy: 0.05)
    }

    @MainActor func testNextMissingFileStopsWithVisibleError() async throws {
        let next = try fixture("02.m4a")
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture("01.m4a", seconds: 0.25), next])
        try FileManager.default.removeItem(at: next)
        controller.autoAdvance = true
        controller.load(controller.items[0].id, autoplay: true)
        try await Task.sleep(nanoseconds: 900_000_000)
        expectFalse(controller.isPlaying)
        expectNotNil(controller.errorMessage)
    }

    @MainActor func testStaleCompletionIgnored() async throws {
        let url = try fixture()
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([url, try fixture("02.m4a")])
        controller.autoAdvance = true
        controller.load(controller.items[0].id, autoplay: true)
        let stale = try AVAudioPlayer(contentsOf: url)
        controller.audioPlayerDidFinishPlaying(stale, successfully: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        expectEqual(controller.currentID, controller.items[0].id)
        expectTrue(controller.isPlaying)
    }

    @MainActor func testKeyboardDirectionModifiersAndRepeat() async {
        func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                            isARepeat: repeatKey, keyCode: code)!
        }
        expectEqual(WindowKeyboardHandler.offset(for: event(123)), -5)
        expectEqual(WindowKeyboardHandler.offset(for: event(124)), 5)
        expectNil(WindowKeyboardHandler.offset(for: event(124, flags: .command)))
        expectNil(WindowKeyboardHandler.offset(for: event(124, repeatKey: true)))
        expectNil(WindowKeyboardHandler.offset(for: event(125)))
    }
    @MainActor func testConfigurableSeekingAndHoldRate() async throws {
        let controller = AudioPlayerController()
        let keyboard = WindowKeyboardHandler()
        defer { keyboard.uninstall(); controller.shutdown() }
        controller.addFiles([try fixture(seconds: 30)])
        controller.load(controller.items[0].id, autoplay: false)
        controller.forwardSeconds = 13
        controller.backwardSeconds = 7
        keyboard.pressRight(controller: controller)
        keyboard.releaseRight()
        expectEqual(controller.position, 13, accuracy: 0.05)
        controller.seek(by: -Double(controller.backwardSeconds))
        expectEqual(controller.position, 6, accuracy: 0.05)
        keyboard.pressRight(controller: controller)
        keyboard.cancelPress()
        try await Task.sleep(nanoseconds: 400_000_000)
        expectEqual(controller.position, 6, accuracy: 0.05)
        expectFalse(controller.isBoosting)
        controller.holdRate = 1.5
        controller.togglePlayback()
        keyboard.pressRight(controller: controller)
        try await Task.sleep(nanoseconds: 450_000_000)
        expectTrue(controller.isBoosting)
        expectEqual(controller.playbackRate, Float(1.5))
        keyboard.releaseRight()
        expectFalse(controller.isBoosting)
        expectEqual(controller.playbackRate, Float(1))
        expectLessThan(controller.position, 9)
        keyboard.pressRight(controller: controller)
        try await Task.sleep(nanoseconds: 400_000_000)
        keyboard.cancelPress()
        expectEqual(controller.playbackRate, Float(1))
        expectFalse(controller.isBoosting)
        controller.togglePlayback()
        keyboard.pressRight(controller: controller)
        try await Task.sleep(nanoseconds: 400_000_000)
        keyboard.releaseRight()
        expectFalse(controller.isPlaying)
        expectFalse(controller.isBoosting)
        controller.forwardSeconds = 0
        controller.backwardSeconds = 9999
        expectEqual(controller.forwardSeconds, 1)
        expectEqual(controller.backwardSeconds, 600)
    }

}
