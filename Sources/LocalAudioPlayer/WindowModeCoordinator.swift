import AppKit
import Combine
import OSLog

@MainActor
final class WindowModeCoordinator: ObservableObject {
    enum Mode: String { case main, mini }

    enum PreferenceKey {
        static let mode = "Sona.windowMode.mode"
        static let pinned = "Sona.windowMode.miniPinned"
        static let mainFrame = "Sona.windowMode.mainFrame"
        static let miniFrame = "Sona.windowMode.miniFrame"
    }

    @Published private(set) var mode: Mode
    @Published private(set) var isPinned: Bool
    @Published private(set) var isTransitioning = false
    @Published private(set) var miniContentHeight: CGFloat = 96
    @Published var notice: String?
    var onWillSwitch: (() -> Void)?

    var isMini: Bool { mode == .mini }
    var minimumContentSize: NSSize { isMini ? NSSize(width: 480, height: miniContentHeight) : NSSize(width: 860, height: 620) }
    var preferredInitialSize: NSSize {
        let proposed = isMini ? (miniFrame ?? NSRect(x: 0, y: 0, width: 560, height: miniContentHeight))
            : (mainFrame ?? NSRect(x: 0, y: 0, width: 1040, height: 720))
        let result = Self.correctedFrame(proposed, minimumSize: minimumContentSize,
                                         visibleFrames: NSScreen.screens.map(\.visibleFrame))
        return NSSize(width: result.width, height: isMini ? miniContentHeight : result.height)
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "local.miniaudio.player", category: "WindowMode")
    private weak var window: NSWindow?
    private var mainFrame: NSRect?
    // Mini frames always contain the base height, excluding temporary feedback rows.
    private var miniFrame: NSRect?
    private var normalAppearance: Appearance?
    private var observers: [NSObjectProtocol] = []
    private var layoutTask: Task<Void, Never>?
    private var fullScreenTimeout: Task<Void, Never>?
    private var nativeFullScreenTimeout: Task<Void, Never>?
    private var nativeFullScreenID: UUID?
    private var nativeFullScreenDirection: FullScreenDirection?
    private var saveTask: Task<Void, Never>?
    private var transitionID: UUID?
    private var fullScreenTarget: Mode?
    private var fullScreenInitial = false
    private var committedMode: Mode
    private var isFullScreenChanging = false
    private var isClosing = false
    private var isShuttingDown = false

    private enum FullScreenDirection { case entering, exiting }

    @MainActor private struct Appearance {
        var styleMask: NSWindow.StyleMask
        var titleVisibility: NSWindow.TitleVisibility
        var transparentTitlebar: Bool
        var collectionBehavior: NSWindow.CollectionBehavior
        var contentMaxSize: NSSize
        var toolbar: NSToolbar?
        var toolbarVisible: Bool
        var buttonVisibility: [NSWindow.ButtonType: Bool]

        init(_ window: NSWindow) {
            styleMask = window.styleMask.subtracting(.fullScreen)
            titleVisibility = window.titleVisibility
            transparentTitlebar = window.titlebarAppearsTransparent
            collectionBehavior = window.collectionBehavior
            contentMaxSize = window.contentMaxSize
            toolbar = window.toolbar
            toolbarVisible = window.toolbar?.isVisible ?? true
            buttonVisibility = [:]
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                buttonVisibility[button] = window.standardWindowButton(button)?.isHidden ?? false
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let restoredMode = defaults.string(forKey: PreferenceKey.mode).flatMap(Mode.init(rawValue:)) ?? .main
        mode = restoredMode
        committedMode = restoredMode
        isPinned = defaults.object(forKey: PreferenceKey.pinned) as? Bool ?? true
        mainFrame = Self.decodeFrame(defaults.array(forKey: PreferenceKey.mainFrame))
        miniFrame = Self.decodeFrame(defaults.array(forKey: PreferenceKey.miniFrame))
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        layoutTask?.cancel()
        fullScreenTimeout?.cancel()
        nativeFullScreenTimeout?.cancel()
        saveTask?.cancel()
    }

