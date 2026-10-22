import Foundation

/// Doğrudan HTTP(S) indirme. Her indirme için localhost'ta, rastgele secret'lı bir
/// `aria2c --enable-rpc` süreci açar (M2'de tek kalıcı sürece dönüşür).
public struct Aria2Adapter: Sendable {
    let executable: URL
    let runner: any ProcessRunning
    let environment: [String: String]
    let connections: Int

    public init(executable: URL, runner: any ProcessRunning = SystemProcessRunner(), environment: [String: String], connections: Int = 8) {
        self.executable = executable
        self.runner = runner
        self.environment = environment
        self.connections = connections
    }

    public func download(_ url: URL, to directory: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var process: (any RunningProcess)?
                do {
                    let (started, rpc) = try await startServer(in: directory)
                    process = started
                    let logs = Task {
                        for await line in started.output { continuation.yield(.log(line)) }
                    }
                    defer { logs.cancel() }

                    let gid: String = try await rpc.call("aria2.addUri", [.array([.string(url.absoluteString)]), .object([
                        "split": .string(String(connections)),
                        "max-connection-per-server": .string(String(connections)),
                    ])])

                    while true {
                        try await Task.sleep(for: .milliseconds(500))
                        let status: Aria2Status = try await rpc.call("aria2.tellStatus", [.string(gid)])
                        switch status.status {
                        case "complete":
                            guard let path = status.files.first?.path, !path.isEmpty else { throw EngineError.noOutputFile }
                            continuation.yield(.progress(status.event))
                            _ = try? await rpc.call("aria2.shutdown", []) as String
                            _ = await started.waitUntilExit()
                            continuation.yield(.completed(URL(filePath: path)))
                            continuation.finish()
                            return
                        case "error", "removed":
                            throw EngineError.toolFailed(.aria2c, status: Int32(status.errorCode ?? "") ?? -1,
                                                         message: status.errorMessage ?? status.status)
                        default:
                            continuation.yield(.progress(status.event))
                        }
                    }
                } catch {
                    // SIGINT ile durdurulan aria2 `.aria2` kontrol dosyasını yazar; sonraki indirme devam eder.
                    await process?.terminate()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func startServer(in directory: URL) async throws -> (any RunningProcess, Aria2RPC) {
        for _ in 0..<3 {
            let port = Int.random(in: 49152...65000)
            let rpc = Aria2RPC(port: port, secret: UUID().uuidString)
            let process = try runner.start(executable, arguments: [
                "--enable-rpc", "--rpc-listen-all=false", "--rpc-listen-port=\(port)", "--rpc-secret=\(rpc.secret)",
                "--stop-with-process=\(getpid())", "--dir=\(directory.path)",
                "--continue=true", "--file-allocation=none", "--auto-file-renaming=true",
                "--console-log-level=warn", "--summary-interval=0", "--show-console-readout=false",
            ], environment: environment)
            for _ in 0..<30 {
                if (try? await rpc.call("aria2.getVersion", []) as Aria2Version) != nil { return (process, rpc) }
                try await Task.sleep(for: .milliseconds(100))
            }
            await process.terminate(grace: .seconds(1))
        }
        throw EngineError.aria2NotReady
    }
}

struct Aria2Status: Decodable {
    struct File: Decodable { let path: String }

    let status: String
    let totalLength: String
    let completedLength: String
    let downloadSpeed: String
    let errorCode: String?
    let errorMessage: String?
    let files: [File]

    var event: ProgressEvent {
        let done = Int64(completedLength) ?? 0
        let total = Int64(totalLength).flatMap { $0 > 0 ? $0 : nil }
        let speed = Double(downloadSpeed) ?? 0
        let eta = total.flatMap { speed > 0 ? Int(Double($0 - done) / speed) : nil }
        return ProgressEvent(phase: .download, bytesDone: done, bytesTotal: total, speed: speed, eta: eta)
    }
}

struct Aria2Version: Decodable { let version: String }

/// Küçük JSON-RPC 2.0 istemcisi (yalnız localhost).
struct Aria2RPC: Sendable {
    let port: Int
    let secret: String

    func call<T: Decodable>(_ method: String, _ params: [JSONValue]) async throws -> T {
        let body = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .string("kervan"), "method": .string(method),
            "params": .array([.string("token:\(secret)")] + params),
        ])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/jsonrpc")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(Response<T>.self, from: data)
        if let error = response.error { throw EngineError.toolFailed(.aria2c, status: Int32(error.code), message: error.message) }
        guard let result = response.result else { throw EngineError.aria2NotReady }
        return result
    }

    private struct Response<T: Decodable>: Decodable {
        struct RPCError: Decodable { let code: Int; let message: String }
        let result: T?
        let error: RPCError?
    }
}

enum JSONValue: Encodable, Sendable {
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
