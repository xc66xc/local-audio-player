import Darwin
import Foundation

private let cliVersion = "1.0.0"

private let usage = """
用法: ncm-restore [选项] <文件或目录> [更多文件或目录 ...]

恢复 NCM 中原始的 MP3/FLAC 数据，不转码，不覆盖已有文件。

选项:
  -o, --output <目录>  指定输出目录
  --no-recursive       仅扫描输入目录的第一层（默认递归）
  --strict-crc         将 legacy NCM 的 CRC 不匹配视为错误
  --json               stdout 输出一个完整 JSON 对象，进度写入 stderr
  -h, --help           显示帮助
  --version            显示版本
  --                   后续参数均作为输入路径

默认输出: 第一个输入目录旁的 NCM还原结果；单文件为其父目录/NCM还原结果。
多个目录输入保留各目录名及相对目录；符号链接不会被扫描。
退出码: 0 成功或跳过，1 文件失败，2 参数错误或无文件，130 中断。
"""

private struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct Options {
    var inputs: [String] = []
    var output: String?
    var recursive = true
    var strictCRC = false
    var json = false
    var help = false
    var version = false
}

private struct BatchReport: Encodable {
    let version = cliVersion
    var restored = 0
    var skipped = 0
    var failed = 0
    var files: [FileResult] = []
    var elapsedMS: Double = 0

    enum CodingKeys: String, CodingKey {
        case version, restored, skipped, failed, files
        case elapsedMS = "elapsed_ms"
    }

    mutating func append(_ result: FileResult) {
        files.append(result)
        switch result.status {
        case "restored": restored += 1
        case "skipped": skipped += 1
        default: failed += 1
        }
    }
}

private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}

private struct InputRoot {
    let url: URL
    let isDirectory: Bool
}

private struct WorkItem {
    let input: URL
    let outputStem: URL
}

private func writeLine(_ text: String, to handle: FileHandle) {
    handle.write(Data((text + "\n").utf8))
}

private func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

private func elapsedMS(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func pathURL(_ path: String) -> URL {
    URL(fileURLWithPath: path).standardizedFileURL
}

private func canonicalURL(_ url: URL, allowMissing: Bool = false) throws -> URL {
    var ancestor = url
    var missing: [String] = []
    while true {
        if let resolved = realpath(ancestor.path, nil) {
            defer { free(resolved) }
            var result = URL(fileURLWithPath: String(cString: resolved))
            for component in missing.reversed() {
                result.appendPathComponent(component)
            }
            return result
        }
        let code = errno
        guard allowMissing, code == ENOENT, ancestor.path != "/" else {
            throw CLIError(message: "无法解析路径 \(url.path): \(String(cString: strerror(code)))")
        }
        missing.append(ancestor.lastPathComponent)
        ancestor.deleteLastPathComponent()
    }
}

private func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    var positionalOnly = false
    while index < arguments.count {
        let argument = arguments[index]
        if positionalOnly {
            options.inputs.append(argument)
        } else {
            switch argument {
            case "--": positionalOnly = true
            case "--json": options.json = true
            case "--no-recursive": options.recursive = false
            case "--strict-crc": options.strictCRC = true
            case "-h", "--help": options.help = true
            case "--version": options.version = true
            case "-o", "--output":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty,
                      !arguments[index].hasPrefix("-") else {
                    throw CLIError(message: "\(argument) 需要输出目录；以 - 开头的目录请使用 ./ 前缀。")
                }
                options.output = arguments[index]
            default:
                if argument.hasPrefix("--output=") {
                    let value = String(argument.dropFirst("--output=".count))
                    guard !value.isEmpty else {
                        throw CLIError(message: "--output 需要输出目录。")
                    }
                    options.output = value
                } else if argument.hasPrefix("-") {
                    throw CLIError(message: "未知参数: \(argument)")
                } else if argument.isEmpty {
                    throw CLIError(message: "输入路径不能为空。")
                } else {
                    options.inputs.append(argument)
                }
            }
        }
        index += 1
    }
    return options
}

private func fileInfo(_ url: URL) throws -> stat {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
        let code = errno
        throw CLIError(message: "无法访问 \(url.path): \(String(cString: strerror(code)))")
    }
    return info
}

