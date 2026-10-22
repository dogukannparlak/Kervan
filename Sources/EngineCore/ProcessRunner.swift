import Foundation

/// Child process çıktısının tek satırı.
public struct OutputLine: Sendable, Equatable {
    public enum Source: Sendable { case stdout, stderr }
    public let source: Source
    public let text: String

    public init(_ source: Source, _ text: String) {
        self.source = source
        self.text = text
    }
}

/// Bütün dış araç çağrıları bu protokolden geçer; testlerde `MockProcess` yerine geçer.
public protocol ProcessRunning: Sendable {
    func start(_ executable: URL, arguments: [String], environment: [String: String]) throws -> any RunningProcess
}

public protocol RunningProcess: Sendable {
    /// stdout ve stderr satırları; iki akış da kapanınca biter.
    var output: AsyncStream<OutputLine> { get }
    func waitUntilExit() async -> Int32
    /// SIGINT gönderir, `grace` süresinde çıkmazsa SIGKILL.
    func terminate(grace: Duration) async
}

extension RunningProcess {
    public func terminate() async { await terminate(grace: .seconds(5)) }

    /// Bütün çıktıyı toplar ve çıkış kodunu döner (kısa ömürlü komutlar için).
    public func collect() async -> (stdout: [String], stderr: [String], status: Int32) {
        var out: [String] = []
        var err: [String] = []
        for await line in output {
            if line.source == .stdout { out.append(line.text) } else { err.append(line.text) }
        }
        return (out, err, await waitUntilExit())
    }
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func start(_ executable: URL, arguments: [String], environment: [String: String]) throws -> any RunningProcess {
        try SystemProcess(executable: executable, arguments: arguments, environment: environment)
    }
}

final class SystemProcess: RunningProcess, @unchecked Sendable {
    let output: AsyncStream<OutputLine>
    private let process = Process()
    private let exit = ExitSignal()

    init(executable: URL, arguments: [String], environment: [String: String]) throws {
        let (stream, continuation) = AsyncStream<OutputLine>.makeStream()
        output = stream

        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let openPipes = Counter(2)
        for (pipe, source) in [(Pipe(), OutputLine.Source.stdout), (Pipe(), .stderr)] {
            if source == .stdout { process.standardOutput = pipe } else { process.standardError = pipe }
            let splitter = LineSplitter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    splitter.finish().forEach { continuation.yield(OutputLine(source, $0)) }
                    if openPipes.decrement() == 0 { continuation.finish() }
                    return
                }
                splitter.feed(data).forEach { continuation.yield(OutputLine(source, $0)) }
            }
        }

        process.terminationHandler = { [exit] process in exit.signal(process.terminationStatus) }
        try process.run()
    }

    func waitUntilExit() async -> Int32 { await exit.wait() }

    func terminate(grace: Duration) async {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.interrupt()
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [exit] in _ = await exit.wait(); return true }
            group.addTask { try? await Task.sleep(for: grace); return false }
            if await group.next() == false { kill(pid, SIGKILL) }
            group.cancelAll()
        }
    }
}

/// Bayt akışını `\n` ya da `\r` sınırlarından satırlara böler; boş satırları atar.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        return lines
    }

    func finish() -> [String] {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? [] : [String(decoding: buffer, as: UTF8.self)]
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) { self.value = value }

    func decrement() -> Int {
        lock.withLock {
            value -= 1
            return value
        }
    }
}

private final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func signal(_ status: Int32) {
        let waiting = lock.withLock {
            self.status = status
            defer { waiters.removeAll() }
            return waiters
        }
        waiting.forEach { $0.resume(returning: status) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done: Int32? = lock.withLock {
                if let status { return status }
                waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }
}
