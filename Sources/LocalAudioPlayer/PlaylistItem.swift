import Foundation

struct PlaylistItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var name: String { url.lastPathComponent }

    init(url: URL) {
        id = UUID()
        self.url = url.standardizedFileURL
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
