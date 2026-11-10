import Foundation
import CryptoKit
import OSLog

struct ResumePosition: Codable, Equatable {
    var position: TimeInterval
    var duration: TimeInterval
    var fileSize: Int64? = nil
    var modificationTime: TimeInterval? = nil
}

struct PendingResume: Codable, Equatable {
    var itemID: UUID
    var position: TimeInterval
}

private enum SessionRecordLog {
    static let logger = Logger(subsystem: "local.miniaudio.player", category: "Session")

    static func discarded(_ field: String) {
        logger.error("[error] [session.resume] discarded invalid \(field, privacy: .public)")
    }
}

struct SavedSession: Codable {
    var schemaVersion = 2
    var items: [PlaylistItem]
    var selectedID: UUID?
    var currentID: UUID?
    var position: TimeInterval
    var duration: TimeInterval
    var autoAdvance: Bool
    var forwardSeconds: Int
    var backwardSeconds: Int
    var holdRate: Float
    var resumePositions: [UUID: ResumePosition] = [:]
    var pendingResume: PendingResume? = nil

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, items, selectedID, currentID, position, duration
        case autoAdvance, forwardSeconds, backwardSeconds, holdRate, resumePositions, pendingResume
    }

    func validated() throws -> SavedSession {
        guard schemaVersion <= 2 else { throw SessionStore.Failure.unsupportedVersion }
        guard schemaVersion >= 1 else { throw SessionStore.Failure.invalidState }
        let ids = Set(items.map(\.id))
        guard ids.count == items.count, items.allSatisfy({ $0.url.isFileURL }),
              selectedID.map({ ids.contains($0) }) ?? true,
              currentID.map({ ids.contains($0) }) ?? true,
              position.isFinite, duration.isFinite, position >= 0, duration >= 0,
              position <= duration, (1...600).contains(forwardSeconds),
              (1...600).contains(backwardSeconds), [Float(1.25), 1.5, 1.75, 2].contains(holdRate)
        else { throw SessionStore.Failure.invalidState }
        var result = self
        result.resumePositions = [:]
        for (id, value) in resumePositions {
            guard ids.contains(id), value.position.isFinite, value.duration.isFinite,
                  value.position >= 5, value.position < value.duration else {
                SessionRecordLog.discarded("resume position")
                continue
            }
            var normalized = value
            if let size = value.fileSize, size < 0 {
                normalized.fileSize = nil
                SessionRecordLog.discarded("file size")
            }
            if let time = value.modificationTime, !time.isFinite {
                normalized.modificationTime = nil
                SessionRecordLog.discarded("modification time")
            }
            result.resumePositions[id] = normalized
        }
        if let pending = pendingResume,
           pending.itemID != currentID || !pending.position.isFinite || pending.position < 5 || pending.position >= duration {
            result.pendingResume = nil
            SessionRecordLog.discarded("pending resume")
        }
        return result
    }
}

extension SavedSession {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        items = try values.decode([PlaylistItem].self, forKey: .items)
        selectedID = try values.decodeIfPresent(UUID.self, forKey: .selectedID)
        currentID = try values.decodeIfPresent(UUID.self, forKey: .currentID)
        position = try values.decode(TimeInterval.self, forKey: .position)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        autoAdvance = try values.decode(Bool.self, forKey: .autoAdvance)
        forwardSeconds = try values.decode(Int.self, forKey: .forwardSeconds)
        backwardSeconds = try values.decode(Int.self, forKey: .backwardSeconds)
        holdRate = try values.decode(Float.self, forKey: .holdRate)
        if values.contains(.resumePositions) {
            do {
                let records = try values.decode([String: DecodedResumePosition].self, forKey: .resumePositions)
                for (key, record) in records {
                    guard let id = UUID(uuidString: key), let value = record.value else {
                        SessionRecordLog.discarded("resume entry")
                        continue
                    }
                    resumePositions[id] = value
                }
            } catch {
                SessionRecordLog.discarded("resume positions")
            }
        }
        do { pendingResume = try values.decodeIfPresent(PendingResume.self, forKey: .pendingResume) }
        catch { SessionRecordLog.discarded("pending resume") }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(items, forKey: .items)
        try values.encodeIfPresent(selectedID, forKey: .selectedID)
        try values.encodeIfPresent(currentID, forKey: .currentID)
        try values.encode(position, forKey: .position)
        try values.encode(duration, forKey: .duration)
        try values.encode(autoAdvance, forKey: .autoAdvance)
        try values.encode(forwardSeconds, forKey: .forwardSeconds)
        try values.encode(backwardSeconds, forKey: .backwardSeconds)
        try values.encode(holdRate, forKey: .holdRate)
        let records = Dictionary(uniqueKeysWithValues: resumePositions.map { ($0.key.uuidString, $0.value) })
        try values.encode(records, forKey: .resumePositions)
        try values.encodeIfPresent(pendingResume, forKey: .pendingResume)
    }
}

