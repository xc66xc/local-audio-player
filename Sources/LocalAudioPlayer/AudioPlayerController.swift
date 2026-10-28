import AppKit
import AVFAudio
import OSLog
import UniformTypeIdentifiers

@MainActor
final class AudioPlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var items: [PlaylistItem] = []
    @Published var selectedID: UUID?
    @Published var autoAdvance = false
    @Published private(set) var currentID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published private(set) var isChoosingFiles = false

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var scopedURLs: Set<URL> = []
    private let logger = Logger(subsystem: "local.miniaudio.player", category: "Playback")

    var currentItem: PlaylistItem? { items.first { $0.id == currentID } }
    var canPlay: Bool { currentID != nil || selectedID != nil }

    func chooseFiles(in window: NSWindow?) {
        guard !isChoosingFiles, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "添加本地音频"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, UTType(filenameExtension: "m4a") ?? .audio]
        isChoosingFiles = true
        panel.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.isChoosingFiles = false
                if response == .OK { self.addFiles(panel.urls) }
            }
        }
    }

    func addFiles(_ urls: [URL]) {
        var known = Set(items.map(\.url))
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        for original in sorted {
            let url = original.standardizedFileURL
            guard known.insert(url).inserted else { continue }
            if original.startAccessingSecurityScopedResource() { scopedURLs.insert(original) }
            items.append(PlaylistItem(url: url))
        }
        if selectedID == nil { selectedID = items.first?.id }
    }

    func removeSelected() {
        guard let id = selectedID, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        if currentID == id { clearPlayback() }
        items.remove(at: index)
        if let scoped = scopedURLs.first(where: { $0.standardizedFileURL == item.url }) {
            scoped.stopAccessingSecurityScopedResource()
            scopedURLs.remove(scoped)
        }
        selectedID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
    }

    @discardableResult
    func load(_ id: UUID, autoplay: Bool) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        do {
            let candidate = try AVAudioPlayer(contentsOf: item.url)
            guard candidate.duration.isFinite, candidate.duration > 0, candidate.prepareToPlay() else {
                throw PlaybackError.unreadable
            }
            let previous = player
            previous?.pause()
            if autoplay && !candidate.play() {
                if isPlaying { previous?.play() }
                throw PlaybackError.cannotPlay
            }
            previous?.delegate = nil
            previous?.stop()
            stopTicker()
            player = candidate
            candidate.delegate = self
            currentID = id
            selectedID = id
            duration = candidate.duration
            position = 0
            isPlaying = autoplay
            if autoplay { startTicker() }
            return true
        } catch {
            report("无法播放“\(item.name)”。文件可能已移动、损坏，或编码不受支持。", error: error)
            return false
        }
    }

    func playItem(_ id: UUID) {
        if currentID == id, player != nil { resume() } else { load(id, autoplay: true) }
    }

    func togglePlayback() {
        if isPlaying {
            player?.pause()
            position = player?.currentTime ?? position
            isPlaying = false
            stopTicker()
        } else if player != nil {
            resume()
        } else if let id = currentID ?? selectedID {
            load(id, autoplay: true)
        }
    }

    private func resume() {
        guard let player else { return }
        if position >= duration { player.currentTime = 0; position = 0 }
        guard player.play() else {
            report("音频无法开始播放，请检查音频输出设备后重试。", error: PlaybackError.cannotPlay)
            return
        }
        isPlaying = true
        startTicker()
    }

    func seek(by offset: TimeInterval) {
        seek(to: (isPlaying ? (player?.currentTime ?? position) : position) + offset)
    }

    func seek(to value: TimeInterval) {
        let target = PlaybackRules.position(value, duration: duration)
        if player == nil, let id = currentID {
            guard load(id, autoplay: false) else { return }
        }
        guard let player else { return }
        if target >= duration {
            // Invalidate completion callbacks for the previous playback session.
            player.stop()
            player.delegate = nil
            self.player = nil
            isPlaying = false
            position = duration
            stopTicker()
            return
        }
        player.currentTime = target
        position = target
    }

    // Identity protects against a delayed completion from a replaced player.
    nonisolated func audioPlayerDidFinishPlaying(_ finishedPlayer: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.handleFinished(finishedPlayer, successfully: flag) }
    }

    private func handleFinished(_ finishedPlayer: AVAudioPlayer, successfully flag: Bool) {
        guard finishedPlayer === player else { return }
        isPlaying = false
        stopTicker()
        position = duration
        guard flag else {
            report("音频播放中断，请重新打开文件。", error: PlaybackError.unreadable)
            return
        }
        guard let id = currentID,
              let next = PlaybackRules.nextID(after: id, in: items, autoAdvance: autoAdvance) else { return }
        load(next, autoplay: true)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ failedPlayer: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.handleDecodeError(failedPlayer, error: error) }
    }

    private func handleDecodeError(_ failedPlayer: AVAudioPlayer, error: Error?) {
        guard failedPlayer === player else { return }
        failedPlayer.pause()
        isPlaying = false
        stopTicker()
        report("音频解码失败，请检查文件后重新打开。", error: error ?? PlaybackError.unreadable)
    }

    func shutdown() {
        clearPlayback()
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }

    private func clearPlayback() {
        stopTicker()
        player?.delegate = nil
        player?.stop()
        player = nil
        currentID = nil
        position = 0
        duration = 0
        isPlaying = false
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, let player = self.player else { return }
                self.position = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func report(_ message: String, error: Error) {
        logger.error("\(message, privacy: .public) Error: \(String(describing: error), privacy: .private)")
        errorMessage = message
    }

    private enum PlaybackError: Error { case unreadable, cannotPlay }
}
