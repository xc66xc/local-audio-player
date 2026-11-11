import CryptoKit
import Darwin
import Foundation
import OSLog

private enum NcmPreparationLog {
    static let logger = Logger(subsystem: "local.miniaudio.player", category: "NCM")

    static func failure(_ stage: String, id: UUID, detail: String = "") {
        logger.error("[error] [ncm.prepare] id=\(id.uuidString, privacy: .public) stage=\(stage, privacy: .public) detail=\(detail, privacy: .private)")
    }
}

private enum NcmPreparationFailure: String, LocalizedError {
    case invalidSource, sourceChanged, missingTool, temporaryDirectory, launch
    case timeout, processFailed, outputLimit, pipeRead, invalidReport, invalidOutput, outputRead

    var errorDescription: String? {
        switch self {
        case .invalidSource: return "NCM 输入必须是可读取、非空的普通文件。"
        case .sourceChanged: return "准备播放时 NCM 源文件发生变化，请重新打开文件。"
        case .missingTool: return "缺少 NCM 还原工具，请重新安装应用。"
        case .temporaryDirectory: return "无法创建 NCM 播放临时目录，请检查磁盘空间和访问权限。"
        case .launch: return "无法启动 NCM 还原工具，请检查应用安装是否完整。"
        case .timeout: return "NCM 准备播放超时，请检查文件或稍后重试。"
        case .processFailed: return "NCM 还原失败，文件可能已损坏或不受支持。"
        case .outputLimit, .pipeRead: return "NCM 还原工具的输出异常，已停止准备播放。"
        case .invalidReport: return "NCM 还原工具未返回有效结果。"
        case .invalidOutput: return "NCM 还原结果未通过完整性检查，已停止播放。"
        case .outputRead: return "无法读取 NCM 还原结果，请检查磁盘与访问权限。"
        }
    }
}

private struct NcmFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    var modificationTime: TimeInterval {
        Date(timeIntervalSince1970: Double(modifiedSeconds))
            .addingTimeInterval(Double(modifiedNanoseconds) / 1_000_000_000)
            .timeIntervalSince1970
    }
}

private func ncmSourceIdentity(at url: URL) throws -> NcmFileIdentity {
    var info = stat()
    guard url.isFileURL, lstat(url.path, &info) == 0,
          info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else {
        throw NcmPreparationFailure.invalidSource
    }
    return NcmFileIdentity(info)
}

private struct NcmDirectoryMarker: Codable {
    let format: String
    let version: Int
    let ownerPID: Int32
    let ownerID: UUID
    let directoryID: UUID
    let ownerUID: uid_t
    let device: Int64
    let inode: UInt64
}

private final class NcmWeakDirectory {
    weak var value: NcmOwnedDirectory?
    init(_ value: NcmOwnedDirectory) { self.value = value }
}

/// Only this identity-checked, uniquely created directory is removed by a lease.
private final class NcmOwnedDirectory: @unchecked Sendable {
    private static let markerName = ".ncm-player-owner.json"
    private static let markerFormat = "local.miniaudio.player.ncm"
    let url: URL
    private let device: dev_t
    private let inode: ino_t
    private let id: UUID
    private let cleanupLock = NSLock()
    private var removed = false