/// A malformed record must not prevent decoding unrelated records or the playlist.
private struct DecodedResumePosition: Decodable {
    let value: ResumePosition?

    init(from decoder: Decoder) throws {
        do { value = try ResumePosition(from: decoder) }
        catch {
            value = nil
            SessionRecordLog.discarded("resume record")
        }
    }
}

/// Small transport checkpoints reference the exact library snapshot they belong to.
/// A crash between library and checkpoint writes cannot apply an old position to a new list.
private struct SessionCheckpoint: Codable {
    var schemaVersion = 2
    let libraryDigest: String
    var state: TransportState

    init(libraryDigest: String, session: SavedSession) {
        self.libraryDigest = libraryDigest
        state = TransportState(session)
    }

    func applying(to library: SavedSession) throws -> SavedSession {
        guard state.schemaVersion <= 2 else { throw SessionStore.Failure.unsupportedVersion }
        guard state.schemaVersion >= 1 else { throw SessionStore.Failure.invalidState }
        var result = library
        result.selectedID = state.selectedID
        result.currentID = state.currentID
        result.position = state.position
        result.duration = state.duration
        result.autoAdvance = state.autoAdvance
        result.forwardSeconds = state.forwardSeconds
        result.backwardSeconds = state.backwardSeconds
        result.holdRate = state.holdRate
        result.pendingResume = state.pendingResume
        return try result.validated()
    }
}

/// Deliberately excludes both file bookmarks and the archived per-item resume map.
private struct TransportState: Codable {
    var schemaVersion: Int
    var selectedID: UUID?
    var currentID: UUID?
    var position: TimeInterval
    var duration: TimeInterval
    var autoAdvance: Bool
    var forwardSeconds: Int
    var backwardSeconds: Int
    var holdRate: Float
    var pendingResume: PendingResume?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selectedID, currentID, position, duration
        case autoAdvance, forwardSeconds, backwardSeconds, holdRate, pendingResume
    }

    init(_ session: SavedSession) {
        schemaVersion = session.schemaVersion
        selectedID = session.selectedID
        currentID = session.currentID
        position = session.position
        duration = session.duration
        autoAdvance = session.autoAdvance
        forwardSeconds = session.forwardSeconds
        backwardSeconds = session.backwardSeconds
        holdRate = session.holdRate
        pendingResume = session.pendingResume
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        selectedID = try values.decodeIfPresent(UUID.self, forKey: .selectedID)
        currentID = try values.decodeIfPresent(UUID.self, forKey: .currentID)
        position = try values.decode(TimeInterval.self, forKey: .position)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        autoAdvance = try values.decode(Bool.self, forKey: .autoAdvance)
        forwardSeconds = try values.decode(Int.self, forKey: .forwardSeconds)
        backwardSeconds = try values.decode(Int.self, forKey: .backwardSeconds)
        holdRate = try values.decode(Float.self, forKey: .holdRate)
        do { pendingResume = try values.decodeIfPresent(PendingResume.self, forKey: .pendingResume) }
        catch {
            pendingResume = nil
            SessionRecordLog.discarded("pending resume")
        }
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
    private var needsSchemaMigration = false

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
        let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
        guard version <= 2 else { throw Failure.unsupportedVersion }
        guard version >= 1 else { throw Failure.invalidState }
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
                    if session.schemaVersion == 1 {
                        // Merge the digest-matched v1 transport before seeding its only known history.
                        session = migrateLegacy(session)
                        needsSchemaMigration = true
                        logger.info("[session.migrate] schema=1 target=2")
                    }
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

    private func migrateLegacy(_ session: SavedSession) -> SavedSession {
        var result = session
        result.schemaVersion = 2
        if let id = session.currentID, session.position >= 5, session.position < session.duration {
            result.resumePositions[id] = ResumePosition(position: session.position, duration: session.duration)
        }
        return result
    }

    private func write(_ session: SavedSession) -> String? {
        guard !writeBlocked else { return nil }
        do {
            // Full validation is needed when the library changes. Checkpoints reuse those IDs.
            var session = try session.validated()
            if session.schemaVersion == 1 { session = migrateLegacy(session) }
            let libraryChanged = lastLibrary?.items != session.items || lastLibrary?.resumePositions != session.resumePositions
            if libraryChanged || needsLibraryRepair || needsSchemaMigration {
                let data = try encode(session)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (lastGoodData ?? data).write(to: backupURL, options: .atomic)
                try data.write(to: fileURL, options: .atomic)
                lastGoodData = data
                lastLibrary = session
                libraryDigest = digest(data)
                needsLibraryRepair = false
                needsSchemaMigration = false
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
