import AVFAudio
import AppKit

final class PlayerTests: CheckSuite {
    private func encodedFixture(_ name: String, codec: String, seconds: Double = 8,
                                options: [String] = []) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiniAudioFormats-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                             "sine=frequency=440:sample_rate=48000", "-t", String(seconds),
                             "-ac", "2", "-af", "volume=0.001", "-c:a", codec] + options + [url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "FixtureEncoding", code: Int(process.terminationStatus))
        }
        return url
    }

    @MainActor func testMainstreamFormatsTransport() async throws {
        let formats: [(String, String, [String])] = [
            ("vbr.mp3", "libmp3lame", ["-q:a", "4"]),
            ("cbr.mp3", "libmp3lame", ["-b:a", "128k"]),
            ("audio.aac", "aac", []),
            ("pcm24.wav", "pcm_s24le", []),
            ("float.wav", "pcm_f32le", []),
            ("lossless.flac", "flac", ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"]),
            ("audio.aiff", "pcm_s16be", []),
            ("book.m4b", "aac", []),
            ("audio.caf", "pcm_s24le", []),
            ("vorbis.ogg", "libvorbis", []),
            ("audio.opus", "libopus", []),
            ("opus-in-ogg.ogg", "libopus", [])
        ]
        for (name, codec, options) in formats {
            print("  FORMAT \(name)")
            let url = try encodedFixture(name, codec: codec, options: options)
            let controller = AudioPlayerController()
            controller.addFiles([url])
            expectTrue(controller.load(controller.items[0].id, autoplay: false))
            expectEqual(controller.duration, 8, accuracy: 0.15)
            controller.seek(to: 3)
            expectEqual(controller.position, 3, accuracy: 0.05)
            controller.togglePlayback()
            expectTrue(controller.isPlaying)
            try await Task.sleep(nanoseconds: 400_000_000)
            controller.holdRate = 1.75
            controller.beginBoost()
            expectEqual(controller.playbackRate, Float(1.75))
            controller.endBoost()
            expectEqual(controller.playbackRate, Float(1))
            controller.togglePlayback()
            expectFalse(controller.isPlaying)
            expectGreaterThan(controller.position, 3)
            controller.seek(to: controller.duration)
            expectFalse(controller.isPlaying)
            controller.seek(by: -2)
            expectEqual(controller.position, controller.duration - 2, accuracy: 0.1)
            controller.shutdown()
        }
    }

    @MainActor func testOggCompletionAndCancellation() async throws {
        for codec in ["libvorbis", "libopus"] {
            let controller = AudioPlayerController()
            defer { controller.shutdown() }
            controller.addFiles([try encodedFixture("01.ogg", codec: codec, seconds: 0.4),
                                 try fixture("02.m4a")])
            let first = controller.items[0].id
            controller.autoAdvance = true
            expectTrue(controller.load(first, autoplay: true))
            try await Task.sleep(nanoseconds: 1_400_000_000)
            expectEqual(controller.currentID, controller.items[1].id)
            expectTrue(controller.isPlaying)
            controller.autoAdvance = false
            expectTrue(controller.load(first, autoplay: true))
            try await Task.sleep(nanoseconds: 1_400_000_000)
            expectEqual(controller.currentID, first)
            expectFalse(controller.isPlaying)
            controller.togglePlayback()
            expectTrue(controller.isPlaying)
            controller.seek(to: controller.duration)
            try await Task.sleep(nanoseconds: 150_000_000)
            expectFalse(controller.isPlaying)
            expectEqual(controller.currentID, first)
        }
    }

    @MainActor func testOggPauseSeekAndBadReplacement() async throws {
        let good = try encodedFixture("01.ogg", codec: "libvorbis", seconds: 30)
        let bad = good.deletingLastPathComponent().appendingPathComponent("02.ogg")
        try Data("OggSbroken".utf8).write(to: bad)
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([good, bad, try fixture("03.m4a")])
        let first = controller.items[0].id
        expectTrue(controller.load(first, autoplay: true))
        try await Task.sleep(nanoseconds: 500_000_000)
        controller.togglePlayback()
        let paused = controller.position
        try await Task.sleep(nanoseconds: 400_000_000)
        expectEqual(controller.position, paused, accuracy: 0.05)
        controller.seek(to: 10)
        controller.togglePlayback()
        try await Task.sleep(nanoseconds: 400_000_000)
        expectGreaterThan(controller.position, 10)
        expectFalse(controller.load(controller.items[1].id, autoplay: true))
        expectTrue(controller.isPlaying)
        expectEqual(controller.currentID, first)
        expectNotNil(controller.errorMessage)
        // Stop while the decoder has queued data; delayed callbacks must not advance.
        controller.autoAdvance = true
        controller.load(controller.items[2].id, autoplay: true)
        try await Task.sleep(nanoseconds: 400_000_000)
        expectEqual(controller.currentID, controller.items[2].id)
    }

    @MainActor func testLongOggSeekAndActualDecode() async throws {
        let url = try encodedFixture("long.opus", codec: "libopus", seconds: 600)
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([url])
        expectTrue(controller.load(controller.items[0].id, autoplay: false))
        expectEqual(controller.duration, 600, accuracy: 0.1)
        controller.seek(to: 590)
        controller.togglePlayback()
        try await Task.sleep(nanoseconds: 650_000_000)
        controller.togglePlayback()
        expectGreaterThan(controller.position, 590)
        expectLessThan(controller.position, 592)
        // Check real decoded sample data, independently of the playback state flags.
        let process = Process()
        let output = Pipe()
        process.executableURL = try DecoderTools.executable("ffmpeg")
        process.arguments = ["-v", "error", "-ss", "590", "-i", url.path, "-t", "0.05",
                             "-ac", "2", "-ar", "48000", "-f", "f32le", "pipe:1"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        expectEqual(process.terminationStatus, 0)
        expectGreaterThan(data.count, 1000)
        let maximum = data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Float.self).reduce(Float(0)) { max($0, abs($1)) }
        }
        expectGreaterThan(maximum, Float(0.00001))
    }

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

    @MainActor private func waitForSession(timeout: TimeInterval = 3,
                                           until condition: () -> Bool) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return true
    }

    private func sessionStore() throws -> SessionStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiniAudioSession-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return SessionStore(fileURL: directory.appendingPathComponent("session.json"))
    }

    @MainActor func testSessionRoundTripPausedAndSettings() async throws {
        for (name, codec) in [("audio.mp3", "libmp3lame"), ("audio.flac", "flac"),
                              ("audio.ogg", "libvorbis"), ("audio.opus", "libopus"), ("audio.m4a", "aac")] {
            let store = try sessionStore()
            let original = AudioPlayerController(sessionStore: store)
            await original.restoreSession()
            original.addFiles([try encodedFixture(name, codec: codec), try fixture("z.m4a")])
            let ids = original.items.map(\.id)
            original.load(ids[0], autoplay: true)
            original.seek(to: 3)
            original.autoAdvance = true
            original.forwardSeconds = 17
            original.backwardSeconds = 9
            original.holdRate = 1.75
            original.beginBoost()
            original.selectedID = ids[1]
            original.shutdown()
            let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
            await restored.restoreSession()
            expectEqual(restored.items.map(\.id), ids)
            expectEqual(restored.currentID, ids[0])
            expectEqual(restored.selectedID, ids[1])
            expectEqual(restored.position, 3, accuracy: 0.25)
            expectEqual(restored.forwardSeconds, 17)
            expectEqual(restored.backwardSeconds, 9)
            expectEqual(restored.holdRate, Float(1.75))
            expectTrue(restored.autoAdvance)
            expectFalse(restored.isPlaying)
            expectFalse(restored.isBoosting)
            expectEqual(restored.playbackRate, Float(1))
            let paused = restored.position
            try await Task.sleep(nanoseconds: 150_000_000)
            expectEqual(restored.position, paused)
            restored.togglePlayback()
            expectTrue(restored.isPlaying)
            restored.shutdown()
        }
    }

    @MainActor func testSessionEndRemovalAndEmpty() async throws {
        let store = try sessionStore()
        let original = AudioPlayerController(sessionStore: store)
        await original.restoreSession()
        original.addFiles([try fixture()])
        original.load(original.items[0].id, autoplay: false)
        original.seek(to: original.duration)
        original.autoAdvance = true
        original.shutdown()
        let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await restored.restoreSession()
        expectEqual(restored.position, restored.duration)
        expectFalse(restored.isPlaying)
        restored.togglePlayback()
        expectTrue(restored.isPlaying)
        expectLessThan(restored.position, 1)
        restored.removeSelected()
        restored.shutdown()
        let empty = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await empty.restoreSession()
        expectTrue(empty.items.isEmpty)
        expectNil(empty.currentID)
        expectNil(empty.selectedID)
        expectEqual(empty.position, 0)
        empty.shutdown()
    }

    @MainActor func testSessionMissingRelocationAndChangedDuration() async throws {
        let store = try sessionStore()
        let url = try fixture("missing.m4a")
        let original = AudioPlayerController(sessionStore: store)
        await original.restoreSession()
        original.addFiles([url])
        let id = original.items[0].id
        original.load(id, autoplay: false)
        original.seek(to: 9)
        original.shutdown()
        try FileManager.default.removeItem(at: url)
        let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await restored.restoreSession()
        expectEqual(restored.currentID, id)
        expectTrue(restored.items[0].isUnavailable)
        expectEqual(restored.position, 9, accuracy: 0.05)
        expectFalse(restored.isPlaying)
        expectNil(restored.errorMessage)
        restored.relocate(id, to: try fixture("replacement.m4a", seconds: 4))
        expectEqual(restored.currentID, id)
        expectEqual(restored.items[0].id, id)
        expectFalse(restored.items[0].isUnavailable)
        expectEqual(restored.position, restored.duration)
        expectFalse(restored.isPlaying)
        restored.shutdown()
        let next = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await next.restoreSession()
        expectEqual(next.items[0].name, "replacement.m4a")
        expectEqual(next.position, next.duration)
        next.shutdown()
    }

    @MainActor func testSessionBackupValidationAndFutureProtection() async throws {
        let store = try sessionStore()
        let controller = AudioPlayerController(sessionStore: store)
        await controller.restoreSession()
        controller.addFiles([try fixture()])
        controller.load(controller.items[0].id, autoplay: false)
        controller.seek(to: 2)
        expectTrue(try await waitForSession { FileManager.default.fileExists(atPath: store.checkpointURL.path) })
        controller.seek(to: 7)
        controller.shutdown()
        try Data("corrupt".utf8).write(to: store.checkpointURL)
        let backup = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await backup.restoreSession()
        expectNotNil(backup.sessionNotice)
        expectEqual(backup.position, 2, accuracy: 0.05)
        backup.shutdown()
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        object["forwardSeconds"] = 9999
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
        let validated = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await validated.restoreSession()
        expectNotNil(validated.sessionNotice)
        expectEqual(validated.forwardSeconds, 5)
        validated.shutdown()
        let future = Data("{\"schemaVersion\":99,\"newFields\":true}".utf8)
        try future.write(to: store.fileURL)
        let newer = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await newer.restoreSession()
        expectNotNil(newer.sessionNotice)
        expectTrue(newer.items.isEmpty)
        newer.forwardSeconds = 20
        newer.shutdown()
        expectEqual(try Data(contentsOf: store.fileURL), future)
        try Data("broken".utf8).write(to: store.fileURL)
        try Data("broken".utf8).write(to: store.backupURL)
        try Data("broken".utf8).write(to: store.checkpointURL)
        try Data("broken".utf8).write(to: store.checkpointBackupURL)
        let broken = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await broken.restoreSession()
        expectNotNil(broken.sessionNotice)
        expectTrue(broken.items.isEmpty)
        broken.shutdown()
    }

    @MainActor func testSessionPeriodicSaveWithoutShutdown() async throws {
        let store = try sessionStore()
        let original = AudioPlayerController(sessionStore: store)
        await original.restoreSession()
        defer { original.shutdown() }
        original.addFiles([try fixture()])
        original.load(original.items[0].id, autoplay: true)
        expectTrue(try await waitForSession(timeout: 8) {
            guard let data = try? Data(contentsOf: store.checkpointURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? [String: Any], let position = state["position"] as? Double
            else { return false }
            return position > 4.5
        })
        // Read before shutdown: this must come from the periodic crash-recovery checkpoint.
        let reader = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await reader.restoreSession()
        expectGreaterThan(reader.position, 4.5)
        expectLessThan(reader.position, 8.5)
        expectFalse(reader.isPlaying)
        reader.shutdown()
    }

    @MainActor func testSessionRapidUpdatesAndWriteFailure() async throws {
        let store = try sessionStore()
        let original = AudioPlayerController(sessionStore: store)
        await original.restoreSession()
        original.addFiles([try fixture()])
        original.load(original.items[0].id, autoplay: false)
        for value in 1...100 {
            original.forwardSeconds = value
            original.seek(to: Double(value) / 10)
        }
        original.shutdown()
        let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await restored.restoreSession()
        expectEqual(restored.forwardSeconds, 100)
        expectEqual(restored.position, 10, accuracy: 0.05)
        restored.shutdown()
        let blocker = store.fileURL.deletingLastPathComponent().appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocker)
        let blocked = AudioPlayerController(sessionStore: SessionStore(fileURL: blocker.appendingPathComponent("session.json")))
        await blocked.restoreSession()
        blocked.forwardSeconds = 12
        expectTrue(try await waitForSession { blocked.sessionNotice != nil })
        expectNotNil(blocked.sessionNotice)
        expectEqual(blocked.forwardSeconds, 12)
        blocked.shutdown()
    }

    @MainActor func testSessionScale() async throws {
        let url = try fixture()
        for count in [100, 1000] {
            let store = try sessionStore()
            let entries = (0..<count).map { _ in PlaylistItem(url: url) }
            let state = SavedSession(items: entries, position: 0, duration: 0, autoAdvance: false,
                                     forwardSeconds: 5, backwardSeconds: 5, holdRate: 2)
            let start = Date()
            expectNil(store.flush(state))
            let written = Date()
            let result = await store.load()
            let end = Date()
            expectEqual(result.session?.items.count, count)
            let libraryBytes = try Data(contentsOf: store.fileURL)
            var progress = state
            progress.duration = 100
            for index in 1...12 {
                progress.position = Double(index)
                expectNil(store.flush(progress))
            }
            expectEqual(try Data(contentsOf: store.fileURL), libraryBytes)
            expectLessThan(try Data(contentsOf: store.checkpointURL).count, 2048)
            let latest = await SessionStore(fileURL: store.fileURL).load()
            expectEqual(latest.session?.position, 12)
            print("  CHECKPOINT bytes=\(try Data(contentsOf: store.checkpointURL).count), library unchanged after 12 updates")
            print("  SESSION \(count) entries: write=\(written.timeIntervalSince(start))s restore=\(end.timeIntervalSince(written))s bytes=\(try Data(contentsOf: store.fileURL).count)")
        }
    }

    @MainActor func testSessionInterruptedLibraryUpdateAndEarlyExit() async throws {
        let store = try sessionStore()
        let original = AudioPlayerController(sessionStore: store)
        await original.restoreSession()
        original.addFiles([try fixture("first.m4a")])
        original.load(original.items[0].id, autoplay: false)
        original.seek(to: 3)
        expectTrue(try await waitForSession { FileManager.default.fileExists(atPath: store.checkpointURL.path) })
        let stale = try Data(contentsOf: store.checkpointURL)
        original.addFiles([try fixture("second.m4a")])
        let second = original.items[1].id
        original.load(second, autoplay: false)
        original.seek(to: 6)
        original.shutdown()
        // Simulate termination after the library was replaced but before the new checkpoint.
        try stale.write(to: store.checkpointURL)
        try stale.write(to: store.checkpointBackupURL)
        let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await restored.restoreSession()
        expectEqual(restored.items.count, 2)
        expectEqual(restored.currentID, second)
        expectEqual(restored.position, 6, accuracy: 0.05)
        expectFalse(restored.isPlaying)
        restored.shutdown()
        let base = try Data(contentsOf: store.fileURL)
        let transport = try Data(contentsOf: store.checkpointURL)
        let earlyExit = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        earlyExit.shutdown()
        expectEqual(try Data(contentsOf: store.fileURL), base)
        expectEqual(try Data(contentsOf: store.checkpointURL), transport)
        let future = Data("{\"schemaVersion\":99}".utf8)
        try future.write(to: store.checkpointURL)
        let newer = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await newer.restoreSession()
        expectNotNil(newer.sessionNotice)
        newer.shutdown()
        expectEqual(try Data(contentsOf: store.checkpointURL), future)
        expectEqual(try Data(contentsOf: store.fileURL), base)
    }

    @MainActor func testSessionFutureFilesWithoutLibraryAndInBackup() async throws {
        let future = Data("{\"schemaVersion\":99}".utf8)
        let store = try sessionStore()
        // A future transport must survive even when no library can be read.
        try future.write(to: store.checkpointURL)
        let orphan = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await orphan.restoreSession()
        expectNotNil(orphan.sessionNotice)
        orphan.shutdown()
        expectEqual(try Data(contentsOf: store.checkpointURL), future)
        expectFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        try FileManager.default.removeItem(at: store.checkpointURL)
        let original = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await original.restoreSession()
        original.addFiles([try fixture()])
        original.shutdown()
        let base = try Data(contentsOf: store.fileURL)
        for backupURL in [store.backupURL, store.checkpointBackupURL] {
            let previous = try Data(contentsOf: backupURL)
            try future.write(to: backupURL)
            let protected = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
            await protected.restoreSession()
            expectNotNil(protected.sessionNotice)
            protected.forwardSeconds = 42
            protected.shutdown()
            expectEqual(try Data(contentsOf: backupURL), future)
            expectEqual(try Data(contentsOf: store.fileURL), base)
            try previous.write(to: backupURL)
        }
    }

}
