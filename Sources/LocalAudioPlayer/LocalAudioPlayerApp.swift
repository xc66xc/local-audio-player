import SwiftUI
import AppKit

@main
struct LocalAudioPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("本地音频播放器", id: "player") {
            PlayerView(controller: delegate.controller, keyboard: delegate.keyboard)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加音频…") { delegate.controller.chooseFiles(in: delegate.keyboard.window) }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AudioPlayerController()
    let keyboard = WindowKeyboardHandler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        keyboard.uninstall()
        controller.shutdown()
    }
}
