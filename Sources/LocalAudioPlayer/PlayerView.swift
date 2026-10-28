import SwiftUI
import AppKit
import AVFoundation

private enum PlayerStyle {
    static let accent = Color(red: 1, green: 0.18, blue: 0.34)
    static let selected = Color(red: 1, green: 0.93, blue: 0.95)
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let artwork = Bundle.main.url(forResource: "player-wave", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
}

struct PlayerView: View {
    @ObservedObject var controller: AudioPlayerController
    let keyboard: WindowKeyboardHandler
    @State private var settingsShown = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                nowPlaying(artHeight: min(330, max(160, geometry.size.height - 400)))
                    .frame(width: geometry.size.width * 0.5)
                Divider()
                playlist.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .background(PlayerStyle.canvas)
        .tint(PlayerStyle.accent)
        .overlay(alignment: .bottomTrailing) {
            if settingsShown {
                ZStack(alignment: .bottomTrailing) {
                    Color.black.opacity(0.001).onTapGesture { settingsShown = false }
                    PlaybackSettings(controller: controller)
                        .padding(22).frame(width: 320)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1)))
                        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
                        .padding(.trailing, 20).padding(.bottom, 74)
                }
            }
        }
        .onChange(of: settingsShown) { open in
            keyboard.shortcutsSuspended = open
            keyboard.cancelPress()
        }
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

    private func nowPlaying(artHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Group {
                if let artwork = PlayerStyle.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "waveform").font(.system(size: 80, weight: .ultraLight))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: artHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)

            Spacer(minLength: 20)
            Text(controller.isBoosting ? "\(String(format: "%g", controller.holdRate))× 倍速播放中" :
                    (controller.isPlaying ? "正在播放" : (controller.currentID == nil ? "准备好，开始收听" : "已暂停")))
                .font(.system(size: 14)).foregroundStyle(PlayerStyle.muted)
            Text(controller.currentItem?.url.deletingPathExtension().lastPathComponent ?? "你的本地声音")
                .font(.system(size: 28, weight: .semibold))
                .lineLimit(2).multilineTextAlignment(.center)
                .help(controller.currentItem?.name ?? "添加本地音频即可开始播放")
                .padding(.top, 12)
            Text(controller.currentItem.map { "本地音频 · \($0.url.pathExtension.uppercased())" } ?? "MP3、M4A、FLAC、WAV 等本地音频")
                .font(.system(size: 14)).foregroundStyle(PlayerStyle.muted)
                .padding(.top, 10)
            Spacer(minLength: 20)

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
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(PlayerStyle.muted)
            .padding(.top, 4)

            HStack(spacing: 28) {
                seekButton(backward: true)
                Button { controller.togglePlayback() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(PlayerStyle.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.isPlaying ? "暂停" : "播放")
                .help("空格键播放或暂停")
                .disabled(!controller.canPlay)
                .opacity(controller.canPlay ? 1 : 0.45)
                seekButton(backward: false)
            }
            .padding(.top, 20)
            Text("空格 播放/暂停 · → 长按倍速")
                .font(.system(size: 11)).foregroundStyle(PlayerStyle.muted)
                .padding(.top, 16)
        }
        .padding(.horizontal, 36)
        .padding(.top, 26)
        .padding(.bottom, 24)
    }

    private func seekButton(backward: Bool) -> some View {
        let seconds = backward ? controller.backwardSeconds : controller.forwardSeconds
        return Button { controller.seek(by: Double(seconds) * (backward ? -1 : 1)) } label: {
            VStack(spacing: 0) {
                Image(systemName: backward ? "arrow.counterclockwise" : "arrow.clockwise")
                    .font(.system(size: 20, weight: .medium))
                Text("\(seconds)").font(.system(size: 12, weight: .medium))
            }
            .frame(width: 56, height: 56)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(controller.currentID == nil)
        .accessibilityLabel("\(backward ? "后退" : "前进") \(seconds) 秒")
    }

    private var playlist: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("播放列表").font(.system(size: 20, weight: .semibold))
                    Text("\(controller.items.count) 个文件").font(.system(size: 11)).foregroundStyle(PlayerStyle.muted)
                }
                Spacer()
                Button { controller.chooseFiles(in: keyboard.window) } label: {
                    Label("添加音频", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(PlayerStyle.selected, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).foregroundStyle(PlayerStyle.accent)
                .disabled(controller.isChoosingFiles)
                Button { controller.removeSelected() } label: {
                    Image(systemName: "trash").font(.system(size: 15))
                        .frame(width: 34, height: 34)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除所选音频")
                .help("从列表移除，不删除原文件")
                .disabled(controller.selectedID == nil)
            }
            .padding(.horizontal, 24).padding(.vertical, 24)

            if controller.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list").font(.system(size: 32, weight: .light))
                    Text("还没有音频").font(.headline)
                    Text("点击右上角添加音频\n双击列表中的文件即可播放")
                        .font(.system(size: 12)).multilineTextAlignment(.center)
                }
                .foregroundStyle(PlayerStyle.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $controller.selectedID) {
                    ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                        AudioRow(item: item, index: index + 1,
                                 isCurrent: controller.currentID == item.id,
                                 isPlaying: controller.isPlaying)
                            .tag(item.id)
                            .listRowSeparator(.visible)
                            .listRowBackground(RoundedRectangle(cornerRadius: 10).fill(controller.currentID == item.id ? PlayerStyle.selected : Color.clear))
                            .onTapGesture(count: 2) { controller.playItem(item.id) }
                    }
                }
                .listStyle(.inset)
                .padding(.horizontal, 16)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("播放列表，双击音频开始播放")
            }
            Divider()
            HStack {
                Toggle("自动连播", isOn: $controller.autoAdvance).toggleStyle(.checkbox)
                    .help("当前音频结束后播放下一首，最后一首停止")
                Spacer()
                Button { settingsShown.toggle() } label: {
                    Label("播放设置", systemImage: "gearshape")
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
    }
}

