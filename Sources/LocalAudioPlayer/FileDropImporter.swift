import AppKit
import Combine
import OSLog
import UniformTypeIdentifiers

/// Owns the temporary read grant while asynchronous file URLs are being collected.
/// The controller takes its own grant before accepted references leave this scope.
final class ScopedDropFile: @unchecked Sendable {
    let url: URL
    private let accessed: Bool

    init?(url: URL) {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
    }

    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}

@MainActor
final class FileDropImporter: ObservableObject {
    @Published private(set) var isLoading = false
    @Published var feedback: String?
    private var requestID: UUID?
    private var providers: [NSItemProvider] = []
    private var nextIndex = 0
    private var inFlight = 0
    private var completed = 0
    private var rejected = 0
    private var results: [Int: ScopedDropFile] = [:]
    private var received: Set<Int> = []
    private var completion: (([ScopedDropFile], Int) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private let timeout: TimeInterval
    private let logger = Logger(subsystem: "local.miniaudio.player", category: "Drop")

    init(timeout: TimeInterval = 8) { self.timeout = timeout }

    @discardableResult
    func start(_ items: [NSItemProvider], completion: @escaping ([ScopedDropFile], Int) -> Void) -> Bool {
        cancel()
        let supported = items.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !supported.isEmpty else { return false }
        let token = UUID()
        requestID = token
        providers = supported
        rejected = items.count - supported.count
        self.completion = completion
        isLoading = true
        feedback = nil
        logger.info("[drop.begin] batch=\(token.uuidString) count=\(items.count)")
        timeoutTask = Task { @MainActor [weak self] in
            guard let seconds = self?.timeout else { return }
            do { try await Task.sleep(nanoseconds: UInt64(max(0.01, seconds) * 1_000_000_000)) } catch { return }
            guard let self, self.requestID == token else { return }
            self.cancel()
            self.feedback = "读取拖入文件超时，请从 Finder 重新拖入本地音频。"
            self.logger.error("[error] [drop.timeout] batch=\(token.uuidString)")
        }
        pump(token)
        return true
    }

    func cancel() {
        guard let token = requestID else { return }
        logger.info("[drop.cancel] batch=\(token.uuidString)")
        reset()
    }

    private func reset() {
        requestID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        providers.removeAll()
        results.removeAll()
        received.removeAll()
        completion = nil
        nextIndex = 0
        inFlight = 0
        completed = 0
        rejected = 0
        isLoading = false
    }

    private func pump(_ token: UUID) {
        guard requestID == token else { return }
        // Resolve only references, with bounded concurrency; never materialize audio copies.
        while inFlight < 8, nextIndex < providers.count {
            let index = nextIndex
            let provider = providers[index]
            nextIndex += 1
            inFlight += 1
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] value, error in
                let url: URL?
                if error != nil { url = nil }
                else if let supplied = value as? URL { url = supplied }
                else if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let text = value as? String { url = URL(string: text) }
                else { url = nil }
                let file = url.flatMap { ScopedDropFile(url: $0) }
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == token else { return }
                    if let error {
                        self.logger.error("[error] [drop.resolve] batch=\(token.uuidString) \(String(describing: error), privacy: .private)")
                    }
                    self.record(file, index: index, token: token)
                }
            }
        }
    }

    private func record(_ file: ScopedDropFile?, index: Int, token: UUID) {
        guard requestID == token, received.insert(index).inserted else { return }
        inFlight -= 1
        completed += 1
        if let file { results[index] = file } else { rejected += 1 }
        if completed == providers.count {
            let files = results.sorted { $0.key < $1.key }.map(\.value)
            let skipped = rejected
            let callback = completion
            // Clear the active batch before calling controller APIs that cancel pending input.
            reset()
            callback?(files, skipped)
            logger.info("[drop.resolved] batch=\(token.uuidString) files=\(files.count) rejected=\(skipped)")
        } else { pump(token) }
    }
}
