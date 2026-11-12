import SwiftUI
import AppKit

struct MiniPlayerView: View {
    @ObservedObject var controller: AudioPlayerController
    @ObservedObject var windowMode: WindowModeCoordinator
    let keyboard: WindowKeyboardHandler

    private var displayedItem: PlaylistItem? {
        controller.currentItem ?? controller.items.first { $0.id == controller.selectedID }
    }

    private var resumeOffer: PendingResume? {
        guard let offer = controller.pendingResume, offer.itemID == controller.currentID,
              controller.currentItem?.isUnavailable == false else { return nil }
        return offer
    }

    private var status: String {
        if controller.currentItem?.isUnavailable == true { return "文件不可用" }
        if controller.isBoosting { return "\(String(format: "%g", controller.holdRate))× 倍速播放中" }
        if controller.isPlaying { return "正在播放" }
        return controller.currentID == nil ? "准备播放" : "已暂停"
    }

    var body: some View {
        VStack(spacing: 0) {
            mainStrip
                .frame(height: 96)
            if let offer = resumeOffer {
                resumeReminder(offer)
                    .frame(height: 28)
            }
        }
        .background(PlayerStyle.canvas)
        .tint(PlayerStyle.accent)
    }

    private var mainStrip: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(spacing: 0) {
                Button {
                    keyboard.cancelPress()
                    windowMode.closeWindow()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PlayerStyle.muted)
                .accessibilityLabel("关闭 Sona")
                .help("保存播放进度并退出 Sona")
                MiniWindowDragRegion()
            }
            .frame(width: 18)

            artwork
                .frame(width: 46)
                .frame(maxHeight: .infinity, alignment: .center)
                .background(MiniWindowDragRegion())

            VStack(spacing: 3) {
                HStack(spacing: 10) {
                    trackInformation
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    transport
                    windowButtons
                }
                .frame(height: 42)

                Slider(value: Binding(get: { controller.position }, set: { controller.seek(to: $0) }),
                       in: 0...max(controller.duration, 0.001))
                    .controlSize(.mini)
                    .frame(height: 12)
                    .disabled(controller.currentID == nil)
                    .accessibilityLabel("播放进度")
                    .accessibilityValue("\(PlaybackRules.timeLabel(controller.position))，共 \(PlaybackRules.timeLabel(controller.duration))")

                HStack {
                    Text(PlaybackRules.timeLabel(controller.position))
                    Spacer(minLength: 8)
                    Text(PlaybackRules.timeLabel(controller.duration))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(PlayerStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var artwork: some View {
        Group {
            if let artwork = PlayerStyle.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(PlayerStyle.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(width: 46, height: 46)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var trackInformation: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let item = displayedItem {
                Text(item.url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.name)
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(PlayerStyle.muted)
                    .lineLimit(1)
            } else {
                Button("添加音频") { controller.chooseFiles(in: keyboard.window) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PlayerStyle.accent)
                    .disabled(controller.isChoosingFiles)
                Text("或拖入音频，松开即播")
                    .font(.system(size: 10))
                    .foregroundStyle(PlayerStyle.muted)
                    .lineLimit(1)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                keyboard.cancelPress()
                controller.restartPlayback()
            } label: {
                Image(systemName: "arrow.backward.to.line")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(controller.currentID == nil)
            .opacity(controller.currentID == nil ? 0.45 : 1)
            .accessibilityLabel("重新播放")
            .help("重新播放：从头播放当前音频")
            seekButton(backward: true)
            Button {
                keyboard.cancelPress()
                controller.togglePlayback()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(PlayerStyle.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!controller.canPlay)
            .opacity(controller.canPlay ? 1 : 0.45)
            .accessibilityLabel(controller.isPlaying ? "暂停" : "播放")
            .help("空格键播放或暂停")
            seekButton(backward: false)
        }
        .fixedSize()
    }

    private func seekButton(backward: Bool) -> some View {
        let seconds = backward ? controller.backwardSeconds : controller.forwardSeconds
        return Button {
            keyboard.cancelPress()
            controller.seek(by: Double(seconds) * (backward ? -1 : 1))
        } label: {
            VStack(spacing: 0) {
                Image(systemName: backward ? "arrow.counterclockwise" : "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                Text("\(seconds)")
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
            }
            .frame(width: 30, height: 30)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(controller.currentID == nil)
        .accessibilityLabel("\(backward ? "后退" : "前进") \(seconds) 秒")
    }

    private var windowButtons: some View {
        HStack(spacing: 6) {
            Button {
                keyboard.cancelPress()
                windowMode.togglePinned()
            } label: {
                Image(systemName: windowMode.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(windowMode.isPinned ? PlayerStyle.accent : PlayerStyle.muted)
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(windowMode.isPinned ? "取消小窗置顶" : "小窗置顶")
            .help(windowMode.isPinned ? "已置顶，点击取消" : "点击让小窗置顶")

            Button {
                keyboard.cancelPress()
                windowMode.toggle()
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PlayerStyle.muted)
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(windowMode.isTransitioning)
            .accessibilityLabel("展开主窗口")
            .help("返回主窗口（Command-Shift-M）")
        }
        .fixedSize()
    }

    private func resumeReminder(_ offer: PendingResume) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .accessibilityHidden(true)
            Text("上次听到 \(PlaybackRules.timeLabel(offer.position))")
                .monospacedDigit()
            Spacer(minLength: 8)
            Button {
                guard controller.pendingResume?.itemID == offer.itemID, controller.currentID == offer.itemID else { return }
                keyboard.cancelPress()
                controller.acceptResume()
            } label: {
                Text("点击跳转")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(PlayerStyle.accent, lineWidth: 0.8))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(PlayerStyle.accent)
            .accessibilityLabel("跳转到上次收听位置，\(PlaybackRules.timeLabel(offer.position))")
            Button {
                guard controller.pendingResume?.itemID == offer.itemID, controller.currentID == offer.itemID else { return }
                keyboard.cancelPress()
                controller.dismissResume()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("忽略上次收听位置")
            .help("采用本次收听进度")
        }
        .font(.system(size: 10))
        .foregroundStyle(PlayerStyle.muted)
        .padding(.horizontal, 12)
        .background(PlayerStyle.selected)
    }
}

/// Only the artwork and its surrounding blank gutter accept window dragging.
/// Buttons, title actions and the progress slider remain outside this view.
private struct MiniWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
