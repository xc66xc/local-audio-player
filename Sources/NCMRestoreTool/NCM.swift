import Foundation
import CommonCrypto
import CryptoKit
import Darwin

enum Cancellation {
    static var receivedSignal: Int32 = 0
}

struct RestoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

func checkCancellation() throws {
    if Cancellation.receivedSignal != 0 { throw RestoreError("操作已取消") }
}

struct FileResult: Encodable {
    let inputPath: String
    let outputPath: String?
    let status: String
    let audioFormat: String?
    let audioBytes: Int64?
    let audioOffsetBytes: Int64?
    let outputSHA256: String?
    let elapsedMS: Double
    let warnings: [String]
    let error: String?

    init(inputPath: String, outputPath: String? = nil, status: String,
         audioFormat: String? = nil, audioBytes: Int64? = nil,
         audioOffsetBytes: Int64? = nil, outputSHA256: String? = nil,
         elapsedMS: Double = 0, warnings: [String] = [], error: String? = nil) {
        self.inputPath = inputPath; self.outputPath = outputPath; self.status = status
        self.audioFormat = audioFormat; self.audioBytes = audioBytes
        self.audioOffsetBytes = audioOffsetBytes; self.outputSHA256 = outputSHA256
        self.elapsedMS = elapsedMS; self.warnings = warnings; self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path", outputPath = "output_path", status
        case audioFormat = "audio_format", audioBytes = "audio_bytes"
        case audioOffsetBytes = "audio_offset_bytes", outputSHA256 = "output_sha256"
        case elapsedMS = "elapsed_ms", warnings, error
    }
}

private let audioBufferBytes = 65_536
// A fixed NCM format constant, recovered and verified in the prior REA analysis.
// It is not an account credential and requires no installed client to obtain it.
private let formatKey = Array("hzHRAmso5kInbaxW".utf8)
private let keyPrefix = Array("neteasecloudmusic".utf8)
private let crcTable: [UInt32] = (0..<256).map { number in
    var value = UInt32(number)
    for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
    return value
}

private func systemError(_ message: String, code: Int32 = errno) -> RestoreError {
    RestoreError("\(message)：\(String(cString: strerror(code)))")
}

private func little32(_ bytes: [UInt8], _ start: Int = 0) -> UInt32 {
    UInt32(bytes[start]) | (UInt32(bytes[start + 1]) << 8) |
        (UInt32(bytes[start + 2]) << 16) | (UInt32(bytes[start + 3]) << 24)
}

private func updateCRC(_ crc: inout UInt32, _ bytes: [UInt8]) {
    for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
}

private func decryptKey(_ encrypted: [UInt8]) throws -> [UInt8] {
    let ciphertext = encrypted.map { $0 ^ 0x64 }
    var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
    var written = 0
    let capacity = plaintext.count
    let status = formatKey.withUnsafeBytes { key in
        ciphertext.withUnsafeBytes { source in
            plaintext.withUnsafeMutableBytes { destination in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        key.baseAddress, formatKey.count, nil,
                        source.baseAddress, ciphertext.count,
                        destination.baseAddress, capacity, &written)
            }
        }
    }
    guard status == kCCSuccess, written > keyPrefix.count,
          plaintext.prefix(keyPrefix.count).elementsEqual(keyPrefix) else {
        throw RestoreError("NCM 密钥块解密失败或前缀不正确")
    }
    return Array(plaintext[keyPrefix.count..<written])
}

private func makeMask(_ key: [UInt8]) -> [UInt8] {
    var box = (0..<256).map { UInt8($0) }
    var j = 0
    for i in 0..<256 {
        j = (j + Int(box[i]) + Int(key[i % key.count])) & 255
        box.swapAt(i, j)
    }
    return (0..<256).map { position in
        let index = (position + 1) & 255
        let a = Int(box[index])
        return box[(a + Int(box[(a + index) & 255])) & 255]
    }
}

private struct AudioLayout {
    let offset: Int64
    let bytes: Int64
    let mask: [UInt8]
    let format: String
    let warnings: [String]
}

private final class RestoreOperation {
    let input: URL
    let outputStem: URL
    let strictCRC: Bool
    var inputFD: Int32 = -1
    var outputFD: Int32 = -1
    var temporaryPath: String?
    var temporaryIdentity: (dev_t, ino_t)?
    var size: Int64 = 0
    var original = stat()
    var position: Int64 = 0

