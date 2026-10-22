@testable import EngineCore
import Foundation

/// Hazır satırları döndüren sahte süreç; adapter'lar gerçek araç olmadan test edilir.
struct MockRunner: ProcessRunning {
    let lines: [OutputLine]
    let status: Int32
    let recorder = ArgumentRecorder()

    func start(_ executable: URL, arguments: [String], environment: [String: String]) throws -> any RunningProcess {
        recorder.record(arguments)
        return MockProcess(lines: lines, status: status)
    }
}

final class ArgumentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    func record(_ arguments: [String]) { lock.withLock { calls.append(arguments) } }
    var last: [String]? { lock.withLock { calls.last } }
}

struct MockProcess: RunningProcess {
    let output: AsyncStream<OutputLine>
    let status: Int32

    init(lines: [OutputLine], status: Int32) {
        output = AsyncStream { continuation in
            lines.forEach { continuation.yield($0) }
            continuation.finish()
        }
        self.status = status
    }

    func waitUntilExit() async -> Int32 { status }
    func terminate(grace: Duration) async {}
}
