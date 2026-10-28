import AppKit

@MainActor
final class WindowKeyboardHandler {
    private var monitor: Any?
    weak var window: NSWindow?

    static func offset(for event: NSEvent) -> Double? {
        guard event.type == .keyDown,
              !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch event.keyCode {
        case 123: return -5
        case 124: return 5
        default: return nil
        }
    }

    func install(for window: NSWindow, controller: AudioPlayerController) {
        uninstall()
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak controller] event in
            guard let self, let window = self.window, let controller,
                  window.isKeyWindow, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !controller.isChoosingFiles, controller.errorMessage == nil else { return event }
            guard event.keyCode == 123 || event.keyCode == 124,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            // Consume repeats too, so focused sliders/lists cannot handle them a second time.
            if let offset = Self.offset(for: event) { controller.seek(by: offset) }
            return nil
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window = nil
    }
}