    init(root: URL, id: UUID, ownerID: UUID) throws {
        self.id = id
        let manager = FileManager.default
        do {
            guard root.isFileURL else { throw NcmPreparationFailure.temporaryDirectory }
            try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let candidate = canonicalRoot.appendingPathComponent("ncm-\(id.uuidString)", isDirectory: true)
            guard mkdir(candidate.path, 0o700) == 0 else {
                throw NcmPreparationFailure.temporaryDirectory
            }
            var info = stat()
            guard lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                // mkdir succeeded; do not sweep other paths if an external actor replaced it.
                NcmPreparationLog.failure("directory-identity", id: id, detail: "errno=\(errno)")
                throw NcmPreparationFailure.temporaryDirectory
            }
            url = candidate
            device = info.st_dev
            inode = info.st_ino
            do {
                let marker = NcmDirectoryMarker(format: Self.markerFormat, version: 1,
                    ownerPID: getpid(), ownerID: ownerID, directoryID: id, ownerUID: geteuid(),
                    device: Int64(info.st_dev), inode: UInt64(info.st_ino))
                try writeMarker(marker)
            } catch {
                cleanup()
                throw error
            }
        } catch {
            NcmPreparationLog.failure("directory-create", id: id, detail: String(describing: error))
            throw NcmPreparationFailure.temporaryDirectory
        }
    }

    private func writeMarker(_ marker: NcmDirectoryMarker) throws {
        let path = url.appendingPathComponent(Self.markerName).path
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NcmPreparationFailure.temporaryDirectory }
        defer {
            if Darwin.close(descriptor) != 0 {
                NcmPreparationLog.failure("marker-close", id: id, detail: "errno=\(errno)")
            }
        }
        let data = try JSONEncoder().encode(marker)
        guard fchmod(descriptor, 0o600) == 0 else { throw NcmPreparationFailure.temporaryDirectory }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw NcmPreparationFailure.temporaryDirectory }
                written += count
            }
        }
        // Publish the ownership proof before starting a helper that creates plaintext.
        guard fsync(descriptor) == 0 else { throw NcmPreparationFailure.temporaryDirectory }
    }

    func cleanup() {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        guard !removed else { return }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno != ENOENT {
                NcmPreparationLog.failure("directory-cleanup-stat", id: id, detail: "errno=\(errno)")
            } else { removed = true }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_dev == device, info.st_ino == inode else {
            NcmPreparationLog.failure("directory-cleanup-identity", id: id)
            removed = true
            return
        }
        do { try FileManager.default.removeItem(at: url); removed = true }
        catch { NcmPreparationLog.failure("directory-cleanup", id: id, detail: String(describing: error)) }
    }

    deinit { cleanup() }

    /// A live or reused PID is deliberately retained. Unmarked/foreign directories
    /// are never inferred to be ours from their names or ages alone.
    static func removeAbandoned(in root: URL) {
        guard root.isFileURL else { return }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_uid == geteuid() else { return }
        let manager = FileManager.default
        guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: { _, error in
                        NcmPreparationLog.failure("recovery-enumerate", id: UUID(), detail: String(describing: error))
                        return true
                    }) else { return }
        for case let candidate as URL in entries {
            let name = candidate.lastPathComponent
            guard name.hasPrefix("ncm-"), let id = UUID(uuidString: String(name.dropFirst(4))) else { continue }
            var directoryInfo = stat()
            guard lstat(candidate.path, &directoryInfo) == 0,
                  directoryInfo.st_mode & S_IFMT == S_IFDIR,
                  directoryInfo.st_mode & 0o777 == 0o700, directoryInfo.st_uid == geteuid() else { continue }
            let markerURL = candidate.appendingPathComponent(markerName)
            let descriptor = Darwin.open(markerURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer {
                if Darwin.close(descriptor) != 0 {
                    NcmPreparationLog.failure("recovery-marker-close", id: id, detail: "errno=\(errno)")
                }
            }
            var markerInfo = stat()
            guard fstat(descriptor, &markerInfo) == 0, markerInfo.st_mode & S_IFMT == S_IFREG,
                  markerInfo.st_mode & 0o777 == 0o600, markerInfo.st_uid == geteuid(),
                  markerInfo.st_nlink == 1, markerInfo.st_size > 0, markerInfo.st_size <= 4096 else { continue }
            var data = Data(count: Int(markerInfo.st_size))
            let bytesRead = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard bytesRead == data.count,
                  let marker = try? JSONDecoder().decode(NcmDirectoryMarker.self, from: data),
                  marker.format == markerFormat, marker.version == 1, marker.directoryID == id,
                  marker.ownerUID == geteuid(), marker.device == Int64(directoryInfo.st_dev),
                  marker.inode == UInt64(directoryInfo.st_ino), marker.ownerPID > 0,
                  Darwin.kill(marker.ownerPID, 0) == -1, errno == ESRCH else { continue }
            var currentDirectory = stat()
            var currentMarker = stat()
            guard lstat(candidate.path, &currentDirectory) == 0,
                  currentDirectory.st_mode & S_IFMT == S_IFDIR,
                  currentDirectory.st_dev == directoryInfo.st_dev, currentDirectory.st_ino == directoryInfo.st_ino,
                  currentDirectory.st_uid == geteuid(), lstat(markerURL.path, &currentMarker) == 0,
                  currentMarker.st_mode & S_IFMT == S_IFREG,
                  NcmFileIdentity(currentMarker) == NcmFileIdentity(markerInfo) else { continue }
            do { try manager.removeItem(at: candidate) }
            catch { NcmPreparationLog.failure("recovery-cleanup", id: id, detail: String(describing: error)) }
        }
    }
}