    func attach(to window: NSWindow) {
        guard !isShuttingDown, !isClosing, self.window !== window else { return }
        removeObservers()
        cancelTransition()
        self.window = window
        normalAppearance = Appearance(window)
        installObservers(for: window)
        if window.styleMask.contains(.fullScreen) {
            if isMini { requestFullScreenExit(for: .mini, initial: true) }
            return
        }
        beginLayout(to: mode, initial: true)
    }

    func toggle() {
        guard !isShuttingDown, !isClosing, !isTransitioning else { return }
        guard let window else { notice = "窗口尚未准备好，请稍后重试。"; return }
        guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        guard !isFullScreenChanging else { notice = "窗口正在切换全屏，请稍后再试。"; return }
        onWillSwitch?()
        saveTask?.cancel()
        saveCurrentFrame()
        let target: Mode = isMini ? .main : .mini
        if window.isMiniaturized { window.deminiaturize(nil) }
        if window.styleMask.contains(.fullScreen) {
            requestFullScreenExit(for: target, initial: false)
        } else {
            beginLayout(to: target)
        }
    }

    func togglePinned() {
        guard !isShuttingDown, !isClosing else { return }
        isPinned.toggle()
        defaults.set(isPinned, forKey: PreferenceKey.pinned)
        if isMini { window?.level = isPinned ? .floating : .normal }
    }

    func updateMiniSupplementHeight(_ height: CGFloat) {
        guard height.isFinite, height >= 0, height <= 224 else {
            logger.error("[error] [window.mode.feedback] invalid height")
            return
        }
        let updated = 96 + height
        guard miniContentHeight != updated else { return }
        miniContentHeight = updated
        if isMini, !isTransitioning, !isClosing, !isShuttingDown, window != nil {
            beginLayout(to: .mini, preservingMiniTop: true)
        }
    }

    func closeWindow() {
        guard !isShuttingDown, !isClosing, let window,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        onWillSwitch?()
        window.performClose(nil)
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        if !isTransitioning { saveCurrentFrame() }
        isShuttingDown = true
        isClosing = true
        cancelTransition()
        removeObservers()
        onWillSwitch = nil
        normalAppearance = nil
        window = nil
    }

    private func requestFullScreenExit(for target: Mode, initial: Bool) {
        guard let window else { return }
        let id = UUID()
        transitionID = id
        fullScreenTarget = target
        fullScreenInitial = initial
        isTransitioning = true
        fullScreenTimeout?.cancel()
        fullScreenTimeout = Task { @MainActor [weak self, weak window] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, let window, self.isCurrent(id, window: window), self.fullScreenTarget != nil else { return }
            // A later native transition owns its own watchdog; an old exit request
            // must not clear that newer transition's guard or resize during it.
            guard self.finishNativeFullScreenTransition(matching: .exiting) else {
                self.cancelTransition()
                self.notice = "窗口仍在切换全屏，请稍后重试。"
                return
            }
            if !window.styleMask.contains(.fullScreen) {
                self.fullScreenTarget = nil
                self.beginLayout(to: target, initial: initial)
            } else {
                self.cancelTransition()
                self.notice = "未能退出全屏，暂未切换窗口模式，请稍后重试。"
                self.logger.error("[error] [window.mode.fullscreen] exit timed out")
            }
        }
        window.toggleFullScreen(nil)
    }

    private func beginNativeFullScreenTransition(_ direction: FullScreenDirection, window: NSWindow) {
        nativeFullScreenTimeout?.cancel()
        let id = UUID()
        nativeFullScreenID = id
        nativeFullScreenDirection = direction
        isFullScreenChanging = true
        nativeFullScreenTimeout = Task { @MainActor [weak self, weak window] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, let window, self.window === window, !self.isClosing, !self.isShuttingDown,
                  self.nativeFullScreenID == id else { return }
            self.clearNativeFullScreenTransition()
            // Explicit mini requests have their own timeout and final state decision.
            if self.fullScreenTarget == nil {
                self.notice = "全屏切换未收到完成确认，请稍后重试。"
            }
            self.logger.error("[error] [window.mode.fullscreen] native completion timed out fullScreen=\(window.styleMask.contains(.fullScreen))")
        }
    }

