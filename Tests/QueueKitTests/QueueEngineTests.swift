import EngineCore
import Foundation
@testable import QueueKit
import Testing

/// URL'nin son parçasına göre davranan sahte indirici:
/// `ok` hemen biter, `fail` hata verir, `perm` kalıcı hata verir, `hang` iptal edilene kadar sürer.
final class FakeExecutor: DownloadExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _runs: [String: Int] = [:]

    func runs(_ url: String) -> Int { lock.withLock { _runs[url, default: 0] } }

    func run(_ item: DownloadItem) -> AsyncThrowingStream<DownloadEvent, Error> {
        lock.withLock { _runs[item.url, default: 0] += 1 }
        let behavior = URL(string: item.url)!.lastPathComponent
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.progress(ProgressEvent(phase: .download, bytesDone: 10, bytesTotal: 100, speed: 5)))
                switch behavior {
                case "fail":
                    continuation.finish(throwing: EngineError.toolFailed(.ytDlp, status: 1, message: "ERROR: network"))
                case "perm":
                    continuation.finish(throwing: EngineError.toolFailed(.ytDlp, status: 1, message: "ERROR: Video unavailable"))
                case "hang":
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    continuation.finish()
                case "partial":
                    // Hedef klasöre yarım dosya bırakıp iptale kadar sürer.
                    let target = URL(filePath: item.destination).appending(path: "Video [p1].mp4")
                    try? Data().write(to: URL(filePath: target.path + ".part"))
                    continuation.yield(.started(target))
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    continuation.finish()
                default:
                    continuation.yield(.completed(URL(filePath: "/tmp/\(behavior).mp4")))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct FakeResolver: LinkResolving {
    var entries = 0
    var generic = false

    func resolve(_ url: URL, cookies: CookiePolicy, context: RequestContext) async throws -> ResolvedLink {
        let json: [String: Any] = entries > 0
            ? ["_type": "playlist", "title": "Liste", "entries": (1...entries).map { ["id": "\($0)", "title": "V\($0)", "url": "https://e.com/v\($0)/ok"] }]
            : ["title": url.lastPathComponent, "extractor": generic ? "generic" : "youtube"]
        let probe = try JSONDecoder().decode(ProbeResult.self, from: JSONSerialization.data(withJSONObject: json))
        return ResolvedLink(kind: entries > 0 ? .playlist(probe) : .video(probe), cookiesBrowser: cookies.explicit, notes: [])
    }
}

func testConfig(parallel: Int = 3, perHost: Int = 3) -> QueueEngine.Config {
    var config = QueueEngine.Config()
    config.maxParallel = parallel
    config.maxPerHost = perHost
    config.hostStartGap = .zero
    config.backoffBase = 0
    config.tickInterval = .milliseconds(20)
    config.persistInterval = .zero
    config.broadcastInterval = .zero
    return config
}

func makeEngine(_ executor: FakeExecutor, store: ItemStore? = nil, resolver: FakeResolver = FakeResolver(),
                config: QueueEngine.Config = testConfig()) throws -> QueueEngine {
    try QueueEngine(store: store ?? ItemStore(path: nil), executor: executor, resolver: resolver, config: config)
}

@discardableResult
func addURL(_ engine: QueueEngine, _ url: String, selection: String? = nil) async throws -> [DownloadItem] {
    let outcome = try await engine.add(url: URL(string: url)!, options: AddOptions(
        destination: "/tmp/kervan-test", cookies: CookiePolicy("none"), selection: selection))
    guard case .added(let items, _) = outcome else { return [] }
    return items
}

/// Koşul sağlanana kadar bekler (en fazla 3 sn).
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@Suite struct ItemStateTests {
    @Test func transitionTable() {
        #expect(ItemState.queued.canTransition(to: .downloading))
        #expect(ItemState.downloading.canTransition(to: .paused))
        #expect(ItemState.paused.canTransition(to: .queued))
        #expect(ItemState.failed.canTransition(to: .queued))
        #expect(!ItemState.done.canTransition(to: .queued))
        #expect(!ItemState.paused.canTransition(to: .downloading))
        #expect(!ItemState.queued.canTransition(to: .done))
        #expect(ItemState.allCases.allSatisfy { !ItemState.done.canTransition(to: $0) })
    }

    @Test func selectionParsing() throws {
        #expect(try PlaylistSelection.parse("1,3,5-7", count: 10) == [1, 3, 5, 6, 7])
        #expect(try PlaylistSelection.parse("all", count: 3) == [1, 2, 3])
        #expect(try PlaylistSelection.parse("2, 2,1", count: 3) == [1, 2])
        #expect(throws: QueueError.self) { try PlaylistSelection.parse("4", count: 3) }
        #expect(throws: QueueError.self) { try PlaylistSelection.parse("3-1", count: 3) }
        #expect(throws: QueueError.self) { try PlaylistSelection.parse("a", count: 3) }
        // Boş liste ve dev aralık servisi çökertmemeli.
        #expect(throws: QueueError.self) { try PlaylistSelection.parse("1", count: 0) }
        #expect(try PlaylistSelection.parse("all", count: 0) == [])
        #expect(throws: QueueError.self) { try PlaylistSelection.parse("1-2000000000", count: 3) }
        #expect(throws: QueueError.self) { try PlaylistSelection.parse("0-2", count: 3) }
    }
}

@Suite struct NotificationTextTests {
    @Test func onlyFinishAndFailureAreNotified() {
        var item = DownloadItem(url: "https://a.com/v", kind: .video, host: "a.com", presetId: "1080p", destination: "/tmp", title: "Video")
        item.state = .done
        #expect(item.notification(previous: .downloading)! == ("Kervan: indirme bitti", "Video"))
        #expect(item.notification(previous: nil) == nil)            // servis yeni açıldı
        #expect(item.notification(previous: .done) == nil)          // değişiklik yok
        item.state = .failed
        item.lastError = "ERROR: 503"
        #expect(item.notification(previous: .downloading)?.body == "Video — ERROR: 503")
        item.state = .paused
        #expect(item.notification(previous: .downloading) == nil)
        item.state = .done
        item.parentId = 1                                           // playlist çocuğu: grup bildirir
        #expect(item.notification(previous: .downloading) == nil)
    }
}

@Suite struct QueueEngineTests {
    @Test func storeRoundTrip() throws {
        let store = try ItemStore(path: nil)
        var item = DownloadItem(url: "https://x.com/a", kind: .video, host: "x.com", presetId: "1080p", destination: "/tmp")
        item = try store.insert([item])[0]
        item.state = .paused
        item.bytesTotal = 42
        try store.update(item)
        // SQLite tarihleri milisaniyeye yuvarlar; tarih dışı alanlar birebir dönmeli.
        let loaded = try #require(try store.all().first)
        #expect(loaded.id == item.id && loaded.state == .paused && loaded.bytesTotal == 42 && loaded.url == item.url)
        #expect(abs(loaded.createdAt.timeIntervalSince(item.createdAt)) < 0.01)
        try store.delete(ids: [item.id!])
        #expect(try store.all().isEmpty)
    }

    @Test func completesAndRecordsOutput() async throws {
        let engine = try makeEngine(FakeExecutor())
        await engine.start()
        let id = try await addURL(engine, "https://a.com/ok")[0].id!
        #expect(await eventually { await engine.item(id)?.state == .done })
        let item = try #require(await engine.item(id))
        #expect(item.outputPath == "/tmp/ok.mp4")
        #expect(item.bytesDone == 100)
        #expect(item.title == "ok")
    }

    @Test func respectsMaxParallel() async throws {
        let engine = try makeEngine(FakeExecutor(), config: testConfig(parallel: 3))
        await engine.start()
        for host in ["a", "b", "c", "d", "e"] { try await addURL(engine, "https://\(host).com/hang") }
        #expect(await eventually { await engine.list().filter { $0.state == .downloading }.count == 3 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await engine.list().filter { $0.state == .downloading }.count == 3)
        #expect(await engine.list().filter { $0.state == .queued }.count == 2)
        await engine.stop()
    }

    @Test func respectsPerHostLimit() async throws {
        let engine = try makeEngine(FakeExecutor(), config: testConfig(parallel: 5, perHost: 2))
        await engine.start()
        for index in 0..<3 { try await addURL(engine, "https://www.same.com/hang?n=\(index)") }
        try await addURL(engine, "https://other.com/hang")
        #expect(await eventually { await engine.list().filter { $0.state == .downloading }.count == 3 })
        try await Task.sleep(for: .milliseconds(100))
        let active = await engine.list().filter { $0.state == .downloading }
        #expect(active.filter { $0.host == "same.com" }.count == 2)
        await engine.stop()
    }

    @Test func retriesThenFails() async throws {
        let executor = FakeExecutor()
        let engine = try makeEngine(executor)
        await engine.start()
        let id = try await addURL(engine, "https://a.com/fail")[0].id!
        #expect(await eventually { await engine.item(id)?.state == .failed })
        #expect(executor.runs("https://a.com/fail") == 3)
        #expect(await engine.item(id)?.lastError?.contains("network") == true)

        // Elle yeniden deneme sayacı sıfırlar.
        _ = try await engine.apply(.retry, to: [id])
        #expect(await eventually { executor.runs("https://a.com/fail") == 6 })
    }

    @Test func permanentErrorIsNotRetried() async throws {
        let executor = FakeExecutor()
        let engine = try makeEngine(executor)
        await engine.start()
        let id = try await addURL(engine, "https://a.com/perm")[0].id!
        #expect(await eventually { await engine.item(id)?.state == .failed })
        #expect(executor.runs("https://a.com/perm") == 1)
    }

    @Test func pauseResumeCancel() async throws {
        let executor = FakeExecutor()
        let engine = try makeEngine(executor)
        await engine.start()
        let id = try await addURL(engine, "https://a.com/hang")[0].id!
        #expect(await eventually { await engine.item(id)?.state == .downloading })

        _ = try await engine.apply(.pause, to: [id])
        #expect(await eventually { await engine.item(id)?.state == .paused })
        #expect(await engine.item(id)?.speed == nil)

        _ = try await engine.apply(.resume, to: [id])
        #expect(await eventually { await engine.item(id)?.state == .downloading })
        #expect(executor.runs("https://a.com/hang") == 2)

        _ = try await engine.apply(.cancel, to: [id])
        #expect(await eventually { await engine.item(id)?.state == .canceled })
        await #expect(throws: QueueError.invalidTransition(id, from: .canceled, to: .queued)) {
            _ = try await engine.apply(.resume, to: [id])
        }
    }

    @Test func recoversInterruptedItems() async throws {
        let store = try ItemStore(path: nil)
        var item = DownloadItem(url: "https://a.com/ok", kind: .video, host: "a.com", presetId: "1080p", destination: "/tmp")
        item.state = .downloading
        let id = try store.insert([item])[0].id!

        let engine = try makeEngine(FakeExecutor(), store: store)
        await engine.start()
        #expect(await eventually { await engine.item(id)?.state == .done })
        #expect(try store.all().first?.state == .done)
    }

    @Test func stopRequeuesRunning() async throws {
        let store = try ItemStore(path: nil)
        let engine = try makeEngine(FakeExecutor(), store: store)
        await engine.start()
        let id = try await addURL(engine, "https://a.com/hang")[0].id!
        #expect(await eventually { await engine.item(id)?.state == .downloading })
        await engine.stop()
        #expect(try store.all().first?.state == .queued)
    }

    @Test func playlistNeedsSelectionThenCreatesChildren() async throws {
        let engine = try makeEngine(FakeExecutor(), resolver: FakeResolver(entries: 3))
        await engine.start()
        let outcome = try await engine.add(url: URL(string: "https://e.com/list")!,
                                           options: AddOptions(destination: "/tmp", cookies: CookiePolicy("none")))
        guard case .needsSelection(let title, let entries, _) = outcome else {
            Issue.record("seçim istenmeliydi")
            return
        }
        #expect(title == "Liste")
        #expect(entries.count == 3)
        #expect(await engine.list().isEmpty)

        let added = try await addURL(engine, "https://e.com/list", selection: "1,3")
        #expect(added.map(\.kind) == [.group, .video, .video])
        #expect(added.dropFirst().map(\.url) == ["https://e.com/v1/ok", "https://e.com/v3/ok"])
        let groupId = added[0].id!
        #expect(await eventually { await engine.item(groupId)?.state == .done })
        #expect(await engine.item(groupId)?.message == "2/2 bitti")

        _ = try await engine.apply(.remove, to: [groupId])
        #expect(await engine.list().isEmpty)
    }

    @Test func filenameHintIsMadeUnique() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "kervan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appending(path: "Sayfa.mp4"))

        let engine = try makeEngine(FakeExecutor(), resolver: FakeResolver(generic: true))
        func add() async throws -> DownloadItem? {
            var options = AddOptions(destination: directory.path, cookies: CookiePolicy("none"), context: RequestContext(filename: "Sayfa"))
            options.force = true
            let outcome = try await engine.add(url: URL(string: "https://a.com/master.m3u8")!, options: options)
            guard case .added(let items, _) = outcome else { return nil }
            return items.first
        }
        #expect(try await add()?.filename == "Sayfa (2)")
        #expect(try await add()?.filename == "Sayfa (3)")
        #expect(try await add()?.title == "Sayfa (4)")

        // Noktalı ad ilk noktadan kesilmez; yarım parça dosyası da adı tutar.
        try Data().write(to: directory.appending(path: "Mr.mp4"))
        try Data().write(to: directory.appending(path: "Dizi.f137.mp4.part"))
        #expect(await engine.uniqueFilename("Mr. Robot", in: directory.path) == "Mr. Robot")
        #expect(await engine.uniqueFilename("Dizi", in: directory.path) == "Dizi (2)")
    }

    @Test func cancelRemovesPartialFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "kervan-c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appending(path: "Başka.mp4"))
        let engine = try makeEngine(FakeExecutor())
        await engine.start()
        let outcome = try await engine.add(url: URL(string: "https://a.com/partial")!, options: AddOptions(
            destination: directory.path, cookies: CookiePolicy("none")))
        guard case .added(let items, _) = outcome, let id = items.first?.id else { return Issue.record("eklenmedi") }
        let part = directory.appending(path: "Video [p1].mp4.part")
        #expect(await eventually { await engine.item(id)?.partialPath != nil })
        #expect(FileManager.default.fileExists(atPath: part.path))

        _ = try await engine.apply(.cancel, to: [id])
        #expect(await eventually { await engine.item(id)?.state == .canceled })
        #expect(!FileManager.default.fileExists(atPath: part.path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Başka.mp4").path))
    }

    @Test func duplicateNeedsForceAndCleanKeepsFiles() async throws {
        let engine = try makeEngine(FakeExecutor())
        await engine.start()
        let first = try await addURL(engine, "https://a.com/ok")[0].id!
        #expect(await eventually { await engine.item(first)?.state == .done })
        await #expect(throws: QueueError.duplicate(first, .done)) { try await addURL(engine, "https://a.com/ok") }

        var options = AddOptions(destination: "/tmp/kervan-test", cookies: CookiePolicy("none"))
        options.force = true
        guard case .added(let again, _) = try await engine.add(url: URL(string: "https://a.com/ok")!, options: options),
              let second = again.first?.id else { return Issue.record("eklenmedi") }
        #expect(await eventually { await engine.item(second)?.state == .done })

        let waiting = try await addURL(engine, "https://a.com/hang")[0].id!
        let removed = await engine.clean()
        #expect(Set(removed) == [first, second])
        #expect(await engine.list().map(\.id) == [waiting])
    }

    @Test func actionWithUnknownIdChangesNothing() async throws {
        let engine = try makeEngine(FakeExecutor())
        let id = try await addURL(engine, "https://a.com/hang")[0].id!
        await #expect(throws: QueueError.notFound(999)) { try await engine.apply(.pause, to: [id, 999]) }
        #expect(await engine.item(id)?.state != .paused)  // ilk öğe de duraklatılmadı
    }

    @Test func nonGenericSiteIgnoresFilenameHint() async throws {
        let engine = try makeEngine(FakeExecutor())
        let outcome = try await engine.add(url: URL(string: "https://youtube.com/watch")!, options: AddOptions(
            destination: "/tmp", cookies: CookiePolicy("none"), context: RequestContext(filename: "Sekme başlığı")))
        guard case .added(let items, _) = outcome else { return }
        #expect(items.first?.filename == nil)
        #expect(items.first?.title == "watch")
    }

    @Test func subscribersReceiveUpdates() async throws {
        let engine = try makeEngine(FakeExecutor())
        let events = await engine.subscribe()
        await engine.start()
        let id = try await addURL(engine, "https://a.com/ok")[0].id!
        var states: [ItemState] = []
        for await event in events {
            if case .updated(let item) = event, item.id == id {
                states.append(item.state)
                if item.state == .done { break }
            }
        }
        #expect(states.first == .queued)
        #expect(states.contains(.downloading))
        #expect(states.last == .done)
    }

    @Test(arguments: [
        (EngineError.toolFailed(.ytDlp, status: 1, message: "ERROR: HTTP Error 503"), true),
        (EngineError.toolFailed(.ytDlp, status: 1, message: "ERROR: [vimeo] x: logged-in"), false),
        (EngineError.ffmpegMissing, false),
        (EngineError.aria2NotReady, true),
    ])
    func retryPolicy(error: EngineError, retryable: Bool) {
        #expect(QueueEngine.isRetryable(error) == retryable)
    }
}