    init(input: URL, outputStem: URL, strictCRC: Bool) {
        self.input = input; self.outputStem = outputStem; self.strictCRC = strictCRC
    }

    func readAt(_ offset: Int64, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset <= size, Int64(count) <= size - offset else {
            throw RestoreError("NCM 字段越过文件末尾，文件可能已截断")
        }
        var bytes = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            try checkCancellation()
            let result = bytes.withUnsafeMutableBytes { pointer in
                pread(inputFD, pointer.baseAddress!.advanced(by: done), count - done, offset + Int64(done))
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw systemError("读取输入失败")
            }
            guard result > 0 else { throw RestoreError("读取输入时文件意外结束") }
            done += result
        }
        return bytes
    }

    func read(_ count: Int) throws -> [UInt8] {
        let bytes = try readAt(position, count: count)
        position += Int64(count)
        return bytes
    }

    func plaintext(_ offset: Int64, count: Int, audioOffset: Int64, mask: [UInt8]) throws -> [UInt8] {
        let available = size - audioOffset - offset
        guard available >= 0 else { throw RestoreError("音频头偏移无效") }
        var bytes = try readAt(audioOffset + offset, count: min(count, Int(available)))
        for i in bytes.indices { bytes[i] ^= mask[Int((offset + Int64(i)) & 255)] }
        return bytes
    }

    func parse() throws -> AudioLayout {
        let header = try read(14)
        guard header.prefix(8).elementsEqual(Array("CTENFDAM".utf8)), header[8] <= 1 else {
            throw RestoreError("不是受支持的 NCM 文件（当前支持常见 0/1 标记布局）")
        }
        let keyLength = Int(little32(header, 10))
        guard keyLength > 0, keyLength <= 1_048_576, keyLength % 16 == 0 else {
            throw RestoreError("NCM 密钥块长度无效")
        }
        let encryptedKey = try read(keyLength)
        var crc: UInt32 = 0xffffffff
        updateCRC(&crc, header); updateCRC(&crc, encryptedKey)
        let mask = makeMask(try decryptKey(encryptedKey))
        let metadataLengthBytes = try read(4)
        updateCRC(&crc, metadataLengthBytes)
        let metadataLength = Int(little32(metadataLengthBytes))
        guard metadataLength <= 16 * 1024 * 1024 else { throw RestoreError("NCM 元数据长度超过 16 MiB 限制") }
        var remaining = metadataLength
        while remaining > 0 {
            let bytes = try read(min(audioBufferBytes, remaining))
            updateCRC(&crc, bytes); remaining -= bytes.count
        }
        let declaredCRC = little32(try read(4))
        var warnings: [String] = []
        if declaredCRC != crc ^ 0xffffffff {
            if header[8] == 1 || strictCRC { throw RestoreError("NCM 文件头 CRC32 校验失败") }
            warnings.append("旧式 NCM 的 CRC 字段未通过校验；音频格式已另行检查，可用 --strict-crc 严格拒绝")
        }
        let cover = try read(9)
        let capacity = Int64(little32(cover, 1))
        let coverBytes = Int64(little32(cover, 5))
        guard cover[0] <= 1, coverBytes <= capacity, capacity <= size - position else {
            throw RestoreError("NCM 封面区长度无效或文件已截断")
        }
        position += capacity
        guard position < size else { throw RestoreError("NCM 文件不包含音频数据") }
        let audioOffset = position
        let format = try detectFormat(audioOffset: audioOffset, mask: mask)
        return AudioLayout(offset: audioOffset, bytes: size - audioOffset,
                           mask: mask, format: format, warnings: warnings)
    }

    func detectFormat(audioOffset: Int64, mask: [UInt8]) throws -> String {
        let audioBytes = size - audioOffset
        var start: Int64 = 0
        for _ in 0..<8 {
            let tag = try plaintext(start, count: 10, audioOffset: audioOffset, mask: mask)
            if !tag.prefix(3).elementsEqual(Array("ID3".utf8)) { break }
            guard tag.count == 10, (2...4).contains(tag[3]), tag[6..<10].allSatisfy({ $0 < 128 }) else {
                throw RestoreError("解密后的 ID3 标签头无效")
            }
            let tagBytes = tag[6..<10].reduce(Int64(0)) { ($0 << 7) | Int64($1) }
            guard tagBytes <= audioBytes - start - 10 else { throw RestoreError("ID3 标签越过音频末尾") }
            start += 10 + tagBytes
            // Accept a separately stored ID3v2.4 footer without guessing the codec from ID3.
            let footer = try plaintext(start, count: 10, audioOffset: audioOffset, mask: mask)
            if footer.count == 10 && footer.prefix(3).elementsEqual(Array("3DI".utf8)) { start += 10 }
        }
        let probe = try plaintext(start, count: 4096, audioOffset: audioOffset, mask: mask)
        if probe.prefix(4).elementsEqual(Array("fLaC".utf8)) {
            guard probe.count >= 42, probe[4] & 127 == 0,
                  probe[5] == 0, probe[6] == 0, probe[7] == 34 else {
                throw RestoreError("FLAC STREAMINFO 不完整或无效")
            }
            let sampleRate = (Int(probe[18]) << 12) | (Int(probe[19]) << 4) | Int(probe[20] >> 4)
            let bits = ((Int(probe[20] & 1) << 4) | Int(probe[21] >> 4)) + 1
            guard sampleRate > 0, (4...32).contains(bits) else { throw RestoreError("FLAC 音频参数无效") }
            return "flac"
        }
        if probe.count >= 4 {
            for index in 0...(probe.count - 4) {
                guard let first = mp3Frame(probe, index) else { continue }
                let next = start + Int64(index + first.length)
                guard next <= audioBytes else { continue }
                if next == audioBytes { return "mp3" }
                let following = try plaintext(next, count: 4, audioOffset: audioOffset, mask: mask)
                if let second = mp3Frame(following, 0), first.version == second.version,
                   first.sampleRate == second.sampleRate {
                    return "mp3"
                }
            }
        }
        throw RestoreError("解密后未识别到有效的 MP3 或 FLAC，未创建输出文件")
    }

    func sourceUnchanged() throws {
        var current = stat()
        guard fstat(inputFD, &current) == 0 else { throw systemError("检查输入文件失败") }
        guard current.st_size == original.st_size,
              current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
            throw RestoreError("处理期间源文件发生变化，未发布输出")
        }
    }

    func closeOutput() throws {
        guard outputFD >= 0 else { return }
        let descriptor = outputFD; outputFD = -1
        guard Darwin.close(descriptor) == 0 else { throw systemError("关闭输出文件失败") }
    }

    func run() throws -> FileResult {
        let started = ProcessInfo.processInfo.systemUptime
        try checkCancellation()
        inputFD = Darwin.open(input.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard inputFD >= 0 else { throw systemError("打开输入文件失败") }
        guard fstat(inputFD, &original) == 0 else { throw systemError("读取输入属性失败") }
        guard original.st_mode & S_IFMT == S_IFREG, original.st_size > 0 else {
            throw RestoreError("输入必须是非空的普通文件")
        }
        size = original.st_size
        let layout = try parse()
        let destination = URL(fileURLWithPath: outputStem.path + "." + layout.format)
        func result(_ status: String, sha: String? = nil) -> FileResult {
            FileResult(inputPath: input.path, outputPath: destination.path, status: status,
                       audioFormat: layout.format, audioBytes: layout.bytes,
                       audioOffsetBytes: layout.offset, outputSHA256: sha,
                       elapsedMS: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                       warnings: layout.warnings)
        }
        var targetStat = stat()
        if lstat(destination.path, &targetStat) == 0 { return result("skipped") }
        guard errno == ENOENT else { throw systemError("检查输出路径失败") }
        let candidate = destination.deletingLastPathComponent()
            .appendingPathComponent(".ncm-restore-\(UUID().uuidString).tmp").path
        let descriptor = Darwin.open(candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw systemError("创建临时输出失败") }
        outputFD = descriptor; temporaryPath = candidate
        var identity = stat()
        guard fstat(outputFD, &identity) == 0 else { throw systemError("读取临时文件身份失败") }
        temporaryIdentity = (identity.st_dev, identity.st_ino)
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: audioBufferBytes)
        var audioPosition: Int64 = 0
        while audioPosition < layout.bytes {
            try checkCancellation()
            let wanted = min(buffer.count, Int(layout.bytes - audioPosition))
            let count = buffer.withUnsafeMutableBytes { pointer in
                pread(inputFD, pointer.baseAddress, wanted, layout.offset + audioPosition)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("读取音频失败")
            }
            guard count > 0 else { throw RestoreError("音频数据在处理期间被截断") }
            for i in 0..<count { buffer[i] ^= layout.mask[Int((audioPosition + Int64(i)) & 255)] }
            buffer.withUnsafeBytes { pointer in hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: pointer[..<count])) }
            var written = 0
            while written < count {
                try checkCancellation()
                let bytes = buffer.withUnsafeBytes { pointer in
                    Darwin.write(outputFD, pointer.baseAddress!.advanced(by: written), count - written)
                }
                if bytes < 0 {
                    if errno == EINTR { continue }
                    throw systemError("写入音频失败")
                }
                guard bytes > 0 else { throw RestoreError("写入输出没有取得进展") }
                written += bytes
            }
            audioPosition += Int64(count)
        }
        try sourceUnchanged()
        try checkCancellation()
        guard fsync(outputFD) == 0 else { throw systemError("保存输出文件失败") }
        try closeOutput()
        try checkCancellation()
        if renamex_np(candidate, destination.path, UInt32(RENAME_EXCL)) != 0 {
            if errno == EEXIST || errno == ENOTEMPTY { return result("skipped") }
            throw systemError("发布输出文件失败（输出磁盘需支持排他重命名）")
        }
        temporaryPath = nil; temporaryIdentity = nil
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return result("restored", sha: digest)
    }

    // Attempt every cleanup independently. Never remove a path we did not create.
    func cleanup() -> [String] {
        var issues: [String] = []
        if outputFD >= 0 {
            let descriptor = outputFD; outputFD = -1
            if Darwin.close(descriptor) != 0 { issues.append(systemError("关闭临时输出失败").message) }
        }
        if inputFD >= 0 {
            let descriptor = inputFD; inputFD = -1
            if Darwin.close(descriptor) != 0 { issues.append(systemError("关闭输入失败").message) }
        }
        if let path = temporaryPath {
            var current = stat()
            if lstat(path, &current) == 0 {
                if let identity = temporaryIdentity,
                   current.st_dev == identity.0, current.st_ino == identity.1 {
                    if unlink(path) != 0 { issues.append(systemError("清理临时文件失败").message) }
                } else {
                    issues.append("临时路径身份不一致，保留该路径：\(path)")
                }
            } else if errno != ENOENT {
                issues.append(systemError("检查临时文件失败").message)
            }
            temporaryPath = nil; temporaryIdentity = nil
        }
        return issues
    }
}