    @discardableResult
    private func finishNativeFullScreenTransition(matching direction: FullScreenDirection) -> Bool {
        guard nativeFullScreenDirection == nil || nativeFullScreenDirection == direction else { return false }
        clearNativeFullScreenTransition()
        return true
    }

    private func clearNativeFullScreenTransition() {
        nativeFullScreenID = nil
        nativeFullScreenDirection = nil
        nativeFullScreenTimeout?.cancel()
        nativeFullScreenTimeout = nil
        isFullScreenChanging = false
    }

    private func beginLayout(to target: Mode, initial: Bool = false, preservingMiniTop: Bool = false) {
        guard let window, !isClosing, !isShuttingDown else { return }
        let previousMode = committedMode
        let previousFrame = window.frame
        if previousMode == .main, !window.styleMask.contains(.fullScreen) { normalAppearance = Appearance(window) }
        cancelTransition()
        let id = UUID()
        transitionID = id
        isTransitioning = true
        mode = target
        let desiredMain = mainFrame ?? previousFrame
        let desiredMini = preservingMiniTop ? previousFrame : miniFrame
        layoutTask = Task { @MainActor [weak self, weak window] in
            // SwiftUI must replace the old minimum-sized content before AppKit shrinks it.
            for _ in 0..<2 {
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                guard let self, let window, self.isCurrent(id, window: window) else { return }
                self.applyAppearance(to: window, mode: target)
                window.contentView?.layoutSubtreeIfNeeded()
                let frame = self.targetFrame(for: target, window: window,
                                             main: desiredMain, mini: desiredMini, anchor: previousFrame)
                window.setFrame(frame, display: true, animate: false)
            }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            guard let self, let window, self.isCurrent(id, window: window) else { return }
            let expected = self.targetFrame(for: target, window: window,
                                            main: desiredMain, mini: desiredMini, anchor: previousFrame)
            guard abs(window.frame.width - expected.width) < 2,
                  abs(window.frame.height - expected.height) < 2 else {
                self.logRejectedLayout(expected: expected, target: target, window: window)
                let fallback: Mode = initial ? .main : previousMode
                self.mode = fallback
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                guard self.isCurrent(id, window: window) else { return }
                self.applyAppearance(to: window, mode: fallback)
                let fallbackFrame = self.targetFrame(for: fallback, window: window,
                    main: self.mainFrame ?? previousFrame, mini: self.miniFrame, anchor: previousFrame)
                window.setFrame(fallbackFrame, display: true, animate: false)
                self.committedMode = fallback
                self.defaults.set(fallback.rawValue, forKey: PreferenceKey.mode)
                self.cancelTransition()
                self.notice = "窗口尺寸未能正确切换，已恢复原界面，请重试。"
                self.logger.error("[error] [window.mode.layout] size rejected")
                return
            }
            self.committedMode = target
            if self.defaults.string(forKey: PreferenceKey.mode) != target.rawValue {
                self.defaults.set(target.rawValue, forKey: PreferenceKey.mode)
            }
            self.cancelTransition()
            self.saveCurrentFrame()
            if target != previousMode { self.notice = nil }
            self.logger.info("[window.mode.switch] mode=\(target.rawValue, privacy: .public)")
        }
    }

    private func logRejectedLayout(expected: NSRect, target: Mode, window: NSWindow) {
        let actual = NSStringFromRect(window.frame)
        let expected = NSStringFromRect(expected)
        let minimum = NSStringFromSize(window.contentMinSize)
        let maximum = NSStringFromSize(window.contentMaxSize)
        let bounds = window.contentView.map { NSStringFromRect($0.bounds) } ?? "nil"
        let fitting = window.contentView.map { NSStringFromSize($0.fittingSize) } ?? "nil"
        let style = window.styleMask.rawValue
        let toolbar = window.toolbar?.isVisible ?? false
        logger.error("[error] [window.mode.layout.geometry] mode=\(target.rawValue, privacy: .public) expected=\(expected, privacy: .public) actual=\(actual, privacy: .public) contentMin=\(minimum, privacy: .public) contentMax=\(maximum, privacy: .public) bounds=\(bounds, privacy: .public) fitting=\(fitting, privacy: .public) styleMask=\(style) toolbarVisible=\(toolbar)")
    }