/// Retain this lease for as long as the native audio player uses its URL.
final class NcmPreparedAudio: @unchecked Sendable {
    let url: URL
    let warnings: [String]
    let sourceSize: Int64
    let sourceModificationTime: TimeInterval
    private let directory: NcmOwnedDirectory
    private let sourceIdentity: NcmFileIdentity
    private let canonicalSource: URL

    fileprivate init(url: URL, warnings: [String], source: NcmFileIdentity,
                     canonicalSource: URL, directory: NcmOwnedDirectory) {
        self.url = url
        self.warnings = warnings
        sourceSize = Int64(source.size)
        sourceModificationTime = source.modificationTime
        sourceIdentity = source
        self.canonicalSource = canonicalSource
        self.directory = directory
    }

    /// Recheck immediately before committing a prepared player on the main actor.
    func validateSource(_ source: URL) throws {
        do {
            guard try ncmSourceIdentity(at: source) == sourceIdentity,
                  try ncmSourceIdentity(at: canonicalSource) == sourceIdentity else {
                throw NcmPreparationFailure.sourceChanged
            }
        } catch {
            NcmPreparationLog.failure("source-changed-before-playback", id: UUID())
            throw NcmPreparationFailure.sourceChanged
        }
    }

    fileprivate func cleanup() { directory.cleanup() }
}