private func mp3Frame(_ bytes: [UInt8], _ offset: Int) -> (length: Int, version: Int, sampleRate: Int)? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    let a = Int(bytes[offset]), b = Int(bytes[offset + 1]), c = Int(bytes[offset + 2])
    let version = (b >> 3) & 3
    guard a == 255, b & 0xe0 == 0xe0, version != 1, (b >> 1) & 3 == 1 else { return nil }
    let bitrateIndex = c >> 4, rateIndex = (c >> 2) & 3
    guard (1...14).contains(bitrateIndex), rateIndex < 3 else { return nil }
    let highRates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    let lowRates = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
    let sampleRate = [44100, 48000, 32000][rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
    let bitrate = (version == 3 ? highRates : lowRates)[bitrateIndex]
    let length = (version == 3 ? 144000 : 72000) * bitrate / sampleRate + ((c >> 1) & 1)
    return (length, version, sampleRate)
}

func restoreFile(input: URL, outputStem: URL, strictCRC: Bool = false) throws -> FileResult {
    let operation = RestoreOperation(input: input, outputStem: outputStem, strictCRC: strictCRC)
    var result: FileResult?
    var primary: Error?
    do { result = try operation.run() } catch { primary = error }
    let cleanupIssues = operation.cleanup()
    if let primary = primary {
        if cleanupIssues.isEmpty { throw primary }
        throw RestoreError(primary.localizedDescription + "；" + cleanupIssues.joined(separator: "；"))
    }
    guard cleanupIssues.isEmpty else { throw RestoreError(cleanupIssues.joined(separator: "；")) }
    guard let completed = result else { throw RestoreError("处理未产生结果") }
    return completed
}