private struct AudioRow: View {
    let item: PlaylistItem
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool
    @State private var duration: Double?
    @State private var durationUnavailable = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isCurrent { Image(systemName: isPlaying ? "waveform" : "pause.fill") }
                else { Text("\(index)").monospacedDigit() }
            }
            .font(.system(size: 12)).frame(width: 18)
            .foregroundStyle(isCurrent ? PlayerStyle.accent : PlayerStyle.muted)
            Image(systemName: "music.note").font(.system(size: 20))
                .foregroundStyle(PlayerStyle.muted)
                .frame(width: 36, height: 36)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            Text(item.name).font(.system(size: 13, weight: isCurrent ? .medium : .regular))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(isCurrent ? PlayerStyle.accent : Color.primary)
            Spacer(minLength: 8)
            Text(duration.map { PlaybackRules.timeLabel($0.rounded()) } ?? "—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isCurrent ? PlayerStyle.accent : PlayerStyle.muted)
                .help(durationUnavailable ? "无法读取时长，播放时将重新检查文件" : "音频时长")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(item.url.path)
        .task(id: item.id) {
            do {
                let value: Double
                if AudioFileTypes.isOgg(item.url) {
                    value = try await OggMetadata.shared.duration(of: item.url)
                } else {
                    value = try await AVURLAsset(url: item.url).load(.duration).seconds
                }
                guard !Task.isCancelled else { return }
                if value.isFinite, value > 0 { duration = value }
                else { durationUnavailable = true }
            } catch {
                if !Task.isCancelled { durationUnavailable = true }
            }
        }
    }
}

private struct PlaybackSettings: View {
    @ObservedObject var controller: AudioPlayerController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("播放设置").font(.system(size: 17, weight: .semibold))
            HStack {
                Text("后退").frame(width: 36, alignment: .leading)
                TextField("秒", value: $controller.backwardSeconds, format: .number).frame(width: 65)
                Stepper("秒", value: $controller.backwardSeconds, in: 1...600)
            }
            HStack {
                Text("前进").frame(width: 36, alignment: .leading)
                TextField("秒", value: $controller.forwardSeconds, format: .number).frame(width: 65)
                Stepper("秒", value: $controller.forwardSeconds, in: 1...600)
            }
            Text("长按倍速").font(.system(size: 12)).foregroundStyle(PlayerStyle.muted)
            Picker("长按倍速", selection: $controller.holdRate) {
                ForEach([Float(1.25), 1.5, 1.75, 2], id: \.self) { rate in
                    Text(String(format: "%g×", rate)).tag(rate)
                }
            }
            .labelsHidden().pickerStyle(.segmented)
            .disabled(controller.isBoosting)
            Text("播放时长按 →，松开恢复正常速度\n秒数范围 1–600，设置本次运行生效")
                .font(.system(size: 11)).foregroundStyle(PlayerStyle.muted)
        }
        .tint(PlayerStyle.accent)
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
