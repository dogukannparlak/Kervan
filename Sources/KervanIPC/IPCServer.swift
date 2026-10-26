import Darwin
import EngineCore
import Foundation
import QueueKit

/// `kervand`'ın soket sunucusu. Bağlantı başına bir iş parçacığı (yerel, az bağlantı);
/// istekler `QueueEngine` actor'üne köprülenir.
public final class IPCServer: Sendable {
    private let engine: QueueEngine
    private let settings: SettingsStore
    private let updater: (@Sendable () async throws -> UpdateState)?
    private let listenFD: Int32

    public init(path: URL, engine: QueueEngine, settings: SettingsStore,
                updater: (@Sendable () async throws -> UpdateState)? = nil) throws {
        self.engine = engine
        self.settings = settings
        self.updater = updater
        listenFD = try UnixSocket.listen(path: path.path)
    }

    /// Dinlemeyen sunucu; testler `serve`'ü doğrudan bir socketpair ucuna bağlar.
    init(engine: QueueEngine, settings: SettingsStore = SettingsStore(), updater: (@Sendable () async throws -> UpdateState)? = nil) {
        self.engine = engine
        self.settings = settings
        self.updater = updater
        listenFD = -1
    }

    public func start() {
        Thread.detachNewThread { [self] in
            while true {
                let fd = accept(listenFD, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let connection = LineConnection(fd: fd)
                Thread.detachNewThread { [self] in serve(connection) }
            }
        }
    }

    /// Bir bağlantının bütün isteklerini, kapanana kadar işler.
    public func serve(_ connection: LineConnection) {
        var subscription: Task<Void, Never>?
        defer {
            subscription?.cancel()
            connection.close()
        }
        while let line = connection.readLine() {
            guard let request = try? IPCCoding.decoder().decode(Request.self, from: line) else {
                try? connection.send(Response.failure("Geçersiz istek."))
                continue
            }
            if request.cmd == .subscribe {
                subscription?.cancel()
                subscription = Task { [engine] in
                    for await event in await engine.subscribe() {
                        let response = switch event {
                        case .updated(let item): Response(ok: true, event: true, items: [item])
                        case .removed(let id): Response(ok: true, event: true, removed: [id])
                        }
                        try? connection.send(response)
                    }
                }
                try? connection.send(Response(ok: true))
                continue
            }
            let response = blocking { [self] in await handle(request) }
            try? connection.send(response)
        }
    }

    func handle(_ request: Request) async -> Response {
        do {
            switch request.cmd {
            case .ping:
                return Response(ok: true, version: kervanVersion, items: [])
            case .add:
                guard let text = request.url, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    throw QueueError.invalidURL(request.url ?? "")
                }
                // Klasör verilmediyse ayardaki indirme klasörü (+ açıksa tür klasörü).
                let current = settings.value
                let context = RequestContext(referer: request.referer, userAgent: request.userAgent, filename: request.title)
                let outcome = try await engine.add(url: url, options: AddOptions(
                    presetId: request.preset ?? current.defaultPreset, destination: request.dir ?? current.downloadDirectory,
                    cookies: CookiePolicy(request.cookies ?? "auto"), selection: request.items, context: context,
                    subtitles: (request.subtitles ?? current.subtitles) ? current.subtitleLanguages : nil,
                    categorize: request.dir == nil && current.categorize))
                switch outcome {
                case .added(let items, let notes):
                    return Response(ok: true, items: items, notes: notes)
                case .needsSelection(let title, let entries, let notes):
                    return Response(ok: true, title: title, entries: entries, notes: notes)
                }
            case .list:
                return Response(ok: true, items: await engine.list())
            case .log:
                guard let id = request.ids?.first else { return .failure("Öğe numarası gerekli.") }
                // Negatif değer `suffix`'i çökertir; aşırı büyüğü de anlamsız.
                let lines = min(max(request.lines ?? 50, 0), 10_000)
                return Response(ok: true, log: try await engine.log(id, lines: lines))
            case .pause, .resume, .cancel, .retry, .remove:
                guard let ids = request.ids, !ids.isEmpty else { return .failure("Öğe numarası gerekli.") }
                let action = QueueAction(rawValue: request.cmd.rawValue)!
                return Response(ok: true, items: try await engine.apply(action, to: ids))
            case .reveal:
                guard let id = request.ids?.first else { return .failure("Öğe numarası gerekli.") }
                guard let item = await engine.item(id) else { throw QueueError.notFound(id) }
                guard let path = item.outputPath, FileManager.default.fileExists(atPath: path) else {
                    return .failure("#\(id) için dosya yok (henüz bitmedi ya da taşındı).")
                }
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/open")
                process.arguments = ["-R", path]
                try process.run()
                return Response(ok: true, items: [item])
            case .formats:
                guard let text = request.url, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    throw QueueError.invalidURL(request.url ?? "")
                }
                let context = RequestContext(referer: request.referer, userAgent: request.userAgent)
                let list = try await engine.qualities(url: url, cookies: CookiePolicy(request.cookies ?? "auto"), context: context)
                return Response(ok: true, qualities: list)
            case .settings:
                return Response(ok: true, settings: settings.value, update: UpdateState.load(paths: settings.paths))
            case .setSettings:
                guard let new = request.settings else { return .failure("settings alanı gerekli.") }
                guard try PresetStore.named(new.defaultPreset) != nil else { throw QueueError.unknownPreset(new.defaultPreset) }
                try await settings.update(new)
                return Response(ok: true, settings: settings.value)
            case .update:
                guard let updater else { return .failure("Güncelleyici bu serviste yok.") }
                return Response(ok: true, update: try await updater())
            case .subscribe:
                return .failure("subscribe burada işlenmez.")
            }
        } catch {
            return .failure(String(describing: error))
        }
    }
}

/// Ayrı bir iş parçacığında (cooperative pool dışında) async işi bekler.
func blocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