    private func applyAppearance(to window: NSWindow, mode: Mode) {
        window.isMovableByWindowBackground = false
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if mode == .mini {
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbar?.isVisible = false
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
            window.collectionBehavior.insert(.fullScreenNone)
            window.level = isPinned ? .floating : .normal
            window.contentMinSize = NSSize(width: 480, height: miniContentHeight)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: miniContentHeight)
        } else {
            if let appearance = normalAppearance {
                window.styleMask = appearance.styleMask
                window.titleVisibility = appearance.titleVisibility
                window.titlebarAppearsTransparent = appearance.transparentTitlebar
                window.collectionBehavior = appearance.collectionBehavior
                if window.toolbar == nil { window.toolbar = appearance.toolbar }
                window.toolbar?.isVisible = appearance.toolbarVisible
                for (button, hidden) in appearance.buttonVisibility { window.standardWindowButton(button)?.isHidden = hidden }
                // A launch directly into mini may have already acquired SwiftUI's
                // compact height limit before this coordinator attaches.
                let minimum = effectiveContentMinimum(for: .main, in: window)
                window.contentMaxSize = NSSize(
                    width: appearance.contentMaxSize.width >= minimum.width ? appearance.contentMaxSize.width : CGFloat.greatestFiniteMagnitude,
                    height: appearance.contentMaxSize.height >= minimum.height ? appearance.contentMaxSize.height : CGFloat.greatestFiniteMagnitude)
            }
            window.level = .normal
            window.contentMinSize = effectiveContentMinimum(for: .main, in: window)
        }
    }

    private func effectiveContentMinimum(for mode: Mode, in window: NSWindow) -> NSSize {
        guard mode == .main else { return NSSize(width: 480, height: miniContentHeight) }
        // Only add chrome overlapping the content. Traditional titled windows
        // already add their external titlebar through frameRect(forContentRect:).
        let content = window.contentRect(forFrameRect: window.frame)
        let overlap = max(0, content.height - window.contentLayoutRect.height)
        return NSSize(width: 860, height: 620 + overlap)
    }

