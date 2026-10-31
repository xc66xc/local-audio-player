import Foundation
import OSLog

struct PlaylistItem: Identifiable, Hashable, Codable {
    let id: UUID
    let url: URL
    var bookmark: Data?
    // Availability is a runtime observation, not a permanently saved error.
    var isUnavailable = false
    enum CodingKeys: String, CodingKey { case id, url, bookmark }
    var name: String { url.lastPathComponent }

    init(url: URL, id: UUID = UUID()) {
        self.id = id
        self.url = url.standardizedFileURL
        do { bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch {
            Logger(subsystem: "local.miniaudio.player", category: "Session")
                .error("[error] [session.bookmark] \(String(describing: error), privacy: .private)")
        }
    }

    func resolvingReference() -> PlaylistItem {
        var resolved = self
        if let bookmark {
            do {
                var stale = false
                let found = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                    relativeTo: nil, bookmarkDataIsStale: &stale)
                resolved = PlaylistItem(url: found, id: id)
            } catch {
                Logger(subsystem: "local.miniaudio.player", category: "Session")
                    .error("[error] [session.resolve] \(String(describing: error), privacy: .private)")
            }
        }
        resolved.isUnavailable = !FileManager.default.isReadableFile(atPath: resolved.url.path)
        return resolved
    }
}

enum PlaybackRules {
    static func position(_ value: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard value.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(value, 0), duration)
    }

    static func nextID(after id: UUID, in items: [PlaylistItem], autoAdvance: Bool) -> UUID? {
        guard autoAdvance, let index = items.firstIndex(where: { $0.id == id }),
              index + 1 < items.count else { return nil }
        return items[index + 1].id
    }

    static func timeLabel(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.isFinite ? time : 0))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
