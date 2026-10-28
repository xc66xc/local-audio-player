import Foundation

// A dependency-free runner for Macs with Command Line Tools and no XCTest installation.
class CheckSuite {
    private var cleanups: [() throws -> Void] = []
    func addTeardownBlock(_ cleanup: @escaping () throws -> Void) { cleanups.append(cleanup) }
    func cleanup() throws {
        defer { cleanups.removeAll() }
        for cleanup in cleanups { try cleanup() }
    }
}

private var failures: [String] = []

private func check(_ passed: Bool, _ detail: String, file: StaticString, line: UInt) {
    if !passed { failures.append("\(file):\(line): \(detail)") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    check(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
func expectEqual(_ actual: Double, _ expected: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    check(abs(actual - expected) <= accuracy, "Expected \(expected) ± \(accuracy), got \(actual)", file: file, line: line)
}
func expectTrue(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) {
    check(actual, "Expected true", file: file, line: line)
}
func expectFalse(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) {
    check(!actual, "Expected false", file: file, line: line)
}
func expectNil<T>(_ actual: T?, file: StaticString = #filePath, line: UInt = #line) {
    check(actual == nil, "Expected nil", file: file, line: line)
}
func expectNotNil<T>(_ actual: T?, file: StaticString = #filePath, line: UInt = #line) {
    check(actual != nil, "Expected a value", file: file, line: line)
}
func expectGreaterThan<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    check(actual > expected, "Expected \(actual) > \(expected)", file: file, line: line)
}
func expectLessThan<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    check(actual < expected, "Expected \(actual) < \(expected)", file: file, line: line)
}

@main
struct CheckRunner {
    @MainActor static func main() async {
        let suite = PlayerTests()
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("主流格式、VBR、24 位与浮点音频的播放/跳转/倍速", suite.testMainstreamFormatsTransport),
            ("Vorbis/Opus 自然结束、连播及手动结束", suite.testOggCompletionAndCancellation),
            ("Ogg 暂停、跳转、损坏文件及切换取消", suite.testOggPauseSeekAndBadReplacement),
            ("十分钟 Opus 末段跳转及真实 PCM 解码", suite.testLongOggSeekAndActualDecode),
            ("自定义跳转、长按倍速、释放与取消", suite.testConfigurableSeekingAndHoldRate),
            ("跳转边界与时间格式", { suite.testSeekBoundsAndTimeLabels() }),
            ("M4A AAC 播放、暂停与五秒跳转", suite.testM4AAACLoadsAndPausedSeekMovesFiveSeconds),
            ("M4A ALAC 播放与跳转", suite.testM4AALACPlaysAndSeeks),
            ("列表排序、去重、移除及保留原文件", suite.testPlaylistSortDedupeAndRemoval),
            ("同名不同路径文件", suite.testSameNameDifferentPathsAreKept),
            ("损坏文件保留原播放", suite.testBadFilePreservesCurrentPlayback),
            ("不连播及结束后重播", suite.testNaturalEndWithoutAutoAdvance),
            ("勾选后正常结束自动连播", suite.testNaturalEndAdvancesOnlyWhenChecked),
            ("播放中取消连播", suite.testUncheckDuringPlaybackStopsAtEnd),
            ("最后一首不循环", suite.testFinalTrackNeverLoops),
            ("手动跳至末尾不连播及后退恢复", suite.testManualEndDoesNotAdvanceAndCanSeekBack),
            ("下一首文件丢失停止并提示", suite.testNextMissingFileStopsWithVisibleError),
            ("忽略过期结束事件", suite.testStaleCompletionIgnored),
            ("左右键、修饰键和长按规则", suite.testKeyboardDirectionModifiersAndRepeat)
        ]
        for (name, run) in tests {
            let before = failures.count
            do { try await run() } catch { failures.append("\(name): \(error)") }
            do { try suite.cleanup() } catch { failures.append("清理失败：\(error)") }
            print("\(failures.count == before ? "PASS" : "FAIL") \(name)")
        }
        for failure in failures { print(failure) }
        print("\(tests.count) checks, \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }
}
