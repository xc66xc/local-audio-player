import AppKit

@MainActor
final class WindowKeyboardHandler {
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var holdTask: Task<Void, Never>?
    private var rightDown = false
    private var held = false
    private weak var controller: AudioPlayerController?
    weak var window: NSWindow?

    static func offset(for event: NSEvent) -> Double? {
        guard event.type == .keyDown, !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch event.keyCode {
        case 123: return -5
        case 124: return 5
        default: return nil
        }
    }

    func pressRight(controller: AudioPlayerController) {
        guard !rightDown else { return }
        self.controller = controller
        rightDown = true
        held = false
        holdTask = Task { @MainActor [weak self, weak controller] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self, self.rightDown else { return }
            self.held = true
            controller?.beginBoost()
        }
    }

    func releaseRight() {
        guard rightDown else { return }
        let shouldSeek = !held
        holdTask?.cancel()
        holdTask = nil
        rightDown = false
        held = false
        controller?.endBoost()
        if shouldSeek, let controller { controller.seek(by: Double(controller.forwardSeconds)) }
    }

    func cancelPress() {
        holdTask?.cancel()
        holdTask = nil
        rightDown = false
        held = false
        controller?.endBoost()
    }

    func install(for window: NSWindow, controller: AudioPlayerController) {
        uninstall()
        self.window = window
        self.controller = controller
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self else { return }
                    if name == NSApplication.didResignActiveNotification || (note.object as? NSWindow) === self.window {
                        self.cancelPress()
                    }
                }
            })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak controller] event in
            guard let self, let controller else { return event }
            if event.type == .keyUp, event.keyCode == 124, self.rightDown {
                self.releaseRight()
                return nil
            }
            guard let window = self.window, window.isKeyWindow, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !controller.isChoosingFiles, controller.errorMessage == nil else {
                self.cancelPress()
                return event
            }
            guard !(window.firstResponder is NSTextView) else { self.cancelPress(); return event }
            guard event.type == .keyDown,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            switch event.keyCode {
            case 49:
                if !event.isARepeat { controller.togglePlayback() }
            case 123:
                if !event.isARepeat { controller.seek(by: -Double(controller.backwardSeconds)) }
            case 124:
                if !event.isARepeat { self.pressRight(controller: controller) }
            default: return event
            }
            return nil
        }
    }

    func uninstall() {
        cancelPress()
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        monitor = nil
        window = nil
        controller = nil
    }
}