    private func targetFrame(for mode: Mode, window: NSWindow, main: NSRect,
                             mini: NSRect?, anchor: NSRect) -> NSRect {
        let contentMinimum = effectiveContentMinimum(for: mode, in: window)
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentMinimum)).size
        var proposed = main
        if mode == .mini {
            let width = max(mini?.width ?? 560, 480)
            let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: miniContentHeight)).size
            proposed = NSRect(x: mini?.minX ?? (anchor.maxX - size.width),
                              y: (mini?.maxY ?? anchor.maxY) - size.height, width: size.width, height: size.height)
        }
        var screens = NSScreen.screens
        if let current = window.screen, let index = screens.firstIndex(of: current) {
            screens.insert(screens.remove(at: index), at: 0)
        }
        return Self.correctedFrame(proposed, minimumSize: minimum, visibleFrames: screens.map(\.visibleFrame))
    }

    private func isCurrent(_ id: UUID, window: NSWindow) -> Bool {
        !isClosing && !isShuttingDown && transitionID == id && self.window === window
    }

    private func cancelTransition() {
        transitionID = nil
        fullScreenTarget = nil
        fullScreenInitial = false
        layoutTask?.cancel()
        layoutTask = nil
        fullScreenTimeout?.cancel()
        fullScreenTimeout = nil
        isTransitioning = false
    }

    private func saveCurrentFrame() {
        guard let window, !isTransitioning, !isFullScreenChanging,
              !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        var frame = window.frame
        if committedMode == .mini {
            let height = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: 96)).height
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            if miniFrame != frame {
                miniFrame = frame
                defaults.set(Self.encodeFrame(frame), forKey: PreferenceKey.miniFrame)
            }
        } else {
            if mainFrame != frame {
                mainFrame = frame
                defaults.set(Self.encodeFrame(frame), forKey: PreferenceKey.mainFrame)
            }
        }
    }

    private func scheduleFrameSave() {
        guard !isTransitioning, !isClosing, !isShuttingDown else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            self?.saveCurrentFrame()
        }
    }

    private func observe(_ name: Notification.Name, window: NSWindow,
                         action: @escaping @MainActor (WindowModeCoordinator) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, self.window === window, !self.isClosing, !self.isShuttingDown else { return }
                action(self)
            }
        })
    }

    private func installObservers(for window: NSWindow) {
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEndLiveResizeNotification, NSWindow.didChangeScreenNotification] {
            observe(name, window: window) { $0.scheduleFrameSave() }
        }
        observe(NSWindow.willEnterFullScreenNotification, window: window) {
            $0.saveCurrentFrame()
            if let window = $0.window { $0.beginNativeFullScreenTransition(.entering, window: window) }
        }
        observe(NSWindow.didEnterFullScreenNotification, window: window) { $0.finishNativeFullScreenTransition(matching: .entering) }
        observe(NSWindow.willExitFullScreenNotification, window: window) {
            if let window = $0.window { $0.beginNativeFullScreenTransition(.exiting, window: window) }
        }
        observe(NSWindow.didExitFullScreenNotification, window: window) {
            guard $0.finishNativeFullScreenTransition(matching: .exiting) else { return }
            if let target = $0.fullScreenTarget { $0.beginLayout(to: target, initial: $0.fullScreenInitial) }
            else { $0.scheduleFrameSave() }
        }
        observe(NSWindow.willCloseNotification, window: window) {
            if !$0.isTransitioning { $0.saveCurrentFrame() }
            $0.isClosing = true
            $0.cancelTransition()
            $0.removeObservers()
            $0.window = nil
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isTransitioning, !self.isClosing, !self.isShuttingDown,
                      let window = self.window, !window.styleMask.contains(.fullScreen) else { return }
                let contentMinimum = self.effectiveContentMinimum(for: self.mode, in: window)
                let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentMinimum)).size
                let corrected = Self.correctedFrame(window.frame, minimumSize: minimum,
                                                     visibleFrames: NSScreen.screens.map(\.visibleFrame))
                window.setFrame(corrected, display: true)
                self.scheduleFrameSave()
            }
        })
    }

    private func removeObservers() {
        clearNativeFullScreenTransition()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        saveTask?.cancel()
        saveTask = nil
    }

    private static func encodeFrame(_ frame: NSRect) -> [Double] { [frame.minX, frame.minY, frame.width, frame.height] }

    private static func decodeFrame(_ values: [Any]?) -> NSRect? {
        guard let values, values.count == 4 else { return nil }
        let numbers = values.compactMap { $0 as? Double }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else { return nil }
        return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// Pure screen correction: keeps a valid rectangle completely within the best matching visible screen.
    static func correctedFrame(_ frame: NSRect, minimumSize: NSSize, visibleFrames: [NSRect]) -> NSRect {
        func valid(_ value: NSRect) -> Bool {
            [value.minX, value.minY, value.width, value.height].allSatisfy(\.isFinite) && value.width > 0 && value.height > 0
        }
        let minimum = NSSize(width: minimumSize.width.isFinite ? max(minimumSize.width, 1) : 1,
                             height: minimumSize.height.isFinite ? max(minimumSize.height, 1) : 1)
        var result = valid(frame) ? frame : NSRect(origin: .zero, size: minimum)
        result.size.width = max(result.width, minimum.width)
        result.size.height = max(result.height, minimum.height)
        let screens = visibleFrames.filter(valid)
        guard var screen = screens.first else { return result }
        var largestArea: CGFloat = 0
        for candidate in screens {
            let overlap = result.intersection(candidate)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > largestArea { largestArea = area; screen = candidate }
        }
        result.size.width = min(result.width, screen.width)
        result.size.height = min(result.height, screen.height)
        result.origin.x = min(max(result.minX, screen.minX), screen.maxX - result.width)
        result.origin.y = min(max(result.minY, screen.minY), screen.maxY - result.height)
        return result
    }
}
