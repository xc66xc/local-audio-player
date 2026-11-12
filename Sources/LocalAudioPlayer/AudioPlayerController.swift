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
    @Published private(set) var pendingResume: PendingResume?
    @Published private(set) var preparingItemID: UUID?
    var isPreparingAudio: Bool { preparingItemID != nil }

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

    let fileDrop = FileDropImporter()

    private var player: (any AudioPlayback)?
    private var preparedAudio: NcmPreparedAudio?
    private let ncmPreparer: NcmPreparer
    private var ncmLoadTask: Task<Void, Never>?
    private var ncmLoadToken: UUID?
    private var ncmLoadCompletion: ((Bool) -> Void)?
    private var resumePositions: [UUID: ResumePosition] = [:]
    private var currentFileStamp: FileStamp?
    private var ticker: Timer?
    private var scopedURLs: Set<URL> = []
    private let logger = Logger(subsystem: "local.miniaudio.player", category: "Playback")

    private let sessionStore: SessionStore?
    private var pendingSave: Task<Void, Never>?
    private var lastPeriodicSave = Date()
    private var hasRestored = false
    private var isShuttingDown = false
    private var saveErrorShown = false

    enum LoadReason { case switching, restoration, reloading }

    private struct FileStamp {
        var size: Int64?
        var modificationTime: TimeInterval?
    }

    private var actualPosition: TimeInterval {
        PlaybackRules.position(isPlaying ? (player?.currentTime ?? position) : position, duration: duration)
    }

    private func fileStamp(for url: URL) -> FileStamp? {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return FileStamp(size: values.fileSize.map { Int64($0) },
                             modificationTime: values.contentModificationDate?.timeIntervalSince1970)
        } catch {
            logger.error("[error] [resume.identity] \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private func isValidResume(_ saved: ResumePosition, duration: TimeInterval, stamp: FileStamp?) -> Bool {
        guard saved.position.isFinite, saved.duration.isFinite, saved.position >= 5,
              saved.position < saved.duration, duration.isFinite, saved.position < duration else { return false }
        if let oldSize = saved.fileSize, let newSize = stamp?.size, oldSize != newSize { return false }
        if let oldTime = saved.modificationTime, let newTime = stamp?.modificationTime,
           oldTime != newTime { return false }
        return true
    }

    @discardableResult
    private func resolveReachedResume(at time: TimeInterval) -> Bool {
        guard let pendingResume, pendingResume.itemID == currentID, time >= pendingResume.position else { return false }
        self.pendingResume = nil
        return true
    }

    /// Archive only at visit boundaries; a pending offer protects the previous listening point.
    private func archiveCurrentPosition(at time: TimeInterval? = nil) {
        guard let id = currentID else { return }
        let time = PlaybackRules.position(time ?? actualPosition, duration: duration)
        resolveReachedResume(at: time)
        guard pendingResume?.itemID != id else { return }
        if time >= 5, time < duration {
            let previous = resumePositions[id]
            resumePositions[id] = ResumePosition(position: time, duration: duration,
                fileSize: currentFileStamp?.size ?? previous?.fileSize,
                modificationTime: currentFileStamp?.modificationTime ?? previous?.modificationTime)
        } else {
            resumePositions[id] = nil
        }
    }

    func acceptResume() {
        guard let offer = pendingResume, offer.itemID == currentID,
              offer.position >= 5, offer.position < duration else { return }
        cancelAudioPreparation()
        if movePlayhead(to: offer.position, adoptingPosition: false) {
            pendingResume = nil
            scheduleSave()
            logger.info("[resume.accept] item=\(offer.itemID.uuidString, privacy: .public)")
        }
    }

    func dismissResume() {
        guard let offer = pendingResume, offer.itemID == currentID else { return }
        cancelAudioPreparation()
        fileDrop.cancel()
        pendingResume = nil
        scheduleSave()
        logger.info("[resume.dismiss] item=\(offer.itemID.uuidString, privacy: .public)")
    }

    init(sessionStore: SessionStore? = nil, ncmPreparer: NcmPreparer = NcmPreparer()) {
        self.sessionStore = sessionStore
        self.ncmPreparer = ncmPreparer
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
        resumePositions = saved.resumePositions
        pendingResume = saved.pendingResume
        currentID = saved.currentID
        position = saved.position
        duration = saved.duration
        // Missing files retain their saved place. Never resume or auto-advance during restoration.
        if let id = saved.currentID, let item = currentItem, !item.isUnavailable,
           load(id, autoplay: false, reason: .restoration, resumeAt: saved.position) {
            let opening = ncmLoadTask
            await opening?.value
        }
        guard !isShuttingDown else { return }
        // A small checkpoint may contain a newer current point than the archived table.
        // Keep the archive frozen when the user still has an earlier offer to choose.
        archiveCurrentPosition()
        selectedID = saved.selectedID
        logger.info("[session.restore] paused=true count=\(self.items.count)")
    }

    private func snapshot() -> SavedSession {
        let time = actualPosition
        resolveReachedResume(at: time)
        return SavedSession(items: items, selectedID: selectedID, currentID: currentID,
                            position: PlaybackRules.position(time, duration: duration), duration: duration,
                            autoAdvance: autoAdvance, forwardSeconds: forwardSeconds,
                            backwardSeconds: backwardSeconds, holdRate: holdRate,
                            resumePositions: resumePositions, pendingResume: pendingResume)
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

    var canImportDroppedFiles: Bool { !isRestoring && !isShuttingDown && !isChoosingFiles && errorMessage == nil }

    func selectItem(_ id: UUID?) {
        guard selectedID != id else { return }
        cancelAudioPreparation()
        fileDrop.cancel()
        selectedID = id
    }

    @discardableResult
    func receiveDroppedFiles(_ providers: [NSItemProvider],
                             canAccept: @escaping () -> Bool = { true },
                             beforePlayback: @escaping () -> Void = {}) -> Bool {
        guard canImportDroppedFiles, canAccept() else { return false }
        cancelAudioPreparation()
        return fileDrop.start(providers) { [weak self] files, rejected in
            guard let self, self.canImportDroppedFiles, canAccept() else { return }
            _ = self.commitDroppedFiles(files, rejected: rejected, beforePlayback: beforePlayback)
        }
    }

    @discardableResult
    func importDroppedFiles(_ urls: [URL]) -> Bool {
        guard canImportDroppedFiles else { return false }
        cancelAudioPreparation()
        fileDrop.cancel()
        let files = urls.compactMap { ScopedDropFile(url: $0) }
        return commitDroppedFiles(files, rejected: urls.count - files.count, beforePlayback: {})
    }

    private func commitDroppedFiles(_ files: [ScopedDropFile], rejected: Int,
                                    beforePlayback: () -> Void) -> Bool {
        var skipped = rejected
        var known = Set<URL>()
        let accepted = files.compactMap { file -> URL? in
            let url = file.url.standardizedFileURL
            guard AudioFileTypes.extensions.contains(url.pathExtension.lowercased()),
                  let values = try? file.url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true, FileManager.default.isReadableFile(atPath: file.url.path) else {
                skipped += 1
                return nil
            }
            return known.insert(url).inserted ? file.url : nil
        }.sorted(by: Self.fileOrder)
        guard let first = accepted.first else {
            fileDrop.feedback = "未找到可添加的本地音频，已跳过 \(skipped) 个项目。"
            logger.info("[drop.reject] count=\(skipped)")
            return false
        }
        beforePlayback()
        addFiles(accepted)
        guard let target = items.first(where: { $0.url == first.standardizedFileURL }) else { return false }
        // Keep the existing current-item resume behavior and initial-load error protection.
        playItem(target.id)
        fileDrop.feedback = skipped > 0 ? "已接收 \(accepted.count) 个音频，跳过 \(skipped) 个不支持或无法读取的项目。" : nil
        logger.info("[drop.import] accepted=\(accepted.count) rejected=\(skipped)")
        return (currentID == target.id && isPlaying) || preparingItemID == target.id
    }

    private static func fileOrder(_ left: URL, _ right: URL) -> Bool {
        let order = left.lastPathComponent.localizedStandardCompare(right.lastPathComponent)
        return order == .orderedSame ? left.path < right.path : order == .orderedAscending
    }

    func relocate(_ id: UUID, to url: URL) {
        cancelAudioPreparation()
        fileDrop.cancel()
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
            let savedPosition = actualPosition
            _ = load(id, autoplay: false, reason: .reloading, resumeAt: savedPosition) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    if changedURL, let scoped = self.scopedURLs.first(where: { $0.standardizedFileURL == previousURL.standardizedFileURL }) {
                        scoped.stopAccessingSecurityScopedResource()
                        self.scopedURLs.remove(scoped)
                    }
                } else {
                    if let currentIndex = self.items.firstIndex(where: { $0.id == id }),
                       self.items[currentIndex].url == url.standardizedFileURL {
                        self.items[currentIndex] = previousItem
                    }
                    if accessed { url.stopAccessingSecurityScopedResource(); self.scopedURLs.remove(url) }
                }
                self.scheduleSave()
            }
            return
        } else if let point = resumePositions[id] {
            // Relocating the same bytes keeps the point; replacing them invalidates it.
            let stamp = fileStamp(for: url)
            if !isValidResume(point, duration: point.duration, stamp: stamp) { resumePositions[id] = nil }
        }
        if changedURL, let scoped = scopedURLs.first(where: { $0.standardizedFileURL == previousURL.standardizedFileURL }) {
            scoped.stopAccessingSecurityScopedResource()
            scopedURLs.remove(scoped)
        }
        scheduleSave()
    }

    func showInFinder(_ id: UUID) {
        guard !isRestoring, !isShuttingDown,
              let item = items.first(where: { $0.id == id }) else { return }
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            errorMessage = "无法在 Finder 中显示“\(item.name)”。原文件不存在或无法访问，请使用“重新定位文件…”。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func chooseRename(for id: UUID, in window: NSWindow?) {
        cancelAudioPreparation()
        fileDrop.cancel()
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
        cancelAudioPreparation()
        fileDrop.cancel()
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
            if AudioFileTypes.isNcm(destination), preparedAudio != nil, player != nil {
                // Playback uses the leased restored file; only the original container moved.
                currentFileStamp = fileStamp(for: destination)
                if wasPlaying { resume() }
            } else {
                // Ogg seeks reopen their source URL, so rebuild after a path change.
                (player as? AVAudioPlayer)?.delegate = nil
                player?.stop()
                player = nil
                preparedAudio = nil
                _ = load(id, autoplay: wasPlaying, reason: .reloading, resumeAt: savedPosition)
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
        cancelAudioPreparation()
        fileDrop.cancel()
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
        cancelAudioPreparation()
        fileDrop.cancel()
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
        cancelAudioPreparation()
        fileDrop.cancel()
        var known = Set(items.map(\.url))
        var accessible = Set(scopedURLs.map { $0.standardizedFileURL })
        let sorted = urls.sorted(by: Self.fileOrder)
        for original in sorted {
            let url = original.standardizedFileURL
            if accessible.insert(url).inserted, original.startAccessingSecurityScopedResource() {
                scopedURLs.insert(original)
            }
            guard known.insert(url).inserted else { continue }
            items.append(PlaylistItem(url: url))
        }
        if selectedID == nil { selectedID = items.first?.id }
        scheduleSave()
    }

    func removeSelected() {
        cancelAudioPreparation()
        fileDrop.cancel()
        guard let id = selectedID, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        if currentID == id { clearPlayback() }
        resumePositions[id] = nil
        items.remove(at: index)
        if let scoped = scopedURLs.first(where: { $0.standardizedFileURL == item.url }) {
            scoped.stopAccessingSecurityScopedResource()
            scopedURLs.remove(scoped)
        }
        selectedID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        scheduleSave()
    }

    @discardableResult
    func load(_ id: UUID, autoplay: Bool, reason: LoadReason = .switching,
              resumeAt: TimeInterval? = nil, onCompletion: ((Bool) -> Void)? = nil) -> Bool {
        cancelAudioPreparation()
        guard !isShuttingDown, let item = items.first(where: { $0.id == id }) else {
            onCompletion?(false)
            return false
        }
        if AudioFileTypes.isNcm(item.url) {
            let token = UUID()
            ncmLoadToken = token
            preparingItemID = id
            ncmLoadCompletion = onCompletion
            ncmLoadTask = Task { @MainActor [weak self, preparer = ncmPreparer] in
                do {
                    let prepared = try await preparer.prepare(item.url)
                    guard let self, !Task.isCancelled, !self.isShuttingDown,
                          self.ncmLoadToken == token,
                          self.items.contains(where: { $0.id == id && $0.url == item.url }) else { return }
                    try prepared.validateSource(item.url)
                    let opened = self.commitLoad(item, playbackURL: prepared.url, prepared: prepared,
                                                 autoplay: autoplay, reason: reason, resumeAt: resumeAt)
                    self.finishAudioPreparation(token: token, succeeded: opened)
                } catch {
                    guard let self, !Task.isCancelled, !self.isShuttingDown,
                          self.ncmLoadToken == token else { return }
                    if let index = self.items.firstIndex(where: { $0.id == id && $0.url == item.url }) {
                        self.items[index].isUnavailable = !FileManager.default.isReadableFile(atPath: item.url.path)
                    }
                    self.finishAudioPreparation(token: token, succeeded: false)
                    self.report("无法打开“\(item.name)”。\(error.localizedDescription)", error: error)
                }
            }
            return true
        }
        let opened = commitLoad(item, playbackURL: item.url, autoplay: autoplay, reason: reason, resumeAt: resumeAt)
        onCompletion?(opened)
        return opened
    }

    func cancelAudioPreparation() {
        let task = ncmLoadTask
        let completion = ncmLoadCompletion
        ncmLoadToken = nil
        ncmLoadTask = nil
        ncmLoadCompletion = nil
        preparingItemID = nil
        task?.cancel()
        completion?(false)
    }

    private func finishAudioPreparation(token: UUID, succeeded: Bool) {
        guard ncmLoadToken == token else { return }
        let completion = ncmLoadCompletion
        ncmLoadToken = nil
        ncmLoadTask = nil
        ncmLoadCompletion = nil
        preparingItemID = nil
        completion?(succeeded)
    }

    private func commitLoad(_ item: PlaylistItem, playbackURL: URL, prepared: NcmPreparedAudio? = nil,
                            reusingPreparedAudio: Bool = false,
                            autoplay: Bool, reason: LoadReason, resumeAt: TimeInterval?) -> Bool {
        let id = item.id
        do {
            let candidate: any AudioPlayback
            // Use the portable decoder for Ogg consistently across supported macOS versions.
            if AudioFileTypes.isOgg(playbackURL) {
                let stream = try StreamAudioPlayer(url: playbackURL)
                stream.finished = { [weak self, weak stream] success in
                    guard let stream else { return }
                    self?.handleFinished(stream, successfully: success)
                }
                candidate = stream
            } else {
                let native = try AVAudioPlayer(contentsOf: playbackURL)
                native.enableRate = true
                guard native.duration.isFinite, native.duration > 0, native.prepareToPlay() else {
                    throw PlaybackError.unreadable
                }
                native.delegate = self
                candidate = native
            }
            var initialPosition = PlaybackRules.position(resumeAt ?? 0, duration: candidate.duration)
            if autoplay && initialPosition >= candidate.duration { initialPosition = 0 }
            if initialPosition > 0 { candidate.currentTime = initialPosition }
            // An already-open NCM keeps playing its leased bytes after a source rename.
            if !reusingPreparedAudio { try prepared?.validateSource(item.url) }
            endBoost()
            let previous = player
            previous?.pause()
            let previousPosition = actualPosition
            if autoplay && !candidate.play() {
                if isPlaying { _ = previous?.play() }
                throw PlaybackError.cannotPlay
            }
            let startsVisit = reason == .switching && currentID != id
            if startsVisit { archiveCurrentPosition(at: previousPosition) }
            let stamp = reusingPreparedAudio ? currentFileStamp :
                (prepared.map { FileStamp(size: $0.sourceSize, modificationTime: $0.sourceModificationTime) }
                 ?? fileStamp(for: item.url))
            let saved = resumePositions[id].flatMap { isValidResume($0, duration: candidate.duration, stamp: stamp) ? $0 : nil }
            if saved == nil { resumePositions[id] = nil }
            if startsVisit {
                pendingResume = saved.map { PendingResume(itemID: id, position: $0.position) }
                if saved != nil { logger.info("[resume.offer] item=\(id.uuidString, privacy: .public)") }
            } else if let offer = pendingResume,
                      offer.itemID != id || saved == nil || offer.position >= candidate.duration {
                pendingResume = nil
            }
            (previous as? AVAudioPlayer)?.delegate = nil
            previous?.stop()
            stopTicker()
            player = candidate
            preparedAudio = prepared
            currentFileStamp = stamp
            currentID = id
            selectedID = id
            duration = candidate.duration
            position = initialPosition
            isPlaying = autoplay
            if let prepared, !prepared.warnings.isEmpty {
                sessionNotice = "此旧版 NCM 的校验信息不一致，已按实际音频格式打开。"
            }
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
        fileDrop.cancel()
        guard !isRestoring else { return }
        cancelAudioPreparation()
        if currentID == id { resumeCurrent() } else { load(id, autoplay: true) }
    }

    func restartPlayback() {
        guard !isRestoring, !isShuttingDown, currentID != nil else { return }
        fileDrop.cancel()
        cancelAudioPreparation()
        // Cancelling a pending relocation may restore the previous source URL.
        guard let item = currentItem else { return }
        endBoost()
        let completed: (Bool) -> Void = { [weak self] succeeded in
            guard succeeded, let self, self.currentID == item.id else { return }
            self.pendingResume = nil
            self.resumePositions[item.id] = nil
            self.scheduleSave()
            self.logger.info("[playback.restart] item=\(item.id.uuidString, privacy: .public)")
        }
        if let preparedAudio, player != nil {
            // A new player identity rejects delayed finish events without unpacking NCM again.
            completed(commitLoad(item, playbackURL: preparedAudio.url, prepared: preparedAudio,
                                 reusingPreparedAudio: true, autoplay: true,
                                 reason: .reloading, resumeAt: 0))
        } else {
            _ = load(item.id, autoplay: true, reason: .reloading, resumeAt: 0, onCompletion: completed)
        }
    }

    func togglePlayback() {
        fileDrop.cancel()
        guard !isRestoring else { return }
        cancelAudioPreparation()
        if isPlaying {
            endBoost()
            player?.pause()
            position = player?.currentTime ?? position
            resolveReachedResume(at: position)
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
            _ = load(id, autoplay: true, reason: .reloading,
                     resumeAt: savedPosition >= duration ? 0 : savedPosition)
            return
        }
        resume()
    }

    private func resume() {
        guard let player else { return }
        if position >= duration { player.currentTime = 0; position = 0; pendingResume = nil }
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
        guard !isRestoring else { return }
        cancelAudioPreparation()
        movePlayhead(to: value, adoptingPosition: true)
    }

    @discardableResult
    private func movePlayhead(to value: TimeInterval, adoptingPosition: Bool) -> Bool {
        fileDrop.cancel()
        defer { scheduleSave() }
        if player == nil, let id = currentID {
            if let item = currentItem, AudioFileTypes.isNcm(item.url) {
                if adoptingPosition { pendingResume = nil }
                return load(id, autoplay: false, reason: .reloading, resumeAt: value)
            }
            guard load(id, autoplay: false, reason: .reloading) else { return false }
        }
        guard let player else { return false }
        let target = PlaybackRules.position(value, duration: duration)
        if target >= duration {
            // Invalidate completion callbacks for the previous playback session.
            endBoost()
            player.stop()
            (player as? AVAudioPlayer)?.delegate = nil
            self.player = nil
            preparedAudio = nil
            isPlaying = false
            position = duration
            pendingResume = nil
            stopTicker()
            return true
        }
        let wasPlaying = isPlaying
        player.currentTime = target
        // A stream seek can synchronously report a decoder restart failure.
        guard !wasPlaying || isPlaying else { return false }
        position = target
        if adoptingPosition { pendingResume = nil }
        return true
    }

    // Identity protects against a delayed completion from a replaced player.
    nonisolated func audioPlayerDidFinishPlaying(_ finishedPlayer: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.handleFinished(finishedPlayer, successfully: flag) }
    }

    private func handleFinished(_ finishedPlayer: any AudioPlayback, successfully flag: Bool) {
        guard finishedPlayer === player else { return }
        let observedPosition = actualPosition
        let lastPosition = position
        endBoost()
        isPlaying = false
        stopTicker()
        guard flag else {
            position = observedPosition < duration ? max(lastPosition, observedPosition) : lastPosition
            // Failed decoders may reset their internal clock. Rebuild at the retained
            // position on the next play instead of resuming that failed transport.
            (finishedPlayer as? AVAudioPlayer)?.delegate = nil
            finishedPlayer.stop()
            player = nil
            preparedAudio = nil
            scheduleSave()
            report("音频播放中断，请重新打开文件。", error: PlaybackError.unreadable)
            return
        }
        position = duration
        pendingResume = nil
        if let id = currentID { resumePositions[id] = nil }
        scheduleSave()
        guard !isPreparingAudio else { return }
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
        let observedPosition = PlaybackRules.position(failedPlayer.currentTime, duration: duration)
        if observedPosition < duration { position = max(position, observedPosition) }
        failedPlayer.delegate = nil
        failedPlayer.stop()
        player = nil
        preparedAudio = nil
        isPlaying = false
        stopTicker()
        scheduleSave()
        report("音频解码失败，请检查文件后重新打开。", error: error ?? PlaybackError.unreadable)
    }

    func shutdown() {
        fileDrop.cancel()
        guard !isShuttingDown else { return }
        cancelAudioPreparation()
        pendingSave?.cancel()
        if !isRestoring { archiveCurrentPosition() }
        if !isRestoring, let sessionStore { showSaveError(sessionStore.flush(snapshot())) }
        isShuttingDown = true
        clearPlayback()
        ncmPreparer.cancelAllAndWait()
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }

    private func clearPlayback() {
        endBoost()
        stopTicker()
        (player as? AVAudioPlayer)?.delegate = nil
        player?.stop()
        player = nil
        preparedAudio = nil
        currentFileStamp = nil
        pendingResume = nil
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
                if self.resolveReachedResume(at: self.position) { self.scheduleSave() }
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
