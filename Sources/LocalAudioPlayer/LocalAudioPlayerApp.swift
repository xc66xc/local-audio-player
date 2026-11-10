import SwiftUI
import AppKit
import OSLog

@main
struct LocalAudioPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Sona", id: "player") {
            PlayerWindowShell(controller: delegate.controller, keyboard: delegate.keyboard, windowMode: delegate.windowMode)
        }
        .defaultSize(width: delegate.windowMode.preferredInitialSize.width,
                     height: delegate.windowMode.preferredInitialSize.height)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            PlayerCommands(controller: delegate.controller, windowMode: delegate.windowMode, keyboard: delegate.keyboard)
        }
    }
}

/// Keep Scene's automatic sizing separate from the two native window geometries.
private struct PlayerWindowShell: View {
    @ObservedObject var controller: AudioPlayerController
    let keyboard: WindowKeyboardHandler
    @ObservedObject var windowMode: WindowModeCoordinator

    var body: some View {
        PlayerWindowHost(controller: controller, keyboard: keyboard, windowMode: windowMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
            .toolbar {
                if !windowMode.isMini {
                    ToolbarItem(placement: .primaryAction) {
                        Button { windowMode.toggle() } label: { Image(systemName: "pip.enter") }
                            .help("切换到小窗模式（⌘⇧M）")
                            .accessibilityLabel("切换到小窗模式")
                            .disabled(controller.isRestoring || controller.isChoosingFiles ||
                                      controller.errorMessage != nil || windowMode.isTransitioning)
                    }
                }
            }
            .toolbar(windowMode.isMini ? .hidden : .automatic, for: .windowToolbar)
            .toolbarBackground(windowMode.isMini ? .hidden : .automatic, for: .windowToolbar)
    }
}

private struct PlayerWindowHost: NSViewRepresentable {
    let controller: AudioPlayerController
    let keyboard: WindowKeyboardHandler
    let windowMode: WindowModeCoordinator

    func makeNSView(context: Context) -> NSHostingView<PlayerView> {
        let host = NSHostingView(rootView: PlayerView(controller: controller, keyboard: keyboard, windowMode: windowMode))
        // AppKit's coordinator owns min/max sizes. Propagating the inner minimum to
        // Scene would add its titlebar inset again when using fullSizeContentView.
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ nsView: NSHostingView<PlayerView>, context: Context) {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AudioPlayerController(sessionStore: .applicationStore())
    let keyboard = WindowKeyboardHandler()
    let windowMode = WindowModeCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        } else {
            Logger(subsystem: "local.miniaudio.player", category: "Appearance")
                .error("无法加载应用图标 AppIcon.icns")
        }
        Task { await controller.restoreSession() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        windowMode.shutdown()
        keyboard.uninstall()
        controller.shutdown()
    }
}

private struct PlayerCommands: Commands {
    @ObservedObject var controller: AudioPlayerController
    @ObservedObject var windowMode: WindowModeCoordinator
    let keyboard: WindowKeyboardHandler

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加音频…") { controller.chooseFiles(in: keyboard.window) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(controller.isRestoring || controller.isChoosingFiles)
        }
        CommandGroup(after: .windowArrangement) {
            Button(windowMode.isMini ? "返回主窗口" : "切换到小窗模式") { windowMode.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(controller.isRestoring || controller.isChoosingFiles || controller.errorMessage != nil ||
                          windowMode.isTransitioning)
        }
    }
}
