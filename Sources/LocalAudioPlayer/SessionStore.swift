import Foundation
import CryptoKit
import OSLog

struct SavedSession: Codable {
    var schemaVersion = 1
    var items: [PlaylistItem]
    var selectedID: UUID?
    var currentID: UUID?
    var position: TimeInterval
    var duration: TimeInterval
    var autoAdvance: Bool
    var forwardSeconds: Int
    var backwardSeconds: Int
    var holdRate: Float

    func validated() throws -> SavedSession {
        guard schemaVersion == 1 else { throw SessionStore.Failure.unsupportedVersion }
        let ids = Set(items.map(\.id))
        guard ids.count == items.count, items.allSatisfy({ $0.url.isFileURL }),
              selectedID.map({ ids.contains($0) }) ?? true,
              currentID.map({ ids.contains($0) }) ?? true,
              position.isFinite, duration.isFinite, position >= 0, duration >= 0,
              position <= duration, (1...600).contains(forwardSeconds),
              (1...600).contains(backwardSeconds), [Float(1.25), 1.5, 1.75, 2].contains(holdRate)
        else { throw SessionStore.Failure.invalidState }
        return self
    }
}

/// Small transport checkpoints reference the exact library snapshot they belong to.
/// A crash between library and checkpoint writes cannot apply an old position to a new list.
private struct SessionCheckpoint: Codable {
    var schemaVersion = 1
    let libraryDigest: String
    var state: SavedSession

    init(libraryDigest: String, session: SavedSession) {
        self.libraryDigest = libraryDigest
        state = session
        state.items = []
    }

    func applying(to library: SavedSession) throws -> SavedSession {
        var result = state
        result.items = library.items
        return try result.validated()
    }
}

/// All disk operations use one queue; final writes wait behind pending writes before exit.
final class SessionStore: @unchecked Sendable {
    enum Failure: Error { case unsupportedVersion, invalidState }
    struct Restoration {
        var session: SavedSession?
        var notice: String?
    }

    let fileURL: URL
    var backupURL: URL { fileURL.appendingPathExtension("backup") }
    var checkpointURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("transport.json") }
    var checkpointBackupURL: URL { checkpointURL.appendingPathExtension("backup") }
    private let queue = DispatchQueue(label: "local.miniaudio.player.session", qos: .utility)
    private let logger = Logger(subsystem: "local.miniaudio.player", category: "Session")
    private var lastGoodData: Data?
    private var lastLibrary: SavedSession?
    private var libraryDigest = ""
    private var lastCheckpointData: Data?
    private var writeBlocked = false
    private var needsLibraryRepair = false
    private var needsCheckpointRepair = false

    static func applicationStore() -> SessionStore {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.miniaudio.player", isDirectory: true)
        return SessionStore(fileURL: directory.appendingPathComponent("session.json"))
    }

    init(fileURL: URL) { self.fileURL = fileURL }

    func load() async -> Restoration {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.read()) }
        }
    }

    private func checkVersion(_ data: Data) throws {
        struct Header: Decodable { let schemaVersion: Int }
        guard try JSONDecoder().decode(Header.self, from: data).schemaVersion == 1 else {
            throw Failure.unsupportedVersion
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func read() -> Restoration {
        var recovered = false
        do {
            // Protect every newer file, even when its companion is missing/corrupt or
            // a readable primary would otherwise let us return before checking a backup.
            for url in [fileURL, backupURL, checkpointURL, checkpointBackupURL]
                where FileManager.default.fileExists(atPath: url.path) {
                do { try checkVersion(Data(contentsOf: url)) }
                catch Failure.unsupportedVersion { throw Failure.unsupportedVersion }
                catch {
                    logger.error("[error] [session.preflight] \(String(describing: error), privacy: .private)")
                }
            }
            for url in [fileURL, backupURL] {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    let data = try Data(contentsOf: url)
                    try checkVersion(data)
                    var session = try JSONDecoder().decode(SavedSession.self, from: data).validated()
                    needsLibraryRepair = url == backupURL
                    recovered = recovered || needsLibraryRepair
                    lastGoodData = data
                    lastLibrary = session
                    libraryDigest = digest(data)
                    let transport = try readCheckpoint(for: session)
                    session = transport.session ?? session
                    recovered = recovered || transport.recovered
                    session.items = session.items.map { $0.resolvingReference() }
                    logger.info("[session.restore] count=\(session.items.count) backup=\(recovered)")
                    return Restoration(session: session, notice: recovered ? "部分播放记录无法读取，已恢复最近的有效记录，进度可能较早。" : nil)
                } catch Failure.unsupportedVersion { throw Failure.unsupportedVersion }
                catch {
                    logger.error("[error] [session.restore] \(String(describing: error), privacy: .private)")
                    recovered = true
                }
            }
        } catch {
            writeBlocked = true
            logger.error("[error] [session.restore] unsupported schema; writes disabled")
            return Restoration(notice: "播放记录来自更新版本，当前版本无法读取。原记录已保留，本次不会覆盖它。")
        }
        return Restoration(notice: recovered ? "播放记录及备份无法读取，本次使用默认状态。" : nil)
    }

    private func readCheckpoint(for library: SavedSession) throws -> (session: SavedSession?, recovered: Bool) {
        var recovered = false
        for url in [checkpointURL, checkpointBackupURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                try checkVersion(data)
                let checkpoint = try JSONDecoder().decode(SessionCheckpoint.self, from: data)
                // An intact checkpoint from an older list is expected after an interrupted save.
                guard checkpoint.libraryDigest == libraryDigest else { continue }
                let result = try checkpoint.applying(to: library)
                lastCheckpointData = data
                needsCheckpointRepair = url == checkpointBackupURL
                return (result, recovered || needsCheckpointRepair)
            } catch Failure.unsupportedVersion { throw Failure.unsupportedVersion }
            catch {
                logger.error("[error] [session.checkpoint] \(String(describing: error), privacy: .private)")
                recovered = true
                needsCheckpointRepair = true
            }
        }
        return (nil, recovered)
    }

    func save(_ session: SavedSession, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { completion(self.write(session)) }
    }

    /// Called only at termination or by tests, never on every progress tick.
    func flush(_ session: SavedSession) -> String? { queue.sync { write(session) } }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func write(_ session: SavedSession) -> String? {
        guard !writeBlocked else { return nil }
        do {
            // Full validation is needed when the library changes. Checkpoints reuse those IDs.
            _ = try session.validated()
            let libraryChanged = lastLibrary?.items != session.items
            if libraryChanged || needsLibraryRepair {
                let data = try encode(session)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (lastGoodData ?? data).write(to: backupURL, options: .atomic)
                try data.write(to: fileURL, options: .atomic)
                lastGoodData = data
                lastLibrary = session
                libraryDigest = digest(data)
                needsLibraryRepair = false
                // Old checkpoints remain harmless: they carry the previous library digest.
                lastCheckpointData = nil
            }
            let data = try encode(SessionCheckpoint(libraryDigest: libraryDigest, session: session))
            guard data != lastCheckpointData || needsCheckpointRepair else { return nil }
            try (lastCheckpointData ?? data).write(to: checkpointBackupURL, options: .atomic)
            try data.write(to: checkpointURL, options: .atomic)
            lastCheckpointData = data
            needsCheckpointRepair = false
            return nil
        } catch {
            logger.error("[error] [session.save] \(String(describing: error), privacy: .private)")
            return "播放记录保存失败，请检查磁盘空间与访问权限。退出后可能无法恢复最新状态。"
        }
    }
}
