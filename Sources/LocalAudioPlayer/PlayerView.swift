import SwiftUI
import AppKit

struct PlayerView: View {
    @ObservedObject var controller: AudioPlayerController
    let keyboard: WindowKeyboardHandler
    private enum SettingField: Hashable { case backward, forward }
    @FocusState private var editingSetting: SettingField?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { controller.chooseFiles(in: keyboard.window) } label: {
                    Label("添加音频", systemImage: "plus")
                }
                .disabled(controller.isChoosingFiles)
                Button { controller.removeSelected() } label: {
                    Image(systemName: "minus")
                }
                .help("从列表移除所选音频，不删除原文件")
                .accessibilityLabel("移除所选音频")
                .disabled(controller.selectedID == nil)
                Spacer()
                Toggle("自动连播", isOn: $controller.autoAdvance)
                    .toggleStyle(.checkbox)
                    .help("播放结束后按列表顺序播放下一首，最后一首播完停止")
            }
            .padding(16)

            Divider()
            if controller.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("添加音频，开始收听").font(.headline)
                    Text("支持 M4A、MP3、WAV 等本地音频")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $controller.selectedID) {
                    ForEach(controller.items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: controller.currentID == item.id
                                  ? (controller.isPlaying ? "speaker.wave.2.fill" : "pause.fill") : "music.note")
                                .foregroundStyle(controller.currentID == item.id ? Color.accentColor : Color.secondary)
                                .frame(width: 20)
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .help(item.url.path)
                        .tag(item.id)
                        .onTapGesture(count: 2) { editingSetting = nil; controller.playItem(item.id) }
                        .simultaneousGesture(TapGesture().onEnded { editingSetting = nil })
                    }
                }
                .listStyle(.inset)
                .accessibilityLabel("播放列表，双击音频开始播放")
            }
            Divider()

            VStack(spacing: 12) {
                HStack {
                    Text(controller.currentItem?.name ?? "尚未播放")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(controller.items.count) 首")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { controller.position }, set: { controller.seek(to: $0) }),
                       in: 0...max(controller.duration, 0.001))
                    .disabled(controller.currentID == nil)
                    .accessibilityLabel("播放进度")
                    .accessibilityValue("\(PlaybackRules.timeLabel(controller.position))，共 \(PlaybackRules.timeLabel(controller.duration))")
                HStack {
                    Text(PlaybackRules.timeLabel(controller.position))
                    Spacer()
                    Text(PlaybackRules.timeLabel(controller.duration))
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, -8)

                Button { editingSetting = nil; controller.togglePlayback() } label: {
                    Label(controller.isPlaying ? "暂停" : "播放", systemImage: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 84)
                }
                .controlSize(.large)
                .disabled(!controller.canPlay)

                HStack {
                    Text("后退")
                    TextField("秒", value: $controller.backwardSeconds, format: .number).frame(width: 50).focused($editingSetting, equals: .backward)
                    Text("秒 · 前进")
                    TextField("秒", value: $controller.forwardSeconds, format: .number).frame(width: 50).focused($editingSetting, equals: .forward)
                    Text("秒")
                }
                Picker("长按倍速", selection: $controller.holdRate) {
                    ForEach([Float(1.25), 1.5, 1.75, 2], id: \.self) { rate in
                        Text(String(format: "%.2g×", rate)).tag(rate)
                    }
                }
                .frame(width: 200)
                .disabled(controller.isBoosting)
                Text(controller.isBoosting ? "倍速播放中，松开 → 恢复正常速度" : "空格 播放/暂停 · ← 后退 · → 短按前进，播放时长按倍速")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(minWidth: 440, minHeight: 480)
        .background(WindowAttachment { window in
            keyboard.install(for: window, controller: controller)
        })
        .alert("无法播放音频", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }
}

private struct WindowAttachment: NSViewRepresentable {
    let attached: (NSWindow) -> Void

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.attached = attached
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {}

    final class AttachmentView: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attached?(window) }
        }
    }
}
