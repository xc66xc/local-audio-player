import AppKit
import AVFAudio
import OSLog
import UniformTypeIdentifiers

@MainActor
final class AudioPlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var items: [PlaylistItem] = []
    @Published var selectedID: UUID? { didSet { scheduleSave() } }
    @Published var autoAdvance = false { didSet { scheduleSave() } }
    @Published private(set) var currentID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var sessionNotice: String?
    @Published private(set) var isRestoring = false
    @Published private(set) var isChoosingFiles = false

    @Published var forwardSeconds = 5 { didSet { if !(1...600).contains(forwardSeconds) { forwardSeconds = min(max(forwardSeconds, 1), 600) }; scheduleSave() } }
    @Published var backwardSeconds = 5 { didSet { if !(1...600).contains(backwardSeconds) { backwardSeconds = min(max(backwardSeconds, 1), 600) }; scheduleSave() } }
    @Published var holdRate: Float = 2 { didSet { scheduleSave() } }
    @Published private(set) var isBoosting = false
    var playbackRate: Float { player?.rate ?? 1 }

    func beginBoost() {
        guard isPlaying, let player else { return }
        player.rate = min(max(holdRate, 1), 2)
        isBoosting = true
    }

    func endBoost() {
        player?.rate = 1
        isBoosting = false
    }

    private var player: (any AudioPlayback)?
    private var ticker: Timer?
    private var scopedURLs: Set<URL> = []
    private let logger = Logger(subsystem: "local.miniaudio.player", category: "Playback")

    private let sessionStore: SessionStore?
    private var pendingSave: Task<Void, Never>?
    private var lastPeriodicSave = Date()
    private var hasRestored = false
    private var isShuttingDown = false
    private var saveErrorShown = false

    init(sessionStore: SessionStore? = nil) {
        self.sessionStore = sessionStore
        isRestoring = sessionStore != nil
        super.init()
    }

    func restoreSession() async {
        guard !hasRestored, let sessionStore else { return }
        hasRestored = true
        isRestoring = true
        let result = await sessionStore.load()
        defer { isRestoring = false }
        guard !isShuttingDown else { return }
        sessionNotice = result.notice
        guard let saved = result.session else { return }
        items = saved.items
        for item in items where item.url.startAccessingSecurityScopedResource() { scopedURLs.insert(item.url) }
        autoAdvance = saved.autoAdvance
        forwardSeconds = saved.forwardSeconds
        backwardSeconds = saved.backwardSeconds
        holdRate = saved.holdRate
        currentID = saved.currentID
        position = saved.position
        duration = saved.duration
        // Missing files retain their saved place. Never resume or auto-advance during restoration.
        if let id = saved.currentID, let item = currentItem, !item.isUnavailable,
           load(id, autoplay: false) {
            seek(to: PlaybackRules.position(saved.position, duration: duration))
        }
        selectedID = saved.selectedID
        logger.info("[session.restore] paused=true count=\(self.items.count)")
    }

    private func snapshot() -> SavedSession {
        let time = isPlaying ? (player?.currentTime ?? position) : position
        return SavedSession(items: items, selectedID: selectedID, currentID: currentID,
                            position: PlaybackRules.position(time, duration: duration), duration: duration,
                            autoAdvance: autoAdvance, forwardSeconds: forwardSeconds,
                            backwardSeconds: backwardSeconds, holdRate: holdRate)
    }

    private func scheduleSave() {
        guard sessionStore != nil, !isRestoring, !isShuttingDown else { return }
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.saveSession()
        }
    }

    private func saveSession() {
        guard let sessionStore, !isRestoring, !isShuttingDown else { return }
        sessionStore.save(snapshot()) { [weak self] message in
            Task { @MainActor in self?.showSaveError(message) }
        }
        lastPeriodicSave = Date()
    }

    private func showSaveError(_ message: String?) {
        if let message, !saveErrorShown {
            sessionNotice = message
            saveErrorShown = true
        }
    }

    func relocate(_ id: UUID, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items.contains(where: { $0.id != id && $0.url == url.standardizedFileURL }) {
            errorMessage = "该文件已在播放列表中，请选择其他文件。"
            return
        }
        let previousItem = items[index]
        let previousURL = previousItem.url
        let changedURL = previousURL != url.standardizedFileURL
        let accessed = changedURL && url.startAccessingSecurityScopedResource()
        if accessed { scopedURLs.insert(url) }
        items[index] = PlaylistItem(url: url, id: id)
        if currentID == id {
            let savedPosition = position
            guard load(id, autoplay: false) else {
                items[index] = previousItem
                if accessed { url.stopAccessingSecurityScopedResource(); scopedURLs.remove(url) }
                return
            }
            seek(to: min(savedPosition, duration))
        }
        if changedURL, let scoped = scopedURLs.first(where: { $0.standardizedFileURL == previousURL.standardizedFileURL }) {
            scoped.stopAccessingSecurityScopedResource()
            scopedURLs.remove(scoped)
        }
        scheduleSave()
    }

    func chooseRename(for id: UUID, in window: NSWindow?) {
        guard !isRestoring, !isChoosingFiles, let window, window.attachedSheet == nil,
              let item = items.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "重命名音频"
        let suffix = item.url.pathExtension
        alert.informativeText = "将直接修改磁盘文件名。" + (suffix.isEmpty ? "" : "扩展名 .\(suffix) 保持不变。")
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = item.url.deletingPathExtension().lastPathComponent
        field.setAccessibilityLabel("新文件名（不含扩展名）")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                if response == .alertFirstButtonReturn { self?.renameFile(id, to: field.stringValue) }
            }
        }
    }

    @discardableResult
    func renameFile(_ id: UUID, to proposedName: String) -> Bool {
        guard !isRestoring, !isShuttingDown,
              let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let stem = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, stem != ".", stem != "..",
              !stem.contains("/"), !stem.contains(":"),
              stem.rangeOfCharacter(from: .controlCharacters) == nil else {
            errorMessage = "名称不能为空，也不能包含 /、: 或控制字符。"
            return false
        }
        let original = items[index]
        let suffix = original.url.pathExtension
        let filename = stem + (suffix.isEmpty ? "" : ".\(suffix)")
        let destination = original.url.deletingLastPathComponent().appendingPathComponent(filename)
        guard destination != original.url else { return true }
        let manager = FileManager.default
        let selection = selectedID
        let wasCurrent = currentID == id
        let wasPlaying = wasCurrent && isPlaying
        let savedPosition = wasCurrent ? (isPlaying ? (player?.currentTime ?? position) : position) : 0
        if wasCurrent {
            endBoost()
            player?.pause()
            position = savedPosition
            isPlaying = false
            stopTicker()
        }
        do {
            // FileManager's move refuses to overwrite an existing destination.
            try manager.moveItem(at: original.url, to: destination)
        } catch {
            if wasPlaying { resume() }
            logger.error("[error] [file.rename] \(String(describing: error), privacy: .private)")
            errorMessage = manager.fileExists(atPath: destination.path)
                ? "同一文件夹中已有同名文件，未覆盖任何文件。"
                : "重命名失败，请检查文件是否存在、名称是否有效，以及文件夹是否有写入权限。"
            return false
        }
        items[index] = PlaylistItem(url: destination, id: id)
        if destination.startAccessingSecurityScopedResource() { scopedURLs.insert(destination) }
        if wasCurrent {
            // Release the old path: Ogg seeks create a decoder using the player's URL.
            (player as? AVAudioPlayer)?.delegate = nil
            player?.stop()
            player = nil
            if load(id, autoplay: false) {
                seek(to: savedPosition)
                if wasPlaying { resume() }
            }
        }
        if let scoped = scopedURLs.first(where: { $0.standardizedFileURL == original.url }) {
            scoped.stopAccessingSecurityScopedResource()
            scopedURLs.remove(scoped)
        }
        selectedID = selection
        scheduleSave()
        logger.info("[file.rename] updated=true current=\(wasCurrent)")
        return true
    }

    func chooseReplacement(for id: UUID, in window: NSWindow?) {
        guard !isChoosingFiles, !isRestoring, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "重新定位音频文件"
        panel.prompt = "选择"
        panel.allowedContentTypes = AudioFileTypes.contentTypes
        panel.canChooseDirectories = false
        isChoosingFiles = true
        panel.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.isChoosingFiles = false
                if response == .OK, let url = panel.url { self.relocate(id, to: url) }
            }
        }
    }

    var currentItem: PlaylistItem? { items.first { $0.id == currentID } }
    var canPlay: Bool { currentID != nil || selectedID != nil }

    func chooseFiles(in window: NSWindow?) {
        guard !isChoosingFiles, !isRestoring, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "添加本地音频"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AudioFileTypes.contentTypes
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
        scheduleSave()
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
        scheduleSave()
    }

    @discardableResult
    func load(_ id: UUID, autoplay: Bool) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        do {
            let candidate: any AudioPlayback
            // Use the portable decoder for Ogg consistently across supported macOS versions.
            if AudioFileTypes.isOgg(item.url) {
                let stream = try StreamAudioPlayer(url: item.url)
                stream.finished = { [weak self, weak stream] success in
                    guard let stream else { return }
                    self?.handleFinished(stream, successfully: success)
                }
                candidate = stream
            } else {
                let native = try AVAudioPlayer(contentsOf: item.url)
                native.enableRate = true
                guard native.duration.isFinite, native.duration > 0, native.prepareToPlay() else {
                    throw PlaybackError.unreadable
                }
                native.delegate = self
                candidate = native
            }
            endBoost()
            let previous = player
            previous?.pause()
            if autoplay && !candidate.play() {
                if isPlaying { _ = previous?.play() }
                throw PlaybackError.cannotPlay
            }
            (previous as? AVAudioPlayer)?.delegate = nil
            previous?.stop()
            stopTicker()
            player = candidate
            currentID = id
            selectedID = id
            duration = candidate.duration
            position = 0
            isPlaying = autoplay
            if autoplay { startTicker() }
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].isUnavailable = false }
            scheduleSave()
            return true
        } catch {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].isUnavailable = !FileManager.default.isReadableFile(atPath: item.url.path)
            }
            report("无法播放“\(item.name)”。文件可能已移动、损坏，或编码不受支持。", error: error)
            return false
        }
    }

    func playItem(_ id: UUID) {
        guard !isRestoring else { return }
        if currentID == id { resumeCurrent() } else { load(id, autoplay: true) }
    }

    func togglePlayback() {
        guard !isRestoring else { return }
        if isPlaying {
            endBoost()
            player?.pause()
            position = player?.currentTime ?? position
            isPlaying = false
            stopTicker()
        } else if currentID != nil {
            resumeCurrent()
        } else if let id = selectedID {
            load(id, autoplay: true)
        }
        scheduleSave()
    }

    private func resumeCurrent() {
        if player == nil, let id = currentID {
            let savedPosition = position
            guard load(id, autoplay: false) else { return }
            seek(to: savedPosition >= duration ? 0 : savedPosition)
        }
        resume()
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
        scheduleSave()
    }

    func seek(by offset: TimeInterval) {
        seek(to: (isPlaying ? (player?.currentTime ?? position) : position) + offset)
    }

    func seek(to value: TimeInterval) {
        defer { scheduleSave() }
        let target = PlaybackRules.position(value, duration: duration)
        if player == nil, let id = currentID {
            guard load(id, autoplay: false) else { return }
        }
        guard let player else { return }
        if target >= duration {
            // Invalidate completion callbacks for the previous playback session.
            endBoost()
            player.stop()
            (player as? AVAudioPlayer)?.delegate = nil
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

    private func handleFinished(_ finishedPlayer: any AudioPlayback, successfully flag: Bool) {
        guard finishedPlayer === player else { return }
        endBoost()
        isPlaying = false
        stopTicker()
        position = duration
        scheduleSave()
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
        endBoost()
        failedPlayer.pause()
        isPlaying = false
        stopTicker()
        scheduleSave()
        report("音频解码失败，请检查文件后重新打开。", error: error ?? PlaybackError.unreadable)
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        pendingSave?.cancel()
        if !isRestoring, let sessionStore { showSaveError(sessionStore.flush(snapshot())) }
        isShuttingDown = true
        clearPlayback()
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }

    private func clearPlayback() {
        endBoost()
        stopTicker()
        (player as? AVAudioPlayer)?.delegate = nil
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
                if Date().timeIntervalSince(self.lastPeriodicSave) >= 5 { self.saveSession() }
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