private func isType(_ info: stat, _ type: mode_t) -> Bool {
    info.st_mode & mode_t(S_IFMT) == type
}

private func isWithin(_ path: String, directory: String) -> Bool {
    path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")
}

private func inputRoots(_ paths: [String]) throws -> [InputRoot] {
    var roots: [InputRoot] = []
    var seen = Set<FileIdentity>()
    for path in paths {
        try checkCancellation()
        guard !path.isEmpty else { throw CLIError(message: "输入路径不能为空。") }
        let url = pathURL(path)
        let info = try fileInfo(url)
        if isType(info, mode_t(S_IFLNK)) {
            writeLine("[warning] 跳过符号链接: \(url.path)", to: .standardError)
            continue
        }
        guard isType(info, mode_t(S_IFDIR)) || isType(info, mode_t(S_IFREG)) else {
            throw CLIError(message: "输入不是普通文件或目录: \(url.path)")
        }
        let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
        if seen.insert(identity).inserted {
            // Foundation directory entries use physical paths, including /private/tmp.
            // realpath keeps root comparisons consistent, after rejecting a symlink input.
            roots.append(InputRoot(url: try canonicalURL(url),
                                   isDirectory: isType(info, mode_t(S_IFDIR))))
        }
    }
    return roots
}

private func defaultOutput(for firstPath: String) throws -> URL {
    let first = pathURL(firstPath)
    let info = try fileInfo(first)
    // Both a directory root and a single file place results in their parent.
    guard isType(info, mode_t(S_IFDIR)) || isType(info, mode_t(S_IFREG)) ||
            isType(info, mode_t(S_IFLNK)) else {
        throw CLIError(message: "输入不是普通文件或目录: \(first.path)")
    }
    return first.deletingLastPathComponent().appendingPathComponent("NCM还原结果", isDirectory: true)
}

private func ensureDirectory(_ directory: URL) throws {
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError(message: "目标路径不是目录。")
        }
    } catch {
        throw CLIError(message: "无法创建输出目录 \(directory.path): \(describe(error))")
    }
}

private func logResult(_ result: FileResult, json: Bool) {
    if result.status == "failed" {
        writeLine("[error] \(result.inputPath): \(result.error ?? "恢复失败。")", to: .standardError)
    } else {
        let label = result.status == "restored" ? "restored" : "skipped"
        let destination = result.outputPath.map { " -> " + $0 } ?? ""
        writeLine("[\(label)] \(result.inputPath)\(destination)",
                  to: json ? .standardError : .standardOutput)
    }
    for warning in result.warnings {
        writeLine("[warning] \(result.inputPath): \(warning)", to: .standardError)
    }
}

private func recordFailure(input: URL, error: Error, report: inout BatchReport, json: Bool,
                           elapsed: Double = 0) {
    let result = FileResult(inputPath: input.path, status: "failed", elapsedMS: elapsed,
                            error: describe(error))
    report.append(result)
    logResult(result, json: json)
}

private func scan(_ roots: [InputRoot], output: URL, options: Options,
                  report: inout BatchReport) throws -> [WorkItem] {
    let multipleDirectories = roots.filter(\.isDirectory).count > 1
    let outputPath = output.path
    var seenDirectories = Set<FileIdentity>()
    var seenFiles = Set<FileIdentity>()
    var items: [WorkItem] = []

    for root in roots.sorted(by: { $0.url.path < $1.url.path }) {
        try checkCancellation()
        let rootPath = root.url.path
        let excludeOutput = root.isDirectory && outputPath != rootPath &&
            isWithin(outputPath, directory: rootPath)
        let destinationRoot = root.isDirectory && multipleDirectories
            ? output.appendingPathComponent(root.url.lastPathComponent, isDirectory: true)
            : output
        var pending = [root.url]
        while let url = pending.popLast() {
            try checkCancellation()
            if excludeOutput && isWithin(url.path, directory: outputPath) {
                continue
            }
            do {
                let info = try fileInfo(url)
                if isType(info, mode_t(S_IFLNK)) { continue }
                let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
                if isType(info, mode_t(S_IFDIR)) {
                    if !options.recursive && url.path != root.url.path { continue }
                    guard seenDirectories.insert(identity).inserted else { continue }
                    let children = try FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil
                    ).sorted { $0.path < $1.path }
                    for child in children.reversed() {
                        try checkCancellation()
                        pending.append(child)
                    }
                } else if isType(info, mode_t(S_IFREG)),
                          url.pathExtension.lowercased() == "ncm",
                          seenFiles.insert(identity).inserted {
                    let relativePath: String
                    if root.isDirectory {
                        relativePath = url.pathComponents.dropFirst(root.url.pathComponents.count)
                            .joined(separator: "/")
                    } else {
                        relativePath = url.lastPathComponent
                    }
                    let stem = destinationRoot.appendingPathComponent(relativePath)
                        .deletingPathExtension()
                    items.append(WorkItem(input: url, outputStem: stem))
                }
            } catch {
                if Cancellation.receivedSignal != 0 { throw error }
                recordFailure(input: url, error: error, report: &report, json: options.json)
            }
        }
    }
    return items.sorted { $0.input.path < $1.input.path }
}

