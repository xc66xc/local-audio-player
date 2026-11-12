import AVFAudio
import AppKit
import CryptoKit
import CommonCrypto
import Darwin
import UniformTypeIdentifiers

// A provider that only delivers after the test has performed the competing user action.
private final class DropProviderGate: @unchecked Sendable {
    let provider = NSItemProvider()
    private let lock = NSLock()
    private var completion: ((Data?, Error?) -> Void)?
    private var didRequest = false
    private let data: Data?
    private let failure: NSError?

    init(url: URL? = nil, fail: Bool = false) {
        data = url.map { Data($0.absoluteString.utf8) }
        failure = fail ? NSError(domain: "DropFixture", code: 1) : nil
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { [weak self] callback in
            guard let self else { return nil }
            self.lock.lock()
            self.completion = callback
            self.didRequest = true
            self.lock.unlock()
            return nil
        }
    }

    var wasRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRequest
    }

    func deliver() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(data, failure)
    }
}

final class PlayerTests: CheckSuite {
    private struct NcmFixture {
        let source: URL
        let bytes: Data
        let payload: Data
    }

    private func ncmDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiniAudioNcm-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return directory
    }

    // Package only generated test audio. The fixed AES key is a public NCM format
    // constant; this fixture never reads an installed client, account, or user song.
    private func ncmBytes(_ payload: Data, version: UInt8 = 1, invalidCRC: Bool = false,
                          missingLegacyCRC: Bool = false) throws -> Data {
        let coreKey = Array("hzHRAmso5kInbaxW".utf8)
        let streamKey = Array("independent-NCM-fixture-stream-key".utf8)
        let plaintext = Array("neteasecloudmusic".utf8) + streamKey
        var encrypted = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        let capacity = encrypted.count
        var written = 0
        let status = coreKey.withUnsafeBytes { key in
            plaintext.withUnsafeBytes { source in
                encrypted.withUnsafeMutableBytes { destination in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            key.baseAddress, coreKey.count, nil, source.baseAddress, plaintext.count,
                            destination.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw NSError(domain: "NcmFixtureAES", code: Int(status)) }
        encrypted = encrypted.prefix(written).map { $0 ^ 0x64 }
        func little32(_ number: UInt32) -> Data {
            var value = number.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        var header = Data("CTENFDAM".utf8)
        header.append(contentsOf: [version, 0])
        header.append(little32(UInt32(encrypted.count)))
        header.append(contentsOf: encrypted)
        header.append(little32(0)) // Empty metadata: identify the codec from the payload.
        var crc: UInt32 = 0xffffffff
        for byte in header {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        }
        crc ^= 0xffffffff
        header.append(little32(missingLegacyCRC ? 0 : (invalidCRC ? crc ^ 1 : crc)))
        header.append(version)
        header.append(little32(19)) // Cover capacity differs from the empty cover length.
        header.append(little32(0))
        header.append(Data(repeating: 0, count: 19))
        var box = (0..<256).map { UInt8($0) }
        var cursor = 0
        for index in 0..<256 {
            cursor = (cursor + Int(box[index]) + Int(streamKey[index % streamKey.count])) & 255
            box.swapAt(index, cursor)
        }
        let mask = (0..<256).map { position -> UInt8 in
            let index = (position + 1) & 255
            let value = Int(box[index])
            return box[(value + Int(box[(value + index) & 255])) & 255]
        }
        header.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 255] })
        return header
    }

    private func ncmFixture(_ name: String, codec: String, seconds: Double = 12,
                            version: UInt8 = 1) throws -> NcmFixture {
        let audio = try encodedFixture("payload.\(codec == "flac" ? "flac" : "mp3")", codec: codec, seconds: seconds)
        let payload = try Data(contentsOf: audio)
        let bytes = try ncmBytes(payload, version: version, missingLegacyCRC: version == 0)
        let source = audio.deletingLastPathComponent().appendingPathComponent(name)
        try bytes.write(to: source)
        return NcmFixture(source: source, bytes: bytes, payload: payload)
    }

    private func realNcmHelper() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/release/ncm-restore")
    }

    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func ncmSlowHelper(in directory: URL, release: URL? = nil) throws -> (tool: URL, pid: URL) {
        let tool = directory.appendingPathComponent("controlled-helper")
        let pid = directory.appendingPathComponent("helper.pid")
        var script = "#!/bin/sh\nprintf '%s' \"$$\" > \(shellQuote(pid.path))\n"
        if let release {
            script += "while [ ! -e \(shellQuote(release.path)) ]; do /bin/sleep 0.05; done\n"
            script += "exec \(shellQuote(realNcmHelper().path)) \"$@\"\n"
        } else {
            // exec preserves the PID so the test can prove the actual helper died.
            script += "exec /bin/sleep 60\n"
        }
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        return (tool, pid)
    }

    private func helperIsRunning(_ marker: URL) -> Bool {
        guard let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func directoryIsEmpty(_ directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true
    }

    @MainActor func testNcmPreparationBytesWarningsAndLeaseCleanup() async throws {
        let temporary = try ncmDirectory("prepared")
        let preparer = NcmPreparer(temporaryRoot: temporary)
        for (codec, suffix) in [("libmp3lame", "mp3"), ("flac", "flac")] {
            for version: UInt8 in [0, 1] {
                let fixture = try ncmFixture("合成 \(suffix)-v\(version).NCM", codec: codec, version: version)
                var prepared: NcmPreparedAudio? = try await preparer.prepare(fixture.source)
                let output = prepared!.url
                expectEqual(output.pathExtension, suffix)
                expectEqual(try Data(contentsOf: output), fixture.payload)
                expectEqual(try Data(contentsOf: fixture.source), fixture.bytes)
                let observedTime = try fixture.source.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate!.timeIntervalSince1970
                expectEqual(prepared!.sourceModificationTime, observedTime)
                expectTrue(output.path.hasPrefix(temporary.path + "/"))
                expectEqual(prepared!.warnings.isEmpty, version == 1)
                let permissions = try FileManager.default.attributesOfItem(atPath: output.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
                expectEqual(permissions?.intValue, 0o700)
                prepared = nil
                expectTrue(try await waitForSession { !FileManager.default.fileExists(atPath: output.path) })
                expectTrue(directoryIsEmpty(temporary))
            }
        }
    }

    @MainActor func testNcmRejectsCorruptTruncatedAndInvalidAudio() async throws {
        let temporary = try ncmDirectory("reject-output")
        let inputs = try ncmDirectory("reject-input")
        let preparer = NcmPreparer(temporaryRoot: temporary)
        let audio = try encodedFixture("crc.flac", codec: "flac")
        let valid = try ncmBytes(Data(contentsOf: audio))
        let variants = [try ncmBytes(Data(contentsOf: audio), invalidCRC: true),
                        Data(valid.prefix(20)), try ncmBytes(Data("invalid audio payload".utf8))]
        for (index, bytes) in variants.enumerated() {
            let source = inputs.appendingPathComponent("bad-\(index).ncm")
            try bytes.write(to: source)
            do {
                _ = try await preparer.prepare(source)
                expectTrue(false)
            } catch {
                expectFalse(error.localizedDescription.isEmpty)
            }
            expectEqual(try Data(contentsOf: source), bytes)
            expectTrue(directoryIsEmpty(temporary))
        }
    }

    @MainActor func testNcmPlaybackSeekHoldAndNaturalCompletion() async throws {
        for codec in ["libmp3lame", "flac"] {
            let fixture = try ncmFixture("01.ncm", codec: codec, seconds: 8)
            let temporary = try ncmDirectory("transport")
            let controller = AudioPlayerController(ncmPreparer: NcmPreparer(temporaryRoot: temporary))
            let keyboard = WindowKeyboardHandler()
            defer { keyboard.uninstall(); controller.shutdown() }
            controller.addFiles([fixture.source, try self.fixture("02.m4a")])
            let id = controller.items[0].id
            expectTrue(controller.load(id, autoplay: false))
            expectTrue(controller.isPreparingAudio)
            expectEqual(controller.preparingItemID, id)
            expectTrue(try await waitForSession { !controller.isPreparingAudio })
            expectEqual(controller.currentID, id)
            expectEqual(controller.duration, 8, accuracy: 0.15)
            expectFalse(controller.isPlaying)
            controller.seek(to: 3)
            expectEqual(controller.position, 3, accuracy: 0.05)
            controller.togglePlayback()
            expectTrue(try await waitForSession { controller.position > 3.1 })
            controller.holdRate = 1.5
            keyboard.pressRight(controller: controller)
            expectTrue(try await waitForSession { controller.isBoosting })
            expectEqual(controller.playbackRate, Float(1.5))
            keyboard.releaseRight()
            expectFalse(controller.isBoosting)
            expectEqual(controller.playbackRate, Float(1))
            controller.togglePlayback()
            let paused = controller.position
            controller.seek(to: paused - 1)
            expectFalse(controller.isPlaying)
            expectEqual(controller.position, paused - 1, accuracy: 0.05)
            controller.autoAdvance = true
            controller.seek(to: controller.duration - 0.25)
            controller.togglePlayback()
            expectTrue(try await waitForSession { controller.currentID == controller.items[1].id })
            expectTrue(controller.isPlaying)
            expectEqual(try Data(contentsOf: fixture.source), fixture.bytes)
            expectTrue(directoryIsEmpty(temporary))
        }
    }

    @MainActor func testNcmDropPendingResumeRestoreAndRenameOriginal() async throws {
        let fixture = try ncmFixture("中文 拖入.ncm", codec: "libmp3lame", seconds: 20)
        var preciseTimes = [timespec(tv_sec: 1_762_823_456, tv_nsec: 123_456_789),
                            timespec(tv_sec: 1_762_823_456, tv_nsec: 123_456_789)]
        guard utimensat(AT_FDCWD, fixture.source.path, &preciseTimes, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let store = try sessionStore()
        let original = AudioPlayerController(sessionStore: store)
        defer { original.shutdown() }
        await original.restoreSession()
        expectTrue(original.receiveDroppedFiles([dropProvider(fixture.source)]))
        expectTrue(try await waitForSession { !original.fileDrop.isLoading && !original.isPreparingAudio })
        expectEqual(original.items.count, 1)
        let id = original.items[0].id
        expectEqual(original.currentID, id)
        expectTrue(original.isPlaying)
        original.togglePlayback()
        original.seek(to: 7)
        original.addFiles([try self.fixture("另一个.m4a")])
        let other = original.items.first { $0.id != id }!.id
        expectTrue(original.load(other, autoplay: false))
        expectTrue(original.load(id, autoplay: true))
        expectTrue(try await waitForSession { !original.isPreparingAudio })
        expectEqual(original.pendingResume?.position, 7)
        expectTrue(try await waitForSession { original.position > 0.2 })
        original.togglePlayback()
        let actual = original.position
        original.shutdown()

        let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        defer { restored.shutdown() }
        await restored.restoreSession()
        expectTrue(try await waitForSession { !restored.isPreparingAudio })
        expectEqual(restored.currentID, id)
        expectEqual(restored.currentItem?.url, fixture.source)
        expectFalse(restored.isPlaying)
        expectEqual(restored.position, actual, accuracy: 0.15)
        expectEqual(restored.pendingResume?.position, 7)
        restored.acceptResume()
        expectEqual(restored.position, 7, accuracy: 0.05)
        restored.togglePlayback()
        expectTrue(restored.renameFile(id, to: "改名后仍为容器"))
        expectTrue(try await waitForSession { !restored.isPreparingAudio })
        let renamed = restored.currentItem!.url
        expectEqual(renamed.lastPathComponent, "改名后仍为容器.ncm")
        expectFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        expectEqual(try Data(contentsOf: renamed), fixture.bytes)
        expectEqual(restored.currentID, id)
        expectTrue(restored.isPlaying)
        expectTrue(try await waitForSession { restored.position > 7.1 })
        restored.seek(to: 5)
        expectEqual(restored.position, 5, accuracy: 0.15)
    }

    @MainActor func testNcmMiniSwitchKeepsPreparationAndRelocationPosition() async throws {
        let fixture = try ncmFixture("01.ncm", codec: "flac")
        let helperDirectory = try ncmDirectory("mini-helper")
        let release = helperDirectory.appendingPathComponent("release")
        let helper = try ncmSlowHelper(in: helperDirectory, release: release)
        let preparer = NcmPreparer(toolURL: helper.tool, temporaryRoot: try ncmDirectory("mini-output"))
        let controller = AudioPlayerController(ncmPreparer: preparer)
        let window = windowFixture()
        let modes = WindowModeCoordinator(defaults: try windowDefaults())
        defer { modes.shutdown(); window.close(); controller.shutdown() }
        modes.attach(to: window)
        expectTrue(try await waitForSession { !modes.isTransitioning })
        controller.addFiles([fixture.source])
        let id = controller.items[0].id
        expectTrue(controller.load(id, autoplay: false))
        expectTrue(try await waitForSession { helperIsRunning(helper.pid) })
        modes.toggle()
        expectTrue(try await waitForSession { modes.isMini && !modes.isTransitioning })
        expectTrue(controller.isPreparingAudio)
        try Data().write(to: release)
        expectTrue(try await waitForSession { !controller.isPreparingAudio })
        expectEqual(controller.currentID, id)
        controller.seek(to: 6)
        let replacement = try ncmFixture("移动后.ncm", codec: "flac", seconds: 4)
        controller.relocate(id, to: replacement.source)
        expectTrue(try await waitForSession { !controller.isPreparingAudio })
        expectEqual(controller.currentID, id)
        expectEqual(controller.currentItem?.url, replacement.source)
        expectEqual(controller.position, controller.duration, accuracy: 0.05)
        expectFalse(controller.isPlaying)
        expectEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        expectEqual(try Data(contentsOf: replacement.source), replacement.bytes)
    }

    @MainActor func testNcmSlowPreparationCannotOverrideNewerUserActions() async throws {
        for action in ["pause", "seek", "load", "rename", "remove", "cancel"] {
            let fixture = try ncmFixture("02.ncm", codec: "libmp3lame")
            let helper = try ncmSlowHelper(in: ncmDirectory("cancel-helper"))
            let temporary = try ncmDirectory("cancel-output")
            let preparer = NcmPreparer(toolURL: helper.tool, temporaryRoot: temporary)
            let controller = AudioPlayerController(ncmPreparer: preparer)
            defer { controller.shutdown() }
            controller.addFiles([try self.fixture("01.m4a"), fixture.source, try self.fixture("03.m4a")])
            let old = controller.items[0].id
            let loading = controller.items[1].id
            let newer = controller.items[2].id
            expectTrue(controller.load(old, autoplay: true))
            controller.seek(to: 3)
            expectTrue(controller.load(loading, autoplay: true))
            expectTrue(try await waitForSession { helperIsRunning(helper.pid) })
            switch action {
            case "pause": controller.togglePlayback()
            case "seek": controller.seek(to: 5)
            case "load": expectTrue(controller.load(newer, autoplay: false))
            case "rename": expectTrue(controller.renameFile(loading, to: "准备期间改名"))
            case "remove": controller.selectedID = loading; controller.removeSelected()
            default: controller.cancelAudioPreparation()
            }
            expectTrue(try await waitForSession { !controller.isPreparingAudio && !helperIsRunning(helper.pid) })
            expectEqual(controller.currentID, action == "load" ? newer : old)
            expectEqual(controller.isPlaying, action != "pause" && action != "load")
            if action == "seek" { expectTrue(controller.position >= 5 && controller.position < 6) }
            if action == "pause" { expectTrue(controller.position >= 3 && controller.position < 4) }
            preparer.cancelAllAndWait()
            expectTrue(directoryIsEmpty(temporary))
            let original = action == "rename" ? fixture.source.deletingLastPathComponent().appendingPathComponent("准备期间改名.ncm") : fixture.source
            expectEqual(try Data(contentsOf: original), fixture.bytes)
        }
    }

    @MainActor func testNcmFailedPreparationKeepsOldPlaybackAndResumeOffer() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        let badDirectory = try ncmDirectory("failure")
        let bad = badDirectory.appendingPathComponent("03-bad.ncm")
        try Data("truncated NCM".utf8).write(to: bad)
        controller.addFiles([try fixture("01.m4a"), try fixture("02.m4a"), bad])
        let id = controller.items[0].id
        expectTrue(controller.load(id, autoplay: false))
        controller.seek(to: 7)
        expectTrue(controller.load(controller.items[1].id, autoplay: false))
        expectTrue(controller.load(id, autoplay: true))
        expectEqual(controller.pendingResume?.position, 7)
        expectTrue(controller.load(controller.items[2].id, autoplay: true))
        expectTrue(try await waitForSession { !controller.isPreparingAudio })
        expectEqual(controller.currentID, id)
        expectTrue(controller.isPlaying)
        expectEqual(controller.pendingResume?.position, 7)
        expectNotNil(controller.errorMessage)
        let before = controller.position
        expectTrue(try await waitForSession { controller.position > before + 0.1 })
    }

    @MainActor func testNcmTimeoutAndShutdownReapHelperAndCleanScratch() async throws {
        let fixture = try ncmFixture("slow.ncm", codec: "flac")
        let timeoutHelper = try ncmSlowHelper(in: ncmDirectory("timeout-helper"))
        let timeoutRoot = try ncmDirectory("timeout-output")
        let timedOut = NcmPreparer(toolURL: timeoutHelper.tool, temporaryRoot: timeoutRoot, timeout: 0.2)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await timedOut.prepare(fixture.source)
            expectTrue(false)
        } catch {
            expectTrue(error.localizedDescription.contains("超时"))
        }
        expectLessThan(ProcessInfo.processInfo.systemUptime - started, 4)
        // The deadline may expire before the child's first instruction. The shutdown
        // case below separately waits for a live PID before proving termination.
        expectFalse(helperIsRunning(timeoutHelper.pid))
        expectTrue(directoryIsEmpty(timeoutRoot))

        let shutdownHelper = try ncmSlowHelper(in: ncmDirectory("shutdown-helper"))
        let shutdownRoot = try ncmDirectory("shutdown-output")
        let preparer = NcmPreparer(toolURL: shutdownHelper.tool, temporaryRoot: shutdownRoot)
        let controller = AudioPlayerController(ncmPreparer: preparer)
        controller.addFiles([fixture.source])
        expectTrue(controller.load(controller.items[0].id, autoplay: true))
        expectTrue(try await waitForSession { helperIsRunning(shutdownHelper.pid) })
        controller.shutdown()
        preparer.cancelAllAndWait()
        expectFalse(helperIsRunning(shutdownHelper.pid))
        expectFalse(controller.isPreparingAudio)
        expectFalse(controller.isPlaying)
        expectTrue(directoryIsEmpty(shutdownRoot))
        expectEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }

    @MainActor func testRestartNativeStateAndSavedResume() async throws {
        let store = try sessionStore()
        let controller = AudioPlayerController(sessionStore: store)
        defer { controller.shutdown() }
        await controller.restoreSession()
        controller.restartPlayback()
        expectNil(controller.currentID)
        expectFalse(controller.isPlaying)
        controller.addFiles([try fixture("01-restart.m4a", seconds: 20), try fixture("02-selected.m4a")])
        controller.restartPlayback()
        expectNil(controller.currentID)

        let current = controller.items[0].id
        let selected = controller.items[1].id
        expectTrue(controller.load(current, autoplay: false))
        controller.seek(to: 7)
        expectTrue(controller.load(selected, autoplay: false))
        expectTrue(controller.load(current, autoplay: true))
        expectEqual(controller.pendingResume?.position, 7)
        controller.holdRate = 1.75
        controller.beginBoost()
        expectTrue(controller.isBoosting)
        controller.selectedID = selected
        controller.restartPlayback()
        expectEqual(controller.currentID, current)
        expectTrue(controller.isPlaying)
        expectEqual(controller.position, 0, accuracy: 0.1)
        expectFalse(controller.isBoosting)
        expectEqual(controller.playbackRate, Float(1))
        expectNil(controller.pendingResume)
        expectTrue(try await waitForSession { controller.position > 0.15 })

        controller.togglePlayback()
        controller.seek(to: 4)
        controller.restartPlayback()
        expectTrue(controller.isPlaying)
        expectEqual(controller.currentID, current)
        expectEqual(controller.position, 0, accuracy: 0.1)
        controller.seek(to: controller.duration)
        expectFalse(controller.isPlaying)
        controller.autoAdvance = true
        controller.restartPlayback()
        expectTrue(controller.isPlaying)
        expectEqual(controller.currentID, current)
        expectTrue(try await waitForSession { controller.position > 0.15 })
        expectLessThan(controller.position, 2)
        controller.togglePlayback()
        let restartedPosition = controller.position
        controller.shutdown()

        let saved = await SessionStore(fileURL: store.fileURL).load()
        expectNil(saved.session?.pendingResume)
        expectNil(saved.session?.resumePositions[current])
        let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        defer { restored.shutdown() }
        await restored.restoreSession()
        expectEqual(restored.currentID, current)
        expectEqual(restored.position, restartedPosition, accuracy: 0.1)
        expectFalse(restored.isPlaying)
        expectNil(restored.pendingResume)
    }

    @MainActor func testRestartOpusAndNcmPreparedPlayback() async throws {
        let opus = AudioPlayerController()
        defer { opus.shutdown() }
        opus.addFiles([try encodedFixture("01.opus", codec: "libopus"), try fixture("02.m4a")])
        let first = opus.items[0].id
        expectTrue(opus.load(first, autoplay: true))
        opus.autoAdvance = true
        opus.seek(to: opus.duration - 0.15)
        opus.restartPlayback()
        expectEqual(opus.currentID, first)
        expectTrue(opus.isPlaying)
        expectEqual(opus.position, 0, accuracy: 0.15)
        // Wait beyond the previous session's end; it must not advance this restart.
        expectTrue(try await waitForSession { opus.position > 0.3 })
        expectEqual(opus.currentID, first)
        expectLessThan(opus.position, 2)
        opus.seek(to: opus.duration)
        opus.restartPlayback()
        expectTrue(opus.isPlaying)
        expectEqual(opus.currentID, first)
        expectEqual(opus.position, 0, accuracy: 0.15)

        let fixture = try ncmFixture("当前.ncm", codec: "flac")
        let helperDirectory = try ncmDirectory("restart-helper")
        let release = helperDirectory.appendingPathComponent("release")
        try Data().write(to: release)
        let helper = try ncmSlowHelper(in: helperDirectory, release: release)
        let temporary = try ncmDirectory("restart-prepared")
        let controller = AudioPlayerController(ncmPreparer: NcmPreparer(toolURL: helper.tool, temporaryRoot: temporary))
        defer { controller.shutdown() }
        controller.addFiles([fixture.source])
        let id = controller.items[0].id
        expectTrue(controller.load(id, autoplay: false))
        expectTrue(try await waitForSession { !controller.isPreparingAudio })
        expectEqual(controller.currentID, id)
        controller.seek(to: controller.duration)
        controller.restartPlayback()
        expectTrue(controller.isPreparingAudio)
        expectTrue(try await waitForSession { !controller.isPreparingAudio })
        expectTrue(controller.isPlaying)
        expectEqual(controller.currentID, id)
        expectLessThan(controller.position, 1)
        controller.togglePlayback()
        controller.seek(to: 5)
        expectTrue(controller.renameFile(id, to: "改名后的当前音频"))
        let preparedDirectories = try FileManager.default.contentsOfDirectory(atPath: temporary.path).sorted()
        expectFalse(preparedDirectories.isEmpty)
        // A loaded NCM must keep its restored lease: a second helper is unavailable.
        try FileManager.default.removeItem(at: helper.tool)
        controller.restartPlayback()
        expectFalse(controller.isPreparingAudio)
        expectTrue(controller.isPlaying)
        expectEqual(controller.currentID, id)
        expectEqual(controller.position, 0, accuracy: 0.15)
        expectEqual(controller.currentItem?.name, "改名后的当前音频.ncm")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path).sorted(), preparedDirectories)
        expectTrue(try await waitForSession { controller.position > 0.15 })
        expectNil(controller.errorMessage)
        expectEqual(try Data(contentsOf: controller.currentItem!.url), fixture.bytes)
        controller.shutdown()
        expectTrue(directoryIsEmpty(temporary))
    }

    @MainActor func testRestartSupersedesPendingImports() async throws {
        let fixture = try ncmFixture("02-late.ncm", codec: "libmp3lame")
        let helper = try ncmSlowHelper(in: ncmDirectory("restart-cancel-helper"))
        let temporary = try ncmDirectory("restart-cancel-output")
        let controller = AudioPlayerController(ncmPreparer: NcmPreparer(toolURL: helper.tool, temporaryRoot: temporary))
        defer { controller.shutdown() }
        controller.addFiles([try self.fixture("01-current.m4a"), fixture.source])
        let current = controller.items[0].id
        expectTrue(controller.load(current, autoplay: true))
        controller.seek(to: 3)
        let gate = DropProviderGate(url: try self.fixture("03-late-drop.m4a"))
        expectTrue(controller.receiveDroppedFiles([gate.provider]))
        expectTrue(try await waitForSession { gate.wasRequested })
        controller.restartPlayback()
        expectFalse(controller.fileDrop.isLoading)
        expectEqual(controller.position, 0, accuracy: 0.1)
        gate.deliver()
        expectTrue(try await waitForSession { controller.position > 0.15 })
        expectEqual(controller.items.count, 2)
        expectEqual(controller.currentID, current)

        controller.seek(to: 4)
        expectTrue(controller.load(controller.items[1].id, autoplay: true))
        expectTrue(try await waitForSession { helperIsRunning(helper.pid) })
        controller.restartPlayback()
        expectTrue(try await waitForSession { !controller.isPreparingAudio && !helperIsRunning(helper.pid) })
        expectEqual(controller.currentID, current)
        expectTrue(controller.isPlaying)
        expectLessThan(controller.position, 2)
        expectTrue(try await waitForSession { directoryIsEmpty(temporary) })
    }

    @MainActor func testRestartFailureAndStartupGuards() async throws {
        let source = try fixture("01-restart-missing.m4a")
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([source, try fixture("02.m4a")])
        let id = controller.items[0].id
        expectTrue(controller.load(id, autoplay: false))
        controller.seek(to: 7)
        expectTrue(controller.load(controller.items[1].id, autoplay: false))
        expectTrue(controller.load(id, autoplay: true))
        expectTrue(try await waitForSession { controller.position > 0.15 })
        controller.togglePlayback()
        let position = controller.position
        expectEqual(controller.pendingResume?.position, 7)
        try FileManager.default.removeItem(at: source)
        controller.restartPlayback()
        expectNotNil(controller.errorMessage)
        expectEqual(controller.currentID, id)
        expectEqual(controller.position, position, accuracy: 0.05)
        expectEqual(controller.pendingResume?.position, 7)
        expectFalse(controller.isPlaying)
        controller.shutdown()
        controller.restartPlayback()
        expectNil(controller.currentID)
        expectFalse(controller.isPlaying)

        let fixture = try ncmFixture("恢复中的音频.ncm", codec: "flac")
        let helperDirectory = try ncmDirectory("restart-restore-helper")
        let release = helperDirectory.appendingPathComponent("release")
        let helper = try ncmSlowHelper(in: helperDirectory, release: release)
        let store = try sessionStore()
        let item = PlaylistItem(url: fixture.source)
        let saved = SavedSession(items: [item], selectedID: item.id, currentID: item.id,
            position: 6, duration: 12, autoAdvance: false, forwardSeconds: 5, backwardSeconds: 5, holdRate: 2)
        expectNil(store.flush(saved))
        let restoring = AudioPlayerController(sessionStore: store,
            ncmPreparer: NcmPreparer(toolURL: helper.tool, temporaryRoot: try ncmDirectory("restart-restore-output")))
        defer { restoring.shutdown() }
        let restoration = Task { await restoring.restoreSession() }
        expectTrue(try await waitForSession { restoring.isRestoring && helperIsRunning(helper.pid) })
        restoring.restartPlayback()
        expectTrue(restoring.isPreparingAudio)
        expectTrue(helperIsRunning(helper.pid))
        try Data().write(to: release)
        await restoration.value
        expectFalse(restoring.isRestoring)
        expectFalse(restoring.isPlaying)
        expectEqual(restoring.position, 6, accuracy: 0.05)
        expectEqual(restoring.currentID, item.id)
    }

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

    private func windowDefaults() throws -> UserDefaults {
        let suite = "SonaWindowChecks-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw NSError(domain: "WindowFixture", code: 1)
        }
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor private func windowFixture() -> NSWindow {
        _ = NSApplication.shared
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 20, y: screen.minY + 20,
                                                  width: 1000, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // These AppKit windows are never ordered front; real SwiftUI layout/focus is checked in GUI QA.
        return window
    }

    @MainActor func testMiniWindowFramesPinAndPreferences() async throws {
        let defaults = try windowDefaults()
        let window = windowFixture()
        let modes = WindowModeCoordinator(defaults: defaults)
        defer { modes.shutdown(); window.close() }
        expectFalse(modes.isMini)
        expectTrue(modes.isPinned)
        modes.attach(to: window)
        expectTrue(try await waitForSession { !modes.isTransitioning })
        let original = window.frame
        expectFalse(window.isVisible)

        modes.toggle()
        expectTrue(try await waitForSession { modes.isMini && !modes.isTransitioning })
        expectEqual(window.level, .floating)
        expectTrue(window.canBecomeKey)
        expectLessThan(window.frame.height, 200)
        let baseHeight = modes.miniContentHeight
        modes.updateMiniSupplementHeight(28)
        expectTrue(try await waitForSession { !modes.isTransitioning })
        expectEqual(modes.miniContentHeight, baseHeight + 28, accuracy: 0.1)
        modes.updateMiniSupplementHeight(0)
        expectTrue(try await waitForSession { !modes.isTransitioning })
        modes.togglePinned()
        expectFalse(modes.isPinned)
        expectEqual(window.level, .normal)

        modes.toggle()
        expectTrue(try await waitForSession { !modes.isMini && !modes.isTransitioning })
        expectEqual(window.level, .normal)
        expectEqual(window.frame.minX, original.minX, accuracy: 1.5)
        expectEqual(window.frame.minY, original.minY, accuracy: 1.5)
        expectEqual(window.frame.width, original.width, accuracy: 1.5)
        expectEqual(window.frame.height, original.height, accuracy: 1.5)

        modes.toggle()
        expectTrue(try await waitForSession { modes.isMini && !modes.isTransitioning })
        let compact = window.frame
        modes.shutdown()
        let restoredWindow = windowFixture()
        let restored = WindowModeCoordinator(defaults: defaults)
        defer { restored.shutdown(); restoredWindow.close() }
        expectTrue(restored.isMini)
        expectFalse(restored.isPinned)
        restored.attach(to: restoredWindow)
        expectTrue(try await waitForSession { !restored.isTransitioning })
        expectEqual(restoredWindow.level, .normal)
        expectEqual(restoredWindow.frame.minX, compact.minX, accuracy: 1.5)
        expectEqual(restoredWindow.frame.minY, compact.minY, accuracy: 1.5)
        expectEqual(restoredWindow.frame.width, compact.width, accuracy: 1.5)
        expectFalse(restoredWindow.isVisible)
    }

    @MainActor func testMiniWindowKeepsAudioAndCancelsHold() async throws {
        for (name, codec) in [("01.m4a", "aac"), ("01.opus", "libopus")] {
            let window = windowFixture()
            let modes = WindowModeCoordinator(defaults: try windowDefaults())
            let controller = AudioPlayerController()
            let keyboard = WindowKeyboardHandler()
            defer { modes.shutdown(); keyboard.uninstall(); controller.shutdown(); window.close() }
            modes.onWillSwitch = {
                keyboard.cancelPress()
                keyboard.shortcutsSuspended = false
            }
            modes.attach(to: window)
            expectTrue(try await waitForSession { !modes.isTransitioning })
            controller.addFiles([try encodedFixture(name, codec: codec, seconds: 30), try fixture("02.m4a")])
            let a = controller.items[0].id
            controller.load(a, autoplay: false)
            controller.seek(to: 7)
            controller.load(controller.items[1].id, autoplay: false)
            controller.load(a, autoplay: false)

            modes.toggle()
            expectTrue(try await waitForSession { modes.isMini && !modes.isTransitioning })
            expectEqual(controller.currentID, a)
            expectEqual(controller.position, 0)
            expectEqual(controller.pendingResume?.position, 7)
            expectFalse(controller.isPlaying)
            controller.acceptResume()
            expectEqual(controller.position, 7, accuracy: 0.05)
            expectFalse(controller.isPlaying)
            controller.forwardSeconds = 13
            controller.togglePlayback()
            keyboard.pressRight(controller: controller)
            expectTrue(try await waitForSession { controller.isBoosting })
            let beforeSwitch = controller.position
            keyboard.shortcutsSuspended = true
            modes.toggle()
            expectTrue(try await waitForSession { !modes.isMini && !modes.isTransitioning })
            keyboard.releaseRight()
            expectFalse(keyboard.shortcutsSuspended)
            expectFalse(controller.isBoosting)
            expectEqual(controller.playbackRate, Float(1))
            expectTrue(controller.isPlaying)
            expectEqual(controller.currentID, a)
            try await Task.sleep(nanoseconds: 300_000_000)
            expectGreaterThan(controller.position, beforeSwitch)
            expectLessThan(controller.position, beforeSwitch + 3)
            expectNil(controller.pendingResume)
        }
    }

    @MainActor func testMiniWindowSwitchPreservesPendingDrop() async throws {
        let window = windowFixture()
        let modes = WindowModeCoordinator(defaults: try windowDefaults())
        let controller = AudioPlayerController()
        let keyboard = WindowKeyboardHandler()
        defer { modes.shutdown(); keyboard.uninstall(); controller.shutdown(); window.close() }
        modes.onWillSwitch = { keyboard.cancelPress() }
        modes.attach(to: window)
        expectTrue(try await waitForSession { !modes.isTransitioning })
        let gate = DropProviderGate(url: try fixture("小窗拖入.m4a"))
        expectTrue(controller.receiveDroppedFiles([gate.provider]))
        expectTrue(try await waitForSession { gate.wasRequested })
        modes.toggle()
        expectTrue(try await waitForSession { modes.isMini && !modes.isTransitioning })
        expectTrue(controller.fileDrop.isLoading)
        gate.deliver()
        expectTrue(try await waitForSession { !controller.fileDrop.isLoading })
        expectEqual(controller.items.count, 1)
        expectTrue(controller.isPlaying)
        expectEqual(controller.currentItem?.name, "小窗拖入.m4a")
        // This covers shared state; production root-view survival and actual drop targets require GUI QA.
    }

    @MainActor func testMiniWindowRestoresModeAndPausedSession() async throws {
        let defaults = try windowDefaults()
        let store = try sessionStore()
        let window = windowFixture()
        let modes = WindowModeCoordinator(defaults: defaults)
        let original = AudioPlayerController(sessionStore: store)
        defer { modes.shutdown(); original.shutdown(); window.close() }
        modes.attach(to: window)
        expectTrue(try await waitForSession { !modes.isTransitioning })
        await original.restoreSession()
        original.addFiles([try fixture("01.m4a"), try fixture("02.m4a")])
        let a = original.items[0].id
        original.load(a, autoplay: false)
        original.seek(to: 7)
        original.load(original.items[1].id, autoplay: false)
        original.load(a, autoplay: true)
        try await Task.sleep(nanoseconds: 350_000_000)
        original.togglePlayback()
        let actual = original.position
        modes.toggle()
        expectTrue(try await waitForSession { modes.isMini && !modes.isTransitioning })
        expectEqual(original.pendingResume?.position, 7)
        original.shutdown()
        modes.shutdown()
        window.close()

        let restoredWindow = windowFixture()
        let restoredModes = WindowModeCoordinator(defaults: defaults)
        let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        defer { restoredModes.shutdown(); restored.shutdown(); restoredWindow.close() }
        restoredModes.attach(to: restoredWindow)
        await restored.restoreSession()
        expectTrue(try await waitForSession { !restoredModes.isTransitioning })
        expectTrue(restoredModes.isMini)
        expectEqual(restored.currentID, a)
        expectEqual(restored.position, actual, accuracy: 0.1)
        expectEqual(restored.pendingResume?.position, 7)
        expectFalse(restored.isPlaying)
        restored.acceptResume()
        expectEqual(restored.position, 7, accuracy: 0.05)
        expectFalse(restored.isPlaying)
    }

    @MainActor func testMiniWindowShutdownCancelsPendingLayout() async throws {
        let defaults = try windowDefaults()
        let window = windowFixture()
        let modes = WindowModeCoordinator(defaults: defaults)
        defer { modes.shutdown(); window.close() }
        modes.attach(to: window)
        expectTrue(try await waitForSession { !modes.isTransitioning })
        modes.toggle()
        modes.shutdown()
        let stoppedFrame = window.frame
        try await Task.sleep(nanoseconds: 350_000_000)
        expectEqual(window.frame, stoppedFrame)
        expectFalse(window.isVisible)
        let fresh = WindowModeCoordinator(defaults: defaults)
        expectFalse(fresh.isMini)
        fresh.shutdown()
    }

    @MainActor func testMiniWindowNativeFullScreenTimeoutAllowsRetry() async throws {
        let window = windowFixture()
        let modes = WindowModeCoordinator(defaults: try windowDefaults())
        defer { modes.shutdown(); window.close() }
        modes.attach(to: window)
        expectTrue(try await waitForSession { !modes.isTransitioning })

        // Simulate AppKit announcing a native transition whose completion never arrives.
        // The hidden fixture never actually enters a desktop fullscreen space.
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        modes.toggle()
        expectFalse(modes.isMini)

        // Wait for the watchdog's recovery feedback rather than assuming exact scheduling.
        let blockedNotice = modes.notice
        expectTrue(try await waitForSession(timeout: 10) { modes.notice != blockedNotice })
        modes.toggle()
        expectTrue(try await waitForSession(timeout: 1.5) { modes.isMini && !modes.isTransitioning })
        expectFalse(window.isVisible)
    }

    @MainActor func testMiniWindowScreenCorrectionAndInvalidPreferences() throws {
        let primary = NSRect(x: 0, y: 24, width: 1440, height: 876)
        let secondary = NSRect(x: 1440, y: 0, width: 1280, height: 800)
        let compact = NSRect(x: 1800, y: 40, width: 560, height: 96)
        let minimum = NSSize(width: 480, height: 96)
        expectEqual(WindowModeCoordinator.correctedFrame(compact, minimumSize: minimum,
                                                        visibleFrames: [primary, secondary]), compact)
        let afterDisconnect = WindowModeCoordinator.correctedFrame(compact, minimumSize: minimum,
                                                                   visibleFrames: [primary])
        expectTrue(primary.contains(afterDisconnect))
        expectEqual(afterDisconnect.size, compact.size)
        let oversized = WindowModeCoordinator.correctedFrame(
            NSRect(x: -3000, y: -4000, width: 5000, height: 6000),
            minimumSize: minimum, visibleFrames: [primary])
        expectEqual(oversized, primary)
        let invalid = WindowModeCoordinator.correctedFrame(
            NSRect(x: CGFloat.nan, y: 0, width: -1, height: 0),
            minimumSize: minimum, visibleFrames: [primary])
        expectTrue(primary.contains(invalid))
        expectEqual(invalid.size, minimum)

        let defaults = try windowDefaults()
        defaults.set("unknown-mode", forKey: WindowModeCoordinator.PreferenceKey.mode)
        defaults.set([-100, 50, -1, 700], forKey: WindowModeCoordinator.PreferenceKey.mainFrame)
        defaults.set([1, 2], forKey: WindowModeCoordinator.PreferenceKey.miniFrame)
        defaults.set("not-a-boolean", forKey: WindowModeCoordinator.PreferenceKey.pinned)
        let modes = WindowModeCoordinator(defaults: defaults)
        defer { modes.shutdown() }
        expectFalse(modes.isMini)
        expectTrue(modes.isPinned)
        expectGreaterThan(modes.preferredInitialSize.width, 0)
        expectGreaterThan(modes.preferredInitialSize.height, 0)
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
        // Wait for the held action itself; a busy CI executor may start its task late.
        expectTrue(try await waitForSession { controller.isBoosting })
        expectEqual(controller.playbackRate, Float(1.5))
        let beforeRelease = controller.position
        keyboard.releaseRight()
        expectFalse(controller.isBoosting)
        expectEqual(controller.playbackRate, Float(1))
        expectEqual(controller.position, beforeRelease, accuracy: 0.05)
        keyboard.pressRight(controller: controller)
        expectTrue(try await waitForSession { controller.isBoosting })
        let beforeCancel = controller.position
        keyboard.cancelPress()
        keyboard.releaseRight()
        expectEqual(controller.playbackRate, Float(1))
        expectFalse(controller.isBoosting)
        expectEqual(controller.position, beforeCancel, accuracy: 0.05)
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
        // Test crash-recovery transport backup before normal-exit resume archival updates the library digest.
        expectTrue(try await waitForSession {
            guard let data = try? Data(contentsOf: store.checkpointURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? [String: Any] else { return false }
            return state["position"] as? Double == 7
        })
        try Data("corrupt".utf8).write(to: store.checkpointURL)
        let backup = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await backup.restoreSession()
        expectNotNil(backup.sessionNotice)
        expectEqual(backup.position, 2, accuracy: 0.05)
        backup.shutdown()
        controller.shutdown()
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
            let history = Dictionary(uniqueKeysWithValues: entries.map {
                ($0.id, ResumePosition(position: 7, duration: 100))
            })
            let state = SavedSession(items: entries, position: 0, duration: 0, autoAdvance: false,
                                     forwardSeconds: 5, backwardSeconds: 5, holdRate: 2,
                                     resumePositions: history)
            let start = Date()
            expectNil(store.flush(state))
            let written = Date()
            let result = await store.load()
            let end = Date()
            expectEqual(result.session?.items.count, count)
            expectEqual(result.session?.resumePositions.count, count)
            let libraryBytes = try Data(contentsOf: store.fileURL)
            var progress = state
            progress.duration = 100
            for index in 1...12 {
                progress.position = Double(index)
                expectNil(store.flush(progress))
            }
            expectEqual(try Data(contentsOf: store.fileURL), libraryBytes)
            expectLessThan(try Data(contentsOf: store.checkpointURL).count, 2048)
            let checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: store.checkpointURL)) as! [String: Any]
            let transport = checkpoint["state"] as! [String: Any]
            expectNil(transport["resumePositions"])
            let latest = await SessionStore(fileURL: store.fileURL).load()
            expectEqual(latest.session?.position, 12)
            print("  CHECKPOINT bytes=\(try Data(contentsOf: store.checkpointURL).count), library unchanged after 12 updates")
            print("  SESSION \(count) entries with resume history: write=\(written.timeIntervalSince(start))s restore=\(end.timeIntervalSince(written))s bytes=\(try Data(contentsOf: store.fileURL).count)")
        }
    }

    @MainActor func testPerTrackResumeSwitchAndAccept() async throws {
        for (name, codec) in [("01.m4a", "aac"), ("01.opus", "libopus")] {
            let controller = AudioPlayerController()
            defer { controller.shutdown() }
            controller.addFiles([try encodedFixture(name, codec: codec, seconds: 15), try fixture("02.m4a")])
            let a = controller.items[0].id
            let b = controller.items[1].id
            expectTrue(controller.load(a, autoplay: false))
            controller.seek(to: 7)
            expectTrue(controller.load(b, autoplay: false))
            controller.seek(to: 6)
            expectTrue(controller.load(a, autoplay: false))
            expectEqual(controller.pendingResume?.itemID, a)
            expectEqual(controller.pendingResume?.position, 7)
            expectEqual(controller.position, 0)
            controller.acceptResume()
            expectEqual(controller.position, 7, accuracy: 0.05)
            expectFalse(controller.isPlaying)
            expectNil(controller.pendingResume)
            expectTrue(controller.load(b, autoplay: true))
            expectEqual(controller.pendingResume?.itemID, b)
            expectEqual(controller.pendingResume?.position, 6)
            controller.acceptResume()
            expectTrue(controller.isPlaying)
            expectEqual(controller.position, 6, accuracy: 0.15)
            expectNil(controller.pendingResume)
        }
    }

    @MainActor func testPerTrackResumePendingSurvivesSwitchAndRestart() async throws {
        let store = try sessionStore()
        let original = AudioPlayerController(sessionStore: store)
        await original.restoreSession()
        original.addFiles([try fixture("01.m4a"), try fixture("02.m4a")])
        let a = original.items[0].id
        let b = original.items[1].id
        original.load(a, autoplay: false)
        original.seek(to: 7)
        original.load(b, autoplay: false)
        original.load(a, autoplay: true)
        try await Task.sleep(nanoseconds: 400_000_000)
        original.togglePlayback()
        expectEqual(original.pendingResume?.position, 7)
        original.load(b, autoplay: false)
        original.load(a, autoplay: true)
        try await Task.sleep(nanoseconds: 400_000_000)
        original.togglePlayback()
        let actualPosition = original.position
        expectGreaterThan(actualPosition, 0.1)
        expectLessThan(actualPosition, 2)
        expectEqual(original.pendingResume?.position, 7)
        original.shutdown()

        let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await restored.restoreSession()
        defer { restored.shutdown() }
        expectEqual(restored.currentID, a)
        expectFalse(restored.isPlaying)
        expectEqual(restored.position, actualPosition, accuracy: 0.15)
        expectEqual(restored.pendingResume?.itemID, a)
        expectEqual(restored.pendingResume?.position, 7)
        restored.acceptResume()
        expectEqual(restored.position, 7, accuracy: 0.05)
        expectFalse(restored.isPlaying)
        expectNil(restored.pendingResume)
    }

    @MainActor func testPerTrackResumeDismissAndManualSeek() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture("01.m4a"), try fixture("02.m4a")])
        let a = controller.items[0].id
        let b = controller.items[1].id
        controller.load(a, autoplay: false)
        controller.seek(to: 7)
        controller.load(b, autoplay: false)
        controller.load(a, autoplay: false)
        expectEqual(controller.pendingResume?.position, 7)
        controller.dismissResume()
        expectNil(controller.pendingResume)
        expectEqual(controller.position, 0)
        controller.load(b, autoplay: false)
        controller.load(a, autoplay: false)
        expectNil(controller.pendingResume)

        controller.seek(to: 7)
        controller.load(b, autoplay: false)
        controller.load(a, autoplay: false)
        controller.seek(to: 6)
        expectNil(controller.pendingResume)
        controller.load(b, autoplay: false)
        controller.load(a, autoplay: false)
        expectEqual(controller.pendingResume?.position, 6)
        // Short arrow-key jumps use this same controller entry point.
        controller.seek(by: 1)
        expectNil(controller.pendingResume)
        expectEqual(controller.position, 1, accuracy: 0.05)
    }

    @MainActor func testPerTrackResumePeriodicCheckpointProtectsOffer() async throws {
        let store = try sessionStore()
        let original = AudioPlayerController(sessionStore: store)
        await original.restoreSession()
        defer { original.shutdown() }
        original.addFiles([try fixture("01.m4a", seconds: 30), try fixture("02.m4a")])
        let a = original.items[0].id
        original.load(a, autoplay: false)
        original.seek(to: 20)
        original.load(original.items[1].id, autoplay: false)
        original.load(a, autoplay: true)
        expectTrue(try await waitForSession { FileManager.default.fileExists(atPath: store.checkpointURL.path) })
        let library = try Data(contentsOf: store.fileURL)
        expectTrue(try await waitForSession(timeout: 8) {
            guard let data = try? Data(contentsOf: store.checkpointURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? [String: Any], let time = state["position"] as? Double
            else { return false }
            return time > 4.5
        })
        expectEqual(try Data(contentsOf: store.fileURL), library)
        expectEqual(original.pendingResume?.position, 20)
        // Read before a final flush: both positions must survive only the periodic checkpoint.
        let recovered = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await recovered.restoreSession()
        defer { recovered.shutdown() }
        expectFalse(recovered.isPlaying)
        expectGreaterThan(recovered.position, 4.5)
        expectLessThan(recovered.position, 10)
        expectEqual(recovered.pendingResume?.itemID, a)
        expectEqual(recovered.pendingResume?.position, 20)
    }

    @MainActor func testPerTrackResumeFailureRenameAndRemoval() async throws {
        let store = try sessionStore()
        let source = try fixture("01.m4a")
        let bad = source.deletingLastPathComponent().appendingPathComponent("03.m4a")
        try Data("broken audio".utf8).write(to: bad)
        let controller = AudioPlayerController(sessionStore: store)
        await controller.restoreSession()
        controller.addFiles([source, try fixture("02.m4a"), bad])
        let a = controller.items[0].id
        let b = controller.items[1].id
        controller.load(a, autoplay: false)
        controller.seek(to: 7)
        controller.load(b, autoplay: false)
        controller.load(a, autoplay: true)
        expectFalse(controller.load(controller.items[2].id, autoplay: true))
        expectEqual(controller.currentID, a)
        expectTrue(controller.isPlaying)
        expectEqual(controller.pendingResume?.position, 7)
        expectTrue(controller.renameFile(a, to: "改名后仍可续听"))
        expectEqual(controller.currentID, a)
        expectTrue(controller.isPlaying)
        expectEqual(controller.pendingResume?.position, 7)
        controller.load(b, autoplay: false)
        controller.load(a, autoplay: false)
        expectEqual(controller.pendingResume?.position, 7)
        let renamed = controller.currentItem!.url
        controller.selectedID = a
        controller.removeSelected()
        expectNil(controller.pendingResume)
        controller.addFiles([renamed])
        let replacement = controller.items.first { $0.url == renamed }!.id
        expectTrue(replacement != a)
        controller.load(replacement, autoplay: false)
        expectNil(controller.pendingResume)
        controller.shutdown()
        let saved = await SessionStore(fileURL: store.fileURL).load()
        expectNil(saved.session?.resumePositions[a])
        expectTrue(FileManager.default.fileExists(atPath: renamed.path))
    }

    @MainActor func testPerTrackResumeNaturalCatchUpAndCompletion() async throws {
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([try fixture("01.m4a"), try fixture("02.m4a")])
        let a = controller.items[0].id
        let b = controller.items[1].id
        controller.load(a, autoplay: false)
        controller.seek(to: 5)
        controller.load(b, autoplay: false)
        controller.load(a, autoplay: true)
        expectEqual(controller.pendingResume?.position, 5)
        controller.holdRate = 2
        controller.beginBoost()
        expectTrue(try await waitForSession(timeout: 5) {
            controller.position >= 5 && controller.pendingResume == nil
        })
        controller.togglePlayback()
        let caughtUp = controller.position
        controller.load(b, autoplay: false)
        controller.load(a, autoplay: false)
        expectNotNil(controller.pendingResume)
        expectEqual(controller.pendingResume?.position ?? 0, caughtUp, accuracy: 0.15)
        controller.acceptResume()
        controller.seek(to: controller.duration - 0.15)
        controller.togglePlayback()
        expectTrue(try await waitForSession { !controller.isPlaying })
        expectEqual(controller.position, controller.duration)
        controller.load(b, autoplay: false)
        controller.load(a, autoplay: false)
        expectNil(controller.pendingResume)
        expectEqual(controller.position, 0)
    }

    @MainActor func testPerTrackResumeDecoderFailureCanReplayActualPosition() async throws {
        let source = try encodedFixture("01.opus", codec: "libopus", seconds: 30)
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([source, try fixture("02.m4a")])
        let a = controller.items[0].id
        controller.load(a, autoplay: false)
        controller.seek(to: 12)
        controller.load(controller.items[1].id, autoplay: false)
        controller.load(a, autoplay: true)
        controller.holdRate = 2
        controller.beginBoost()
        expectTrue(try await waitForSession(timeout: 6) { controller.position >= 5 })
        controller.endBoost()
        expectEqual(controller.pendingResume?.position, 12)

        // Only terminate this test's direct child decoder for its unique temporary fixture.
        // A bounded decode pipe keeps the 30-second child alive; no production test hook is needed.
        let lookup = Process()
        let identifiers = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        lookup.arguments = ["-P", String(getpid()), "-f", NSRegularExpression.escapedPattern(for: source.path)]
        lookup.standardOutput = identifiers
        try lookup.run()
        let data = identifiers.fileHandleForReading.readDataToEndOfFile()
        lookup.waitUntilExit()
        let pids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        guard lookup.terminationStatus == 0, pids.count == 1, let pid = pids.first else {
            throw NSError(domain: "FixtureDecoderLookup", code: Int(lookup.terminationStatus))
        }
        let inspect = Process()
        let command = Pipe()
        inspect.executableURL = URL(fileURLWithPath: "/bin/ps")
        inspect.arguments = ["-p", String(pid), "-o", "comm="]
        inspect.standardOutput = command
        try inspect.run()
        let executable = String(decoding: command.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        inspect.waitUntilExit()
        guard inspect.terminationStatus == 0, URL(fileURLWithPath: executable).lastPathComponent == "ffmpeg" else {
            throw NSError(domain: "FixtureDecoderIdentity", code: 1)
        }
        guard kill(pid, SIGKILL) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

        expectTrue(try await waitForSession(timeout: 5) { !controller.isPlaying && controller.errorMessage != nil })
        let interruptedPosition = controller.position
        expectGreaterThan(interruptedPosition, 4.9)
        expectLessThan(interruptedPosition, 12)
        expectEqual(controller.currentID, a)
        expectEqual(controller.pendingResume?.position, 12)
        controller.errorMessage = nil
        controller.togglePlayback()
        expectTrue(controller.isPlaying)
        try await Task.sleep(nanoseconds: 650_000_000)
        expectGreaterThan(controller.position, interruptedPosition + 0.15)
        expectLessThan(controller.position, 12)
        expectEqual(controller.pendingResume?.position, 12)
        expectNil(controller.errorMessage)
    }

    @MainActor func testPerTrackResumeChangedFileAndRelocation() async throws {
        let source = try fixture("01.m4a")
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([source, try fixture("02.m4a")])
        let a = controller.items[0].id
        let b = controller.items[1].id
        controller.load(a, autoplay: false)
        controller.seek(to: 7)
        controller.load(b, autoplay: false)
        let shorter = try fixture("short.m4a", seconds: 4)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: shorter, to: source)
        controller.load(a, autoplay: false)
        expectNil(controller.pendingResume)
        expectLessThan(controller.duration, 5)
        let relocated = try fixture("different.m4a")
        controller.relocate(a, to: relocated)
        controller.seek(to: 7)
        controller.load(b, autoplay: false)
        controller.relocate(a, to: try fixture("another.m4a", seconds: 10))
        controller.load(a, autoplay: false)
        expectNil(controller.pendingResume)
        expectEqual(controller.items[0].id, a)
    }

    @MainActor func testResumeSchemaOneMigrationAndMixedSnapshots() async throws {
        let store = try sessionStore()
        let entries = [PlaylistItem(url: try fixture("01.m4a")), PlaylistItem(url: try fixture("02.m4a"))]
        let current = entries[0].id
        let initial = SavedSession(items: entries, selectedID: current, currentID: current,
                                   position: 2, duration: 12, autoAdvance: false,
                                   forwardSeconds: 5, backwardSeconds: 5, holdRate: 2)
        var legacyLibrary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as! [String: Any]
        legacyLibrary["schemaVersion"] = 1
        legacyLibrary.removeValue(forKey: "resumePositions")
        legacyLibrary.removeValue(forKey: "pendingResume")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyLibrary, options: [.sortedKeys])
        try legacyData.write(to: store.fileURL)
        var legacyState = legacyLibrary
        legacyState["items"] = []
        legacyState["position"] = 7
        let digest = SHA256.hash(data: legacyData).map { String(format: "%02x", $0) }.joined()
        var legacyTransport: [String: Any] = ["schemaVersion": 1, "libraryDigest": digest, "state": legacyState]
        try JSONSerialization.data(withJSONObject: legacyTransport).write(to: store.checkpointURL)

        let restored = AudioPlayerController(sessionStore: store)
        await restored.restoreSession()
        expectEqual(restored.currentID, current)
        expectEqual(restored.position, 7, accuracy: 0.05)
        expectFalse(restored.isPlaying)
        expectNil(restored.pendingResume)
        restored.shutdown()
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        expectEqual(written["schemaVersion"] as? Int, 2)
        let migrated = await SessionStore(fileURL: store.fileURL).load()
        expectEqual(migrated.session?.resumePositions[current]?.position, 7)
        expectEqual(migrated.session?.resumePositions.count, 1)

        // A stale v1 transport cannot be applied to a different v2 library digest.
        legacyState["position"] = 9
        legacyTransport["state"] = legacyState
        let staleTransport = try JSONSerialization.data(withJSONObject: legacyTransport)
        try staleTransport.write(to: store.checkpointURL)
        try staleTransport.write(to: store.checkpointBackupURL)
        try legacyData.write(to: store.backupURL)
        let mixed = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await mixed.restoreSession()
        expectEqual(mixed.position, 7, accuracy: 0.05)
        expectFalse(mixed.isPlaying)
        mixed.load(entries[1].id, autoplay: false)
        mixed.load(current, autoplay: false)
        expectEqual(mixed.pendingResume?.position, 7)
        mixed.shutdown()
    }

    @MainActor func testResumeInvalidEntriesDoNotDiscardLibrary() async throws {
        let store = try sessionStore()
        let url = try fixture()
        let entries = (0..<3).map { _ in PlaylistItem(url: url) }
        let history = [entries[0].id: ResumePosition(position: 7, duration: 12),
                       entries[1].id: ResumePosition(position: -1, duration: 12),
                       entries[2].id: ResumePosition(position: 20, duration: 12),
                       UUID(): ResumePosition(position: 7, duration: 12)]
        let state = SavedSession(items: entries, position: 0, duration: 0, autoAdvance: false,
                                 forwardSeconds: 5, backwardSeconds: 5, holdRate: 2,
                                 resumePositions: history)
        expectNil(store.flush(state))
        let restored = await SessionStore(fileURL: store.fileURL).load()
        expectEqual(restored.session?.items.count, 3)
        expectEqual(restored.session?.resumePositions.count, 1)
        expectEqual(restored.session?.resumePositions[entries[0].id]?.position, 7)
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

    @MainActor func testRenameActiveFormatsAndSeek() async throws {
        for (name, codec) in [("track.m4a", "aac"), ("track.mp3", "libmp3lame"),
                              ("track.flac", "flac"), ("track.ogg", "libvorbis"), ("track.opus", "libopus")] {
            let source = try encodedFixture(name, codec: codec)
            let bytes = try Data(contentsOf: source)
            let controller = AudioPlayerController()
            defer { controller.shutdown() }
            controller.addFiles([source, try fixture("z.m4a")])
            let ids = controller.items.map(\.id)
            controller.load(ids[0], autoplay: true)
            controller.seek(to: 2)
            controller.selectedID = ids[1]
            expectTrue(controller.renameFile(ids[0], to: "学习 音频"))
            let renamed = controller.items[0].url
            expectEqual(renamed.lastPathComponent, "学习 音频." + source.pathExtension)
            expectFalse(FileManager.default.fileExists(atPath: source.path))
            expectEqual(try Data(contentsOf: renamed), bytes)
            expectEqual(controller.items.map(\.id), ids)
            expectEqual(controller.currentID, ids[0])
            expectEqual(controller.selectedID, ids[1])
            expectTrue(controller.isPlaying)
            expectEqual(controller.position, 2, accuracy: 0.3)
            controller.seek(to: 4)
            expectTrue(try await waitForSession { controller.position > 4 })
            controller.togglePlayback()
            expectFalse(controller.isPlaying)
            expectGreaterThan(controller.position, 4)
            expectNil(controller.errorMessage)
        }
    }

    @MainActor func testRenamePausedPersistenceAndCaseChange() async throws {
        let store = try sessionStore()
        let source = try fixture("track.m4a")
        let controller = AudioPlayerController(sessionStore: store)
        await controller.restoreSession()
        controller.addFiles([source])
        let id = controller.items[0].id
        controller.load(id, autoplay: false)
        controller.seek(to: 5)
        expectTrue(controller.renameFile(id, to: "TRACK"))
        expectEqual(controller.items[0].name, "TRACK.m4a")
        expectFalse(controller.isPlaying)
        expectEqual(controller.position, 5, accuracy: 0.05)
        controller.shutdown()
        let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await restored.restoreSession()
        expectEqual(restored.items[0].name, "TRACK.m4a")
        expectEqual(restored.currentID, id)
        expectEqual(restored.position, 5, accuracy: 0.05)
        expectFalse(restored.isPlaying)
        restored.seek(to: restored.duration)
        expectTrue(restored.renameFile(id, to: "播放结束"))
        expectEqual(restored.position, restored.duration)
        expectFalse(restored.isPlaying)
        restored.shutdown()
    }

    @MainActor func testRenameCollisionInvalidMissingAndInactive() async throws {
        let source = try fixture("01.m4a")
        let conflict = source.deletingLastPathComponent().appendingPathComponent("exists.m4a")
        let untouched = Data("do not overwrite".utf8)
        try untouched.write(to: conflict)
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([source, try fixture("02.m4a")])
        let id = controller.items[0].id
        controller.load(id, autoplay: true)
        controller.seek(to: 3)
        expectFalse(controller.renameFile(id, to: "exists"))
        expectEqual(try Data(contentsOf: conflict), untouched)
        expectEqual(controller.items[0].url, source)
        expectTrue(controller.isPlaying)
        expectEqual(controller.position, 3, accuracy: 0.1)
        for name in ["", "  ", ".", "..", "bad/name", "bad:name", "bad\nname"] {
            expectFalse(controller.renameFile(id, to: name))
            expectTrue(FileManager.default.fileExists(atPath: source.path))
        }
        expectTrue(controller.renameFile(id, to: "01"))
        expectTrue(controller.renameFile(controller.items[1].id, to: "第二首"))
        expectEqual(controller.currentID, id)
        expectTrue(controller.isPlaying)
        expectEqual(controller.items[1].name, "第二首.m4a")
        try FileManager.default.removeItem(at: controller.items[1].url)
        expectFalse(controller.renameFile(controller.items[1].id, to: "不存在"))
        expectNotNil(controller.errorMessage)
        expectEqual(controller.items[1].name, "第二首.m4a")
    }

    private func dropProvider(_ url: URL) -> NSItemProvider {
        NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
    }

    @MainActor func testDroppedFormatsResumeAndPersistence() async throws {
        for (name, codec) in [("中文 录音.m4a", "aac"), ("song.mp3", "libmp3lame"),
                              ("track.flac", "flac"), ("track.ogg", "libvorbis"), ("track.opus", "libopus")] {
            let url = try encodedFixture(name, codec: codec)
            let controller = AudioPlayerController()
            defer { controller.shutdown() }
            expectTrue(controller.importDroppedFiles([url]))
            expectEqual(controller.items.count, 1)
            expectTrue(controller.isPlaying)
            let id = controller.currentID
            controller.seek(to: 3)
            controller.togglePlayback()
            expectTrue(controller.importDroppedFiles([url, url]))
            expectEqual(controller.items.count, 1)
            expectEqual(controller.currentID, id)
            expectEqual(controller.position, 3, accuracy: 0.1)
            expectTrue(controller.isPlaying)
            expectTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let store = try sessionStore()
        let original = AudioPlayerController(sessionStore: store)
        await original.restoreSession()
        expectTrue(original.importDroppedFiles([try fixture("saved drop.m4a")]))
        original.seek(to: 4)
        original.togglePlayback()
        let id = original.currentID
        original.shutdown()
        let restored = AudioPlayerController(sessionStore: SessionStore(fileURL: store.fileURL))
        await restored.restoreSession()
        expectEqual(restored.items.count, 1)
        expectEqual(restored.currentID, id)
        expectEqual(restored.position, 4, accuracy: 0.1)
        expectFalse(restored.isPlaying)
        restored.shutdown()
    }

    @MainActor func testDroppedBatchOrderDuplicatesAndExistingQueue() async throws {
        let old = try fixture("00-old.m4a")
        let first = try fixture("02-new.m4a")
        let second = try fixture("10-new.m4a")
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([old])
        let originalID = controller.items[0].id
        expectTrue(controller.importDroppedFiles([second, first, first]))
        expectEqual(controller.items.map(\.url), [old, first, second])
        expectEqual(controller.currentID, controller.items[1].id)
        expectEqual(controller.position, 0, accuracy: 0.1)
        expectFalse(controller.autoAdvance)
        let firstID = controller.items[1].id
        controller.playItem(originalID)
        controller.seek(to: 5)
        expectTrue(controller.importDroppedFiles([first]))
        expectEqual(controller.items.count, 3)
        expectEqual(controller.currentID, firstID)
        expectEqual(controller.position, 0, accuracy: 0.1)
        let sameA = try fixture("same.m4a")
        let sameB = try fixture("same.m4a")
        expectTrue(controller.importDroppedFiles([sameB, sameA]))
        expectEqual(controller.items.count, 5)
        expectEqual(Set(controller.items.suffix(2).map(\.url)), Set([sameA, sameB]))
        // Dropping an existing item must use the existing list's next item, not a hidden batch queue.
        let queue = AudioPlayerController()
        defer { queue.shutdown() }
        let short = try fixture("01-short.m4a", seconds: 0.35)
        let existingNext = try fixture("02-existing.m4a")
        let added = try fixture("03-added.m4a")
        queue.addFiles([short, existingNext])
        queue.autoAdvance = true
        let nextID = queue.items[1].id
        expectTrue(queue.importDroppedFiles([added, short]))
        expectTrue(try await waitForSession { queue.currentID == nextID })
        expectTrue(queue.isPlaying)
        expectEqual(queue.items.map(\.url), [short, existingNext, added])
    }

    @MainActor func testDroppedRejectionsAndBadFirstCandidate() async throws {
        let old = try fixture("00-playing.m4a")
        let root = old.deletingLastPathComponent()
        let image = root.appendingPathComponent("photo.png")
        let directory = root.appendingPathComponent("folder.mp3", isDirectory: true)
        let missing = root.appendingPathComponent("missing.m4a")
        try Data("not audio".utf8).write(to: image)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        controller.addFiles([old])
        let oldID = controller.items[0].id
        controller.playItem(oldID)
        controller.seek(to: 2)
        expectFalse(controller.importDroppedFiles([image, directory, missing, URL(string: "https://example.invalid/audio.mp3")!]))
        expectEqual(controller.items.map(\.url), [old])
        expectEqual(controller.currentID, oldID)
        expectTrue(controller.isPlaying)
        expectNotNil(controller.fileDrop.feedback)
        let good = try fixture("02-good.m4a")
        expectTrue(controller.importDroppedFiles([image, good, directory]))
        expectEqual(controller.items.map(\.url), [old, good])
        expectNotNil(controller.fileDrop.feedback)
        controller.playItem(oldID)
        let bad = root.appendingPathComponent("01-broken.m4a")
        try Data("broken".utf8).write(to: bad)
        expectFalse(controller.importDroppedFiles([good, bad]))
        expectEqual(controller.items.count, 3)
        expectEqual(controller.currentID, oldID)
        expectTrue(controller.isPlaying)
        expectNotNil(controller.errorMessage)
        expectTrue(FileManager.default.fileExists(atPath: old.path))
    }

    @MainActor func testDroppedProviderOrderFailureAndAdmission() async throws {
        let first = try fixture("01-first.m4a")
        let second = try fixture("02-second.m4a")
        let firstGate = DropProviderGate(url: first)
        let secondGate = DropProviderGate(url: second)
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        var submissions = 0
        expectTrue(controller.receiveDroppedFiles([secondGate.provider, firstGate.provider], beforePlayback: { submissions += 1 }))
        expectTrue(try await waitForSession { firstGate.wasRequested && secondGate.wasRequested })
        secondGate.deliver()
        expectTrue(controller.fileDrop.isLoading)
        firstGate.deliver()
        expectTrue(try await waitForSession { !controller.fileDrop.isLoading })
        expectEqual(controller.items.map(\.url), [first, second])
        expectEqual(controller.currentID, controller.items[0].id)
        expectTrue(controller.isPlaying)
        expectEqual(submissions, 1)
        let third = try fixture("03-third.m4a")
        let failed = DropProviderGate(fail: true)
        expectTrue(controller.receiveDroppedFiles([failed.provider, dropProvider(third)]))
        expectTrue(try await waitForSession { failed.wasRequested })
        failed.deliver()
        expectTrue(try await waitForSession { !controller.fileDrop.isLoading })
        expectEqual(controller.items.count, 3)
        expectEqual(controller.currentItem?.url, third)
        expectNotNil(controller.fileDrop.feedback)
        let previous = controller.currentID
        expectFalse(controller.receiveDroppedFiles([dropProvider(first)], canAccept: { false }))
        expectFalse(controller.receiveDroppedFiles([NSItemProvider(object: "plain text" as NSString)]))
        expectEqual(controller.currentID, previous)
        expectFalse(controller.fileDrop.isLoading)
    }

    @MainActor func testDroppedLateCallbacksCannotOverrideUserControls() async throws {
        let old = try fixture("existing.m4a")
        let late = try fixture("late.m4a")
        for action in ["pause", "seek", "list"] {
            let controller = AudioPlayerController()
            defer { controller.shutdown() }
            controller.addFiles([old])
            let oldID = controller.items[0].id
            controller.playItem(oldID)
            controller.seek(to: 2)
            let gate = DropProviderGate(url: late)
            var submissions = 0
            expectTrue(controller.receiveDroppedFiles([gate.provider], beforePlayback: { submissions += 1 }))
            expectTrue(try await waitForSession { gate.wasRequested })
            if action == "pause" { controller.togglePlayback() }
            else if action == "seek" { controller.seek(to: 5) }
            else { controller.addFiles([]) }
            expectFalse(controller.fileDrop.isLoading)
            gate.deliver()
            // The callback has been explicitly delivered; allow its main-actor continuation to run.
            try await Task.sleep(nanoseconds: 100_000_000)
            expectEqual(controller.items.map(\.url), [old])
            expectEqual(controller.currentID, oldID)
            expectEqual(submissions, 0)
            if action == "pause" { expectFalse(controller.isPlaying) }
            else { expectTrue(controller.isPlaying) }
        }
    }

    @MainActor func testDroppedNewBatchExitAndLateAdmission() async throws {
        let old = try fixture("old.m4a")
        let newest = try fixture("newest.m4a")
        let staleGate = DropProviderGate(url: old)
        let controller = AudioPlayerController()
        defer { controller.shutdown() }
        expectTrue(controller.receiveDroppedFiles([staleGate.provider]))
        expectTrue(try await waitForSession { staleGate.wasRequested })
        expectTrue(controller.receiveDroppedFiles([dropProvider(newest)]))
        expectTrue(try await waitForSession { !controller.fileDrop.isLoading })
        staleGate.deliver()
        try await Task.sleep(nanoseconds: 100_000_000)
        expectEqual(controller.items.map(\.url), [newest])
        expectTrue(controller.isPlaying)
        let gated = AudioPlayerController()
        defer { gated.shutdown() }
        let gate = DropProviderGate(url: old)
        var canAccept = true
        expectTrue(gated.receiveDroppedFiles([gate.provider], canAccept: { canAccept }))
        expectTrue(try await waitForSession { gate.wasRequested })
        canAccept = false
        gate.deliver()
        expectTrue(try await waitForSession { !gated.fileDrop.isLoading })
        expectTrue(gated.items.isEmpty)
        expectFalse(gated.isPlaying)
        let exiting = AudioPlayerController()
        let exitGate = DropProviderGate(url: old)
        expectTrue(exiting.receiveDroppedFiles([exitGate.provider]))
        expectTrue(try await waitForSession { exitGate.wasRequested })
        exiting.shutdown()
        exitGate.deliver()
        try await Task.sleep(nanoseconds: 100_000_000)
        expectTrue(exiting.items.isEmpty)
        expectNil(exiting.currentID)
        expectFalse(exiting.isPlaying)
        expectFalse(exiting.fileDrop.isLoading)
        expectFalse(exiting.receiveDroppedFiles([dropProvider(old)]))
        let timedOut = FileDropImporter(timeout: 0.1)
        let timeoutGate = DropProviderGate(url: old)
        var timeoutSubmissions = 0
        expectTrue(timedOut.start([timeoutGate.provider]) { _, _ in timeoutSubmissions += 1 })
        expectTrue(try await waitForSession { timeoutGate.wasRequested })
        expectTrue(try await waitForSession { !timedOut.isLoading })
        expectNotNil(timedOut.feedback)
        timeoutGate.deliver()
        try await Task.sleep(nanoseconds: 100_000_000)
        expectEqual(timeoutSubmissions, 0)
    }

    @MainActor func testDroppedLocalReferenceBatchScale() async throws {
        let source = try fixture("source.m4a")
        let manager = FileManager.default
        for count in [100, 1000] {
            let directory = source.deletingLastPathComponent().appendingPathComponent("batch-\(count)", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let urls = try (1...count).map { index -> URL in
                let url = directory.appendingPathComponent(String(format: "%04d-音频.m4a", index))
                try manager.linkItem(at: source, to: url)
                return url
            }
            let providers = urls.reversed().map { dropProvider($0) }
            let controller = AudioPlayerController()
            defer { controller.shutdown() }
            // Provider construction and fixture setup precede the measured app import path.
            let started = ProcessInfo.processInfo.systemUptime
            expectTrue(controller.receiveDroppedFiles(providers))
            // The importer has its own eight-second business timeout; allow that result to arrive.
            expectTrue(try await waitForSession(timeout: 10) { !controller.fileDrop.isLoading })
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            expectEqual(controller.items.count, count)
            expectEqual(controller.items.first?.url, urls.first)
            expectEqual(controller.currentItem?.url, urls.first)
            expectTrue(controller.isPlaying)
            expectNil(controller.errorMessage)
            expectNil(controller.fileDrop.feedback)
            controller.shutdown()
            expectTrue(manager.fileExists(atPath: source.path))
            expectTrue(urls.allSatisfy { manager.fileExists(atPath: $0.path) })
            print("  DROP \(count) local hard-link references via NSItemProvider: import=\(elapsed)s received=\(controller.items.count)")
        }
    }

}
