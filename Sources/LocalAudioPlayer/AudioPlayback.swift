import AVFAudio
import Foundation
import UniformTypeIdentifiers
import OSLog

@MainActor
protocol AudioPlayback: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var rate: Float { get set }
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: AudioPlayback {}

enum AudioFileTypes {
    static let extensions = ["mp3", "m4a", "aac", "adts", "wav", "flac", "aif", "aiff", "aifc", "ogg", "oga", "opus", "m4b", "caf"]
    static var contentTypes: [UTType] {
        extensions.compactMap { UTType(tag: $0, tagClass: .filenameExtension, conformingTo: .audio) }
    }

    static func isOgg(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 4)) == Data("OggS".utf8)
    }
}

enum DecoderTools {
    enum Failure: Error { case missingTool, unsupportedAudio, decoderFailed }

    static func executable(_ name: String) throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        // Source builds/tests use the same pinned helpers as the distributed application.
        if Bundle.main.bundleURL.pathExtension != "app" {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let local = root.appendingPathComponent(".build/decoder/bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: local.path) { return local }
        }
        throw Failure.missingTool
    }

    static func duration(of url: URL) throws -> Double {
        guard url.isFileURL else { throw Failure.unsupportedAudio }
        let process = Process()
        let output = Pipe()
        process.executableURL = try executable("ffprobe")
        process.arguments = ["-v", "error", "-probesize", "1048576", "-analyzeduration", "3000000",
                             "-select_streams", "a:0", "-show_entries", "format=duration:stream=codec_name",
                             "-of", "json", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let streams = json?["streams"] as? [[String: Any]]
        let codec = streams?.first?["codec_name"] as? String
        let format = json?["format"] as? [String: Any]
        guard process.terminationStatus == 0, ["vorbis", "opus"].contains(codec ?? ""),
              let string = format?["duration"] as? String, let duration = Double(string),
              duration.isFinite, duration > 0 else { throw Failure.unsupportedAudio }
        return duration
    }
}

// Serialize list probes instead of starting one child process per row at once.
actor OggMetadata {
    static let shared = OggMetadata()
    func duration(of url: URL) throws -> Double {
        try Task.checkCancellation()
        return try DecoderTools.duration(of: url)
    }
}

// AVAudioPlayer remains the native path. Ogg uses a bounded PCM queue and time pitch
// so seeking and temporary speed work even on systems without an Ogg importer.
@MainActor
final class StreamAudioPlayer: AudioPlayback {
    let duration: TimeInterval
    var finished: ((Bool) -> Void)?
    private let url: URL
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var session: PCMDecodeSession?
    private var anchor: Double = 0
    private var pausedPosition: Double?
    private var playing = false

    var rate: Float {
        get { pitch.rate }
        set { pitch.rate = min(max(newValue, 1), 2) }
    }
    var currentTime: TimeInterval {
        get {
            if !playing { return pausedPosition ?? anchor }
            guard session != nil, let render = node.lastRenderTime,
                  let time = node.playerTime(forNodeTime: render) else { return anchor }
            return min(duration, anchor + Double(time.sampleTime) / time.sampleRate)
        }
        set {
            let resume = playing
            stopSession()
            anchor = min(max(newValue, 0), duration)
            if resume && !play() { finished?(false) }
        }
    }

    init(url: URL) throws {
        self.url = url
        duration = try DecoderTools.duration(of: url)
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func play() -> Bool {
        do {
            if anchor >= duration { anchor = 0 }
            if !engine.isRunning { try engine.start() }
            if session == nil {
                let next = try PCMDecodeSession(url: url, offset: anchor, node: node, format: format)
                session = next
                next.start { [weak self, weak next] success in
                    Task { @MainActor [weak self, weak next] in
                        guard let self, let next, self.session === next else { return }
                        self.stopSession()
                        self.anchor = self.duration
                        self.finished?(success)
                    }
                }
            }
            node.play()
            playing = true
            return true
        } catch {
            Logger(subsystem: "local.miniaudio.player", category: "Decoder")
                .error("Ogg playback failed: \(String(describing: error), privacy: .private)")
            stopSession()
            return false
        }
    }

    func pause() {
        pausedPosition = currentTime
        node.pause()
        engine.pause()
        playing = false
    }
    func stop() { stopSession(); anchor = 0; engine.stop() }

    private func stopSession() {
        session?.cancel()
        session = nil
        node.stop()
        engine.pause()
        playing = false
        pausedPosition = nil
    }
}

private final class PCMDecodeSession: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let node: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let slots = DispatchSemaphore(value: 8)
    private let lock = NSLock()
    private var cancelled = false

    init(url: URL, offset: Double, node: AVAudioPlayerNode, format: AVAudioFormat) throws {
        self.node = node
        self.format = format
        process.executableURL = try DecoderTools.executable("ffmpeg")
        process.arguments = ["-nostdin", "-v", "error", "-threads", "1", "-ss", String(offset),
                             "-i", url.path, "-map", "0:a:0", "-vn", "-sn", "-dn",
                             "-ac", "2", "-ar", "48000", "-c:a", "pcm_f32le", "-f", "f32le", "pipe:1"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
        // Wake the producer when paused with the entire bounded queue full.
        for _ in 0..<9 { slots.signal() }
    }

    func start(completed: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { try? pipe.fileHandleForReading.close() }
            do {
                while true {
                    slots.wait()
                    lock.lock()
                    let stopped = cancelled
                    lock.unlock()
                    if stopped { return }
                    var data = Data()
                    while data.count < 8192 * 8 {
                        guard let part = try pipe.fileHandleForReading.read(upToCount: 8192 * 8 - data.count),
                              !part.isEmpty else { break }
                        data.append(part)
                    }
                    if data.isEmpty {
                        process.waitUntilExit()
                        let success = process.terminationStatus == 0
                        let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
                        tail.frameLength = 1
                        tail.floatChannelData![0][0] = 0
                        tail.floatChannelData![1][0] = 0
                        lock.lock()
                        if !cancelled {
                            node.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { _ in completed(success) }
                        }
                        lock.unlock()
                        return
                    }
                    guard data.count % 8 == 0,
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 8)) else {
                        throw DecoderTools.Failure.decoderFailed
                    }
                    buffer.frameLength = buffer.frameCapacity
                    data.withUnsafeBytes { bytes in
                        let samples = bytes.bindMemory(to: Float.self)
                        for frame in 0..<Int(buffer.frameLength) {
                            buffer.floatChannelData![0][frame] = samples[frame * 2]
                            buffer.floatChannelData![1][frame] = samples[frame * 2 + 1]
                        }
                    }
                    lock.lock()
                    if !cancelled {
                        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [slots] _ in slots.signal() }
                    }
                    let stoppedAfterRead = cancelled
                    lock.unlock()
                    if stoppedAfterRead { return }
                }
            } catch {
                lock.lock()
                let stopped = cancelled
                lock.unlock()
                if !stopped { completed(false) }
            }
        }
    }
}