/// Serializes restoration per player; all preparation and hashing run off the main actor.
final class NcmPreparer: @unchecked Sendable {
    private let toolURL: URL?
    private let temporaryRoot: URL
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "local.miniaudio.player.ncm", qos: .userInitiated)
    private let lock = NSLock()
    private let outstanding = DispatchGroup()
    private let ownerID = UUID()
    private var operations: [UUID: NcmPreparationOperation] = [:]
    private var directories: [UUID: NcmWeakDirectory] = [:]
    private var stopped = false

    init(toolURL: URL? = nil, temporaryRoot: URL? = nil, timeout: TimeInterval = 120) {
        self.toolURL = toolURL
        self.temporaryRoot = temporaryRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("local.miniaudio.player-ncm", isDirectory: true)
        self.timeout = timeout
        let recoveryRoot = self.temporaryRoot
        queue.async { NcmOwnedDirectory.removeAbandoned(in: recoveryRoot) }
    }

    func prepare(_ source: URL) async throws -> NcmPreparedAudio {
        let operation = NcmPreparationOperation(source: source, toolURL: toolURL,
            root: temporaryRoot, timeout: timeout, ownerID: ownerID) { [weak self] id, directory in
                guard let self else { directory.cleanup(); return false }
                return self.register(directory, id: id)
            }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !stopped else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                operations[operation.id] = operation
                outstanding.enter()
                lock.unlock()
                queue.async { [self] in
                    var result = Result { try operation.run() }
                    lock.lock()
                    operations.removeValue(forKey: operation.id)
                    let isStopped = stopped
                    lock.unlock()
                    if isStopped, case .success(let prepared) = result {
                        prepared.cleanup()
                        result = .failure(CancellationError())
                    }
                    outstanding.leave()
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private func register(_ directory: NcmOwnedDirectory, id: UUID) -> Bool {
        lock.lock()
        directories = directories.filter { $0.value.value != nil }
        let isStopped = stopped
        if !isStopped { directories[id] = NcmWeakDirectory(directory) }
        lock.unlock()
        if isStopped { directory.cleanup() }
        return !isStopped
    }

    /// Permanently stops this preparer. The caller may synchronously finish app shutdown.
    func cancelAllAndWait() {
        lock.lock()
        stopped = true
        let active = Array(operations.values)
        lock.unlock()
        active.forEach { $0.cancel() }
        // Cancellation escalates independently after 350 ms. Keep a single overall bound,
        // rather than multiplying shutdown delay by the number of queued requests.
        if outstanding.wait(timeout: .now() + 2) == .timedOut {
            active.forEach { $0.forceKill() }
            if outstanding.wait(timeout: .now() + 0.5) == .timedOut {
                NcmPreparationLog.failure("shutdown-wait", id: UUID())
            }
        }
        lock.lock()
        let produced = directories.values.compactMap(\.value)
        directories.removeAll()
        lock.unlock()
        // Successful continuations can still be waiting for the main actor. Do not
        // depend on that actor getting another turn to release its plaintext lease.
        produced.forEach { $0.cleanup() }
    }
}

private struct NcmBatchReport: Decodable {
    let restored: Int
    let skipped: Int
    let failed: Int
    let files: [File]

    struct File: Decodable {
        let inputPath: String
        let outputPath: String?
        let status: String
        let audioFormat: String?
        let audioBytes: Int64?
        let outputSHA256: String?
        let warnings: [String]
        let error: String?

        enum CodingKeys: String, CodingKey {
            case inputPath = "input_path", outputPath = "output_path", status
            case audioFormat = "audio_format", audioBytes = "audio_bytes"
            case outputSHA256 = "output_sha256", warnings, error
        }
    }
}

/// A bounded collector keeps draining after overflow so a noisy child cannot fill a pipe.
/// Nonblocking reads and short poll intervals also handle children that retain pipe FDs.
private final class NcmPipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var bytes = Data()
    private var overflow = false
    private var readFailed = false
    private var stopped = false

    init(handle: FileHandle, limit: Int) throws {
        self.handle = handle
        self.limit = limit
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NcmPreparationFailure.pipeRead
        }
    }

    func start() {
        completion.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                do { try handle.close() }
                catch { NcmPreparationLog.failure("pipe-close", id: UUID(), detail: String(describing: error)) }
                completion.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                lock.lock()
                let shouldStop = stopped
                lock.unlock()
                if shouldStop { return }
                var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    markReadFailure()
                    return
                }
                if ready == 0 { continue }
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count == 0 { return }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    markReadFailure()
                    return
                }
                lock.lock()
                let keep = min(count, limit - bytes.count)
                if keep > 0 { bytes.append(contentsOf: buffer.prefix(keep)) }
                if keep < count { overflow = true }
                lock.unlock()
            }
        }
    }

    private func markReadFailure() {
        lock.lock()
        readFailed = true
        lock.unlock()
    }

    var hasError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflow || readFailed
    }

    func finish() throws -> Data {
        // The native helper closes both streams on exit. A retained writer must not hang us.
        if completion.wait(timeout: .now() + 0.3) == .timedOut {
            stop()
            _ = completion.wait(timeout: .now() + 0.2)
            throw NcmPreparationFailure.pipeRead
        }
        lock.lock()
        defer { lock.unlock() }
        if readFailed { throw NcmPreparationFailure.pipeRead }
        if overflow { throw NcmPreparationFailure.outputLimit }
        return bytes
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private final class NcmPreparationOperation: @unchecked Sendable {
    let id = UUID()
    private let source: URL
    private let toolURL: URL?
    private let root: URL
    private let timeout: TimeInterval
    private let ownerID: UUID
    private let directoryCreated: @Sendable (UUID, NcmOwnedDirectory) -> Bool
    private let condition = NSCondition()
    private var cancelled = false
    private var process: Process?
    private var terminationSent = false

    init(source: URL, toolURL: URL?, root: URL, timeout: TimeInterval, ownerID: UUID,
         directoryCreated: @escaping @Sendable (UUID, NcmOwnedDirectory) -> Bool) {
        self.source = source
        self.toolURL = toolURL
        self.root = root
        self.timeout = timeout
        self.ownerID = ownerID
        self.directoryCreated = directoryCreated
    }

    func cancel() {
        condition.lock()
        cancelled = true
        terminateLocked()
        condition.broadcast()
        condition.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.forceKill()
        }
    }

    func forceKill() {
        condition.lock()
        defer { condition.unlock() }
        if let process, process.isRunning { signalOwned(process, SIGKILL) }
    }

    private func terminateLocked() {
        guard !terminationSent, let process, process.isRunning else { return }
        terminationSent = true
        signalOwned(process, SIGTERM)
    }

    private func signalOwned(_ process: Process, _ signal: Int32) {
        if Darwin.kill(process.processIdentifier, signal) != 0, errno != ESRCH {
            NcmPreparationLog.failure("process-signal", id: id, detail: "signal=\(signal) errno=\(errno)")
        }
    }

    private func checkCancellation() throws {
        condition.lock()
        let isCancelled = cancelled
        condition.unlock()
        if isCancelled { throw CancellationError() }
    }

    func run() throws -> NcmPreparedAudio {
        do {
            try checkCancellation()
            guard timeout.isFinite, timeout > 0 else { throw NcmPreparationFailure.timeout }
            guard source.isFileURL, source.pathExtension.lowercased() == "ncm" else {
                throw NcmPreparationFailure.invalidSource
            }
            let original = try ncmSourceIdentity(at: source)
            let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
            guard try ncmSourceIdentity(at: canonicalSource) == original else {
                throw NcmPreparationFailure.sourceChanged
            }
            let executable: URL
            do { executable = try toolURL ?? DecoderTools.executable("ncm-restore") }
            catch { throw NcmPreparationFailure.missingTool }
            guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw NcmPreparationFailure.missingTool
            }
            try checkCancellation()
            let directory = try NcmOwnedDirectory(root: root, id: id, ownerID: ownerID)
            guard directoryCreated(id, directory) else { throw CancellationError() }
            let json = try runHelper(executable: executable, input: canonicalSource, directory: directory.url)
            try checkCancellation()
            try ensureUnchanged(original, canonicalSource: canonicalSource)
            let report: NcmBatchReport
            do { report = try JSONDecoder().decode(NcmBatchReport.self, from: json) }
            catch { throw NcmPreparationFailure.invalidReport }
            guard report.restored == 1, report.failed == 0, report.skipped == 0,
                  report.files.count == 1, let file = report.files.first,
                  file.status == "restored", file.error == nil,
                  URL(fileURLWithPath: file.inputPath).standardizedFileURL == canonicalSource,
                  let outputPath = file.outputPath, outputPath.hasPrefix("/") else {
                throw NcmPreparationFailure.invalidReport
            }
            let output = URL(fileURLWithPath: outputPath).standardizedFileURL
            try validateOutput(output, report: file, directory: directory.url)
            try checkCancellation()
            try ensureUnchanged(original, canonicalSource: canonicalSource)
            return NcmPreparedAudio(url: output, warnings: file.warnings, source: original,
                                    canonicalSource: canonicalSource, directory: directory)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = (error as? NcmPreparationFailure) ?? .processFailed
            NcmPreparationLog.failure(failure.rawValue, id: id)
            throw failure
        }
    }

    private func ensureUnchanged(_ original: NcmFileIdentity, canonicalSource: URL) throws {
        do {
            guard try ncmSourceIdentity(at: source) == original,
                  try ncmSourceIdentity(at: canonicalSource) == original else {
                throw NcmPreparationFailure.sourceChanged
            }
        } catch { throw NcmPreparationFailure.sourceChanged }
    }

    private func runHelper(executable: URL, input: URL, directory: URL) throws -> Data {
        let helper = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let output = try NcmPipeCollector(handle: stdout.fileHandleForReading, limit: 1_048_576)
        let diagnostic = try NcmPipeCollector(handle: stderr.fileHandleForReading, limit: 65_536)
        helper.executableURL = executable
        helper.environment = ["PATH": "/usr/bin:/bin"]
        helper.arguments = ["--json", "--no-recursive", "-o", directory.path, "--", input.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = stdout
        helper.standardError = stderr
        output.start()
        diagnostic.start()
        defer { output.stop(); diagnostic.stop() }
        // These handles belong to the parent. Closing them is required for collector EOF.
        var writersClosed = false
        func closeWriters() {
            guard !writersClosed else { return }
            writersClosed = true
            do { try stdout.fileHandleForWriting.close() }
            catch { NcmPreparationLog.failure("stdout-close", id: id, detail: String(describing: error)) }
            do { try stderr.fileHandleForWriting.close() }
            catch { NcmPreparationLog.failure("stderr-close", id: id, detail: String(describing: error)) }
        }
        defer { closeWriters() }
        condition.lock()
        guard !cancelled else { condition.unlock(); throw CancellationError() }
        process = helper
        do { try helper.run() }
        catch {
            process = nil
            condition.unlock()
            NcmPreparationLog.failure("process-launch", id: id, detail: String(describing: error))
            throw NcmPreparationFailure.launch
        }
        condition.unlock()
        // Process does not need these parent writer references after spawn.
        closeWriters()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stoppedAt: TimeInterval?
        var timedOut = false
        var pipeError = false
        while helper.isRunning {
            let now = ProcessInfo.processInfo.systemUptime
            condition.lock()
            if now >= deadline { timedOut = true }
            if output.hasError || diagnostic.hasError { pipeError = true }
            if cancelled || timedOut || pipeError {
                if stoppedAt == nil { stoppedAt = now }
                terminateLocked()
                if let stoppedAt, now - stoppedAt >= 0.35, helper.isRunning {
                    signalOwned(helper, SIGKILL)
                }
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.025))
            condition.unlock()
        }
        condition.lock()
        process = nil
        condition.unlock()
        // No waitUntilExit or unbounded read is used on any path.
        try checkCancellation()
        if timedOut { throw NcmPreparationFailure.timeout }
        let data = try output.finish()
        _ = try diagnostic.finish()
        guard helper.terminationReason == .exit, helper.terminationStatus == 0 else {
            NcmPreparationLog.failure("process-exit", id: id, detail: "status=\(helper.terminationStatus)")
            throw NcmPreparationFailure.processFailed
        }
        return data
    }

    private func validateOutput(_ output: URL, report: NcmBatchReport.File, directory: URL) throws {
        let prefix = directory.path + "/"
        let ext = output.pathExtension.lowercased()
        guard output.path.hasPrefix(prefix), output.resolvingSymlinksInPath().path.hasPrefix(prefix),
              ["mp3", "flac"].contains(ext), report.audioFormat == ext,
              let expectedSize = report.audioBytes, expectedSize > 0,
              let expectedDigest = report.outputSHA256?.lowercased(), expectedDigest.count == 64,
              expectedDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NcmPreparationFailure.invalidOutput
        }
        // Reject symlinks in every output component, including intermediary directories.
        var component = directory
        for name in output.pathComponents.dropFirst(directory.pathComponents.count) {
            component.appendPathComponent(name)
            var info = stat()
            guard lstat(component.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
                throw NcmPreparationFailure.invalidOutput
            }
        }
        let descriptor = Darwin.open(output.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NcmPreparationFailure.outputRead }
        defer {
            if Darwin.close(descriptor) != 0 {
                NcmPreparationLog.failure("output-close", id: id, detail: "errno=\(errno)")
            }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size == expectedSize,
              fchmod(descriptor, 0o600) == 0, fstat(descriptor, &info) == 0 else {
            throw NcmPreparationFailure.invalidOutput
        }
        let original = NcmFileIdentity(info)
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total: Int64 = 0
        while true {
            try checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw NcmPreparationFailure.outputRead
            }
            if count == 0 { break }
            total += Int64(count)
            guard total <= expectedSize else { throw NcmPreparationFailure.invalidOutput }
            buffer.withUnsafeBytes {
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count]))
            }
        }
        let actualDigest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        var finalInfo = stat()
        var pathInfo = stat()
        guard total == expectedSize, actualDigest == expectedDigest,
              fstat(descriptor, &finalInfo) == 0, NcmFileIdentity(finalInfo) == original,
              lstat(output.path, &pathInfo) == 0, pathInfo.st_mode & S_IFMT == S_IFREG,
              NcmFileIdentity(pathInfo) == original else { throw NcmPreparationFailure.invalidOutput }
    }
}
