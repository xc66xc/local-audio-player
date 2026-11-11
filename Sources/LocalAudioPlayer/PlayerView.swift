import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum PlayerStyle {
    static let accent = Color(red: 1, green: 0.18, blue: 0.34)
    static let selected = Color(red: 1, green: 0.93, blue: 0.95)
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let artwork = Bundle.main.url(forResource: "player-wave", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
}

struct PlayerView: View {
    @ObservedObject var controller: AudioPlayerController
    @ObservedObject var windowMode: WindowModeCoordinator
    let keyboard: WindowKeyboardHandler
    @State private var settingsShown = false
    @State private var isDropTargeted = false
    @State private var feedbackDetail: String?
    @ObservedObject private var fileDrop: FileDropImporter

    init(controller: AudioPlayerController, keyboard: WindowKeyboardHandler, windowMode: WindowModeCoordinator) {
        self.controller = controller
        self.keyboard = keyboard
        self.windowMode = windowMode
        fileDrop = controller.fileDrop
    }

    private var canReceiveDrop: Bool {
        controller.canImportDroppedFiles && keyboard.window?.isVisible == true &&
            keyboard.window?.attachedSheet == nil && NSApp.modalWindow == nil
    }

    private var hasResumeReminder: Bool {
        controller.pendingResume?.itemID == controller.currentID && controller.pendingResume != nil &&
            controller.currentItem?.isUnavailable == false
    }

    private var miniStatusMessage: String? {
        if fileDrop.isLoading { return "正在添加音频…" }
        if controller.isPreparingAudio { return "正在打开音频…" }
        return windowMode.notice ?? controller.sessionNotice ?? fileDrop.feedback
    }

    private var isOpeningAudio: Bool { fileDrop.isLoading || controller.isPreparingAudio }

    private func cancelOpeningAudio() {
        fileDrop.cancel()
        controller.cancelAudioPreparation()
    }

    private var miniSupplementHeight: CGFloat {
        (hasResumeReminder ? 28 : 0) + (miniStatusMessage != nil ? 28 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            if windowMode.isMini {
                MiniPlayerView(controller: controller, windowMode: windowMode, keyboard: keyboard)
                if let message = miniStatusMessage { miniFeedbackBar(message) }
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        nowPlaying(artHeight: min(330, max(160, geometry.size.height - 400)))
                            .frame(width: geometry.size.width * 0.5)
                        Divider()
                        playlist.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: windowMode.isMini ? 480 : 860,
               minHeight: windowMode.isMini ? 96 + miniSupplementHeight : 620,
               maxHeight: windowMode.isMini ? 96 + miniSupplementHeight : .infinity)
        .ignoresSafeArea(.container, edges: windowMode.isMini ? .top : [])
        .background(PlayerStyle.canvas)
        .tint(PlayerStyle.accent)
        .disabled(controller.isRestoring)
        .overlay(alignment: .top) {
            if !windowMode.isMini {
                VStack(spacing: 6) {
                    if let notice = windowMode.notice {
                        feedbackBanner(notice) { windowMode.notice = nil }
                    }
                    if let notice = controller.sessionNotice {
                        feedbackBanner(notice) { controller.sessionNotice = nil }
                    }
                    if isOpeningAudio {
                        feedbackBanner(fileDrop.isLoading ? "正在添加音频…" : "正在打开音频…", closeTitle: "取消") {
                            cancelOpeningAudio()
                        }
                    } else if let feedback = fileDrop.feedback {
                        feedbackBanner(feedback) { fileDrop.feedback = nil }
                    }
                }.padding(12)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if settingsShown && !windowMode.isMini {
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
        .overlay {
            if isDropTargeted && canReceiveDrop {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(PlayerStyle.accent.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PlayerStyle.accent, lineWidth: 2))
                    VStack(spacing: windowMode.isMini ? 0 : 12) {
                        if !windowMode.isMini {
                            Image(systemName: "arrow.down.doc").font(.system(size: 30, weight: .medium))
                        }
                        Text("松开即可播放").font(.system(size: windowMode.isMini ? 15 : 22, weight: .semibold))
                        if !windowMode.isMini {
                            Text("拖入本地音频，自动加入播放列表").font(.system(size: 13))
                        }
                    }
                    .foregroundStyle(PlayerStyle.accent)
                    .padding(windowMode.isMini ? 12 : 28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(10)
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            guard canReceiveDrop else { return false }
            let window = keyboard.window
            return controller.receiveDroppedFiles(providers, canAccept: { [weak window] in
                window?.isVisible == true && window?.attachedSheet == nil && NSApp.modalWindow == nil
            }, beforePlayback: {
                settingsShown = false
                keyboard.cancelPress()
            })
        }
        .onDisappear { fileDrop.cancel(); keyboard.shortcutsSuspended = false }
        .onAppear { windowMode.updateMiniSupplementHeight(miniSupplementHeight) }
        .onChange(of: miniSupplementHeight) { windowMode.updateMiniSupplementHeight($0) }
        .onChange(of: settingsShown) { open in
            keyboard.shortcutsSuspended = open
            keyboard.cancelPress()
        }
        .background(WindowAttachment { window in
            if keyboard.window !== window { keyboard.install(for: window, controller: controller) }
            windowMode.onWillSwitch = {
                settingsShown = false
                keyboard.cancelPress()
                keyboard.shortcutsSuspended = false
            }
            windowMode.attach(to: window)
        })
        .alert(controller.errorMessage != nil ? "操作未完成" : "播放提示", isPresented: Binding(
            get: { controller.errorMessage != nil || feedbackDetail != nil },
            set: { if !$0 { controller.errorMessage = nil; feedbackDetail = nil } }
        )) {
            Button("好", role: .cancel) { controller.errorMessage = nil; feedbackDetail = nil }
        } message: { Text(controller.errorMessage ?? feedbackDetail ?? "") }
    }

    private func miniFeedbackBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isOpeningAudio ? "arrow.down.doc" : "info.circle")
                .accessibilityHidden(true)
            Text(message).lineLimit(1).truncationMode(.tail).help(message)
            Spacer(minLength: 0)
            Button(isOpeningAudio ? "取消" : "详情") {
                if isOpeningAudio { cancelOpeningAudio() } else { feedbackDetail = message }
            }.buttonStyle(.borderless)
            if !isOpeningAudio {
                Button {
                    if windowMode.notice != nil { windowMode.notice = nil }
                    else if controller.sessionNotice != nil { controller.sessionNotice = nil }
                    else { fileDrop.feedback = nil }
                } label: {
                    Image(systemName: "xmark").frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless).accessibilityLabel("关闭当前提示")
            }
        }
        .font(.system(size: 11)).foregroundStyle(PlayerStyle.muted)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func feedbackBanner(_ message: String, closeTitle: String = "关闭", close: @escaping () -> Void) -> some View {
        HStack {
            Text(message).font(.system(size: 12))
            Button(closeTitle, action: close)
        }
        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
                    Text("点击右上角添加，或将音频拖入窗口\n松开即可播放")
                        .font(.system(size: 12)).multilineTextAlignment(.center)
                }
                .foregroundStyle(PlayerStyle.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { controller.selectedID }, set: { controller.selectItem($0) })) {
                    ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                        AudioRow(item: item, index: index + 1,
                                 isCurrent: controller.currentID == item.id,
                                 isPlaying: controller.isPlaying,
                                 currentDuration: controller.currentID == item.id && controller.duration > 0 ? controller.duration : nil,
                                 resumePosition: controller.pendingResume.flatMap { $0.itemID == item.id ? $0.position : nil },
                                 acceptResume: {
                                     guard controller.currentID == item.id, controller.pendingResume?.itemID == item.id else { return }
                                     keyboard.cancelPress()
                                     controller.acceptResume()
                                 },
                                 dismissResume: {
                                     guard controller.currentID == item.id, controller.pendingResume?.itemID == item.id else { return }
                                     keyboard.cancelPress()
                                     controller.dismissResume()
                                 },
                                 play: { controller.playItem(item.id) },
                                 relocate: { controller.chooseReplacement(for: item.id, in: keyboard.window) })
                            .contextMenu {
                                Button("在 Finder 中显示") { controller.showInFinder(item.id) }
                                Button("重命名…") { controller.chooseRename(for: item.id, in: keyboard.window) }
                                Button("重新定位文件…") { controller.chooseReplacement(for: item.id, in: keyboard.window) }
                                Button("从列表移除") { controller.selectedID = item.id; controller.removeSelected() }
                            }
                            .tag(item.id)
                            .listRowSeparator(.visible)
                            // Inset lists draw native selection/context-menu outlines
                            // inside the row; keep the current-track fill on that edge.
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(controller.currentID == item.id ? PlayerStyle.selected : Color.clear)
                                    .padding(.horizontal, 10)
                            )
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
    let currentDuration: TimeInterval?
    let resumePosition: TimeInterval?
    let acceptResume: () -> Void
    let dismissResume: () -> Void
    let play: () -> Void
    let relocate: () -> Void
    @State private var duration: Double?
    @State private var durationUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                if item.isUnavailable {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("文件不可用").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("重新定位", action: relocate).buttonStyle(.borderless).font(.system(size: 11))
                    }
                }
                Text((currentDuration ?? duration).map { PlaybackRules.timeLabel($0.rounded()) } ?? "—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isCurrent ? PlayerStyle.accent : PlayerStyle.muted)
                    .fixedSize()
                    .help(durationUnavailable ? "无法读取时长，播放时将重新检查文件" :
                          AudioFileTypes.isNcm(item.url) && duration == nil && currentDuration == nil ? "首次打开后显示时长" : "音频时长")
            }
            .contentShape(Rectangle())
            // Keep the double-click gesture off the reminder's buttons.
            .onTapGesture(count: 2, perform: play)

            if isCurrent, !item.isUnavailable, let resumePosition {
                resumeReminder(at: resumePosition)
                    .padding(.leading, 78)
            }
        }
        .padding(.vertical, isCurrent && resumePosition != nil ? 8 : 4)
        .contentShape(Rectangle())
        .help(item.url.path)
        .task(id: item) {
            duration = nil
            durationUnavailable = false
            guard !item.isUnavailable else { durationUnavailable = true; return }
            if AudioFileTypes.isNcm(item.url) {
                duration = currentDuration
                return
            }
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
        .onChange(of: currentDuration) { value in
            if let value, value > 0 { duration = value }
        }
    }

    private func resumeReminder(at position: TimeInterval) -> some View {
        let time = PlaybackRules.timeLabel(position)
        return HStack(spacing: 8) {
            Label {
                Text("上次听到 \(time)").monospacedDigit()
            } icon: {
                Image(systemName: "clock").accessibilityHidden(true)
            }
            .font(.system(size: 11))
            .foregroundStyle(PlayerStyle.muted)
            .fixedSize()
            Button(action: acceptResume) {
                Text("点击跳转")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(PlayerStyle.accent, lineWidth: 0.8))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(PlayerStyle.accent)
            .fixedSize()
            .accessibilityLabel("跳转到上次收听位置，\(time)")
            .help("跳转到 \(time)，保持当前播放或暂停状态")
            Spacer(minLength: 0)
            Button(action: dismissResume) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(PlayerStyle.muted)
            .accessibilityLabel("忽略上次收听位置")
            .help("忽略上次位置，记录这次的收听进度")
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
            Text("播放时长按 →，松开恢复正常速度\n秒数范围 1–600，设置自动保存")
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