private func run(_ options: Options, report: inout BatchReport) throws -> Int32 {
    guard !options.inputs.isEmpty else {
        throw CLIError(message: "未提供输入文件或目录。使用 --help 查看用法。")
    }
    let roots = try inputRoots(options.inputs)
    let requestedOutput = try options.output.map(pathURL) ?? defaultOutput(for: options.inputs[0])
    let output = try canonicalURL(requestedOutput, allowMissing: true)
    let items = try scan(roots, output: output, options: options, report: &report)
    guard !items.isEmpty else {
        throw CLIError(message: "输入中没有可处理的 .ncm 文件。")
    }
    try checkCancellation()
    try ensureDirectory(output)
    for item in items {
        try checkCancellation()
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try ensureDirectory(item.outputStem.deletingLastPathComponent())
            let result = try restoreFile(input: item.input, outputStem: item.outputStem,
                                         strictCRC: options.strictCRC)
            report.append(result)
            logResult(result, json: options.json)
        } catch {
            if Cancellation.receivedSignal != 0 { throw error }
            recordFailure(input: item.input, error: error, report: &report, json: options.json,
                          elapsed: elapsedMS(since: start))
        }
        try checkCancellation()
    }
    return report.failed == 0 ? 0 : 1
}

private func requestsJSON(_ arguments: [String]) -> Bool {
    // Keep error reports machine-readable even if option parsing fails before --json.
    for argument in arguments {
        if argument == "--" { break }
        if argument == "--json" { return true }
    }
    return false
}

private func main() -> Int32 {
    signal(SIGINT, { value in Cancellation.receivedSignal = value })
    signal(SIGTERM, { value in Cancellation.receivedSignal = value })
    let start = DispatchTime.now().uptimeNanoseconds
    let arguments = Array(CommandLine.arguments.dropFirst())
    var json = requestsJSON(arguments)
    var showSummary = true
    var report = BatchReport()
    var exitCode: Int32 = 0
    do {
        let options = try parseOptions(arguments)
        json = options.json
        try checkCancellation()
        if options.help {
            showSummary = false
            writeLine(usage, to: json ? .standardError : .standardOutput)
        } else if options.version {
            showSummary = false
            if !json { writeLine("ncm-restore \(cliVersion)", to: .standardOutput) }
        } else {
            exitCode = try run(options, report: &report)
        }
    } catch {
        if Cancellation.receivedSignal != 0 {
            exitCode = 130
            writeLine("[error] 已中断（信号 \(Cancellation.receivedSignal)）。", to: .standardError)
        } else {
            exitCode = 2
            writeLine("[error] \(describe(error))", to: .standardError)
        }
    }
    if Cancellation.receivedSignal != 0 { exitCode = 130 }
    report.elapsedMS = elapsedMS(since: start)
    if json {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            writeLine("[error] 无法编码 JSON 结果: \(describe(error))", to: .standardError)
            if exitCode != 130 { exitCode = 1 }
        }
    } else if showSummary {
        writeLine("完成: restored=\(report.restored) skipped=\(report.skipped) failed=\(report.failed)",
                  to: .standardOutput)
    }
    return Cancellation.receivedSignal == 0 ? exitCode : 130
}

exit(main())
