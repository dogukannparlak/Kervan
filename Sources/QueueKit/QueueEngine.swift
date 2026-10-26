import EngineCore
import Foundation

public enum QueueEvent: Sendable, Equatable {
    case updated(DownloadItem)
    case removed(Int64)
}

public enum AddOutcome: Sendable, Equatable {
    case added([DownloadItem], notes: [String])
    /// Çok videolu sayfa: hangi videoların ineceği seçilmeli.
    case needsSelection(title: String?, entries: [ProbeResult.Entry], notes: [String])
}

public struct AddOptions: Sendable {
    public var presetId: String
    public var destination: String
    public var cookies: CookiePolicy
    /// Çok videolu sayfada seçim ("all", "1,3"); nil ise `needsSelection` döner.
    public var selection: String?
    public var context: RequestContext
    /// Gömülecek altyazı dilleri; nil ise altyazı yok.
    public var subtitles: String?
    /// true ise `destination/<Kategori>/` altına iner.
    public var categorize: Bool
    /// true ise aynı link/video listede olsa da eklenir.
    public var force = false
    /// İstemcinin seçtiği kalitenin ya da yakalanan dosyanın yaklaşık boyutu (bayt).
    public var sizeHint: Int64?

    public init(presetId: String = "1080p", destination: String, cookies: CookiePolicy = CookiePolicy("auto"),
                selection: String? = nil, context: RequestContext = RequestContext(), subtitles: String? = nil,
                categorize: Bool = false) {
        self.presetId = presetId
        self.destination = destination
        self.cookies = cookies
        self.selection = selection
        self.context = context
        self.subtitles = subtitles
        self.categorize = categorize
    }
}

public enum QueueAction: String, Codable, Sendable {
    case pause, resume, cancel, retry, remove
}

/// Kuyruğun tek sahibi. Durum geçişleri yalnız burada, `ItemState.canTransition` tablosuyla yapılır.
public actor QueueEngine {
    public struct Config: Sendable {
        public var maxParallel = 3
        public var maxPerHost = 2
        /// Aynı siteye art arda başlatmalar arası bekleme (rate-limit).
        public var hostStartGap: Duration = .seconds(2)
        public var maxAttempts = 3
        public var backoffBase: TimeInterval = 10
        public var backoffCap: TimeInterval = 600
        public var persistInterval: Duration = .seconds(1)
        public var broadcastInterval: Duration = .milliseconds(250)
        public var tickInterval: Duration = .seconds(1)

        public init() {}
    }

    private let store: ItemStore
    private let executor: any DownloadExecuting
    private let resolver: any LinkResolving
    private let logs: LogStore?
    private var config: Config

    private var items: [Int64: DownloadItem] = [:]
    private var running: [Int64: Task<Void, Never>] = [:]
    /// Çalışan öğe durdurulunca varacağı durum (pause → paused, cancel → canceled, kapanış → queued).
    private var pendingStop: [Int64: ItemState] = [:]
    private var pendingRemove: Set<Int64> = []
    /// Silinen ama süreci henüz durmamış öğelerin yarım dosyası: süreç durunca silinir.
    private var purgeAfterStop: [Int64: String] = [:]
    private var lastHostStart: [String: ContinuousClock.Instant] = [:]
    private var lastPersist: [Int64: ContinuousClock.Instant] = [:]
    private var lastBroadcast: [Int64: ContinuousClock.Instant] = [:]
    private var subscribers: [UUID: AsyncStream<QueueEvent>.Continuation] = [:]
    private var ticker: Task<Void, Never>?
    /// Kapanışta yeni indirme başlatılmaz.
    private var stopping = false

    public init(store: ItemStore, executor: any DownloadExecuting, resolver: any LinkResolving,
                logs: LogStore? = nil, config: Config = Config()) throws {
        self.store = store
        self.executor = executor
        self.resolver = resolver
        self.logs = logs
        self.config = config
        for item in try store.all() {
            if let id = item.id { items[id] = item }
        }
    }

    // MARK: - Yaşam döngüsü

    /// Çökme kurtarma: yarıda kalan öğeler kuyruğa döner (`.part` dosyasından devam eder).
    public func start() {
        for (id, item) in items where item.kind != .group && item.state.isActive {
            var item = item
            item.state = .queued
            item.speed = nil
            item.eta = nil
            save(item, force: true)
            _ = id
        }
        ticker = Task { [config] in
            while !Task.isCancelled {
                self.schedule()
                try? await Task.sleep(for: config.tickInterval)
            }
        }
    }

    /// Kapanış: çalışanlar durdurulur ve `queued` olarak kaydedilir.
    public func stop() async {
        stopping = true
        ticker?.cancel()
        for (id, task) in running {
            pendingStop[id] = .queued
            task.cancel()
        }
        let deadline = ContinuousClock.now + .seconds(7)
        while !running.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Sorgular

    public func list() -> [DownloadItem] {
        items.values.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    public func item(_ id: Int64) -> DownloadItem? { items[id] }

    public func log(_ id: Int64, lines: Int) throws -> [String] {
        guard items[id] != nil else { throw QueueError.notFound(id) }
        return logs?.tail(id, lines: lines) ?? []
    }

    public func subscribe() -> AsyncStream<QueueEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<QueueEvent>.makeStream(bufferingPolicy: .bufferingNewest(1000))
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    // MARK: - Ekleme

    public func add(url: URL, options: AddOptions) async throws -> AddOutcome {
        guard try PresetStore.named(options.presetId) != nil else { throw QueueError.unknownPreset(options.presetId) }
        if !options.force, let existing = duplicate(url: url.absoluteString, mediaId: nil) { throw existing }
        let resolved = try await resolver.resolve(url, cookies: options.cookies, context: options.context)
        let kind: ItemKind = resolved.kind == .http ? .http : .video
        let destination = options.categorize
            ? (options.destination as NSString).appendingPathComponent(DownloadCategory.of(kind: kind, presetId: options.presetId, url: url).rawValue)
            : options.destination
        var base = DownloadItem(url: url.absoluteString, kind: .video, host: DownloadItem.host(of: url), presetId: options.presetId,
                                destination: destination, cookiesBrowser: resolved.cookiesBrowser, maxAttempts: config.maxAttempts)
        base.referer = options.context.referer
        base.userAgent = options.context.userAgent
        base.subtitles = options.subtitles
        base.filename = options.context.filename.map { uniqueFilename($0, in: destination) }
        // Boyut indirme başlamadan görünsün: istemcinin bildirdiği ya da probe'daki kaliteden tahmin.
        base.bytesTotalEstimate = options.sizeHint
        var added: [DownloadItem]
        switch resolved.kind {
        case .http:
            base.kind = .http
            base.title = base.filename ?? (url.lastPathComponent.isEmpty ? url.host() : url.lastPathComponent)
            added = try store.insert([base])
        case .video(let info):
            if let extractor = info.extractor, let videoId = info.id { base.mediaId = "\(extractor):\(videoId)" }
            if base.bytesTotalEstimate == nil { base.bytesTotalEstimate = info.qualities?.estimatedSize(for: options.presetId) }
            // Aynı video başka bir linkle (kısa link, farklı parametre) eklenmiş olabilir.
            if !options.force, let existing = duplicate(url: nil, mediaId: base.mediaId) { throw existing }
            // Genel çıkarıcı (m3u8, düz mp4) başlık olarak "master" gibi dosya adı verir; sayfa başlığı daha iyi.
            base.title = info.extractor == "generic" ? (base.filename ?? info.title) : info.title
            if info.extractor != "generic" { base.filename = nil }
            added = try store.insert([base])
        case .playlist(let info):
            let entries = info.entries ?? []
            base.filename = nil
            base.bytesTotalEstimate = nil  // listenin boyutu değil; her video kendi boyutunu inerken alır
            guard let selection = options.selection else {
                return .needsSelection(title: info.title, entries: entries, notes: resolved.notes)
            }
            let indices = try PlaylistSelection.parse(selection, count: entries.count)
            var group = base
            group.kind = .group
            group.title = info.title
            group = try store.insert([group])[0]
            let children = indices.map { index in
                let entry = entries[index - 1]
                var child = base
                child.parentId = group.id
                child.title = entry.title ?? "\(info.title ?? "video") #\(index)"
                if let link = entry.url, let entryURL = URL(string: link), ["http", "https"].contains(entryURL.scheme ?? "") {
                    child.url = link
                    child.host = DownloadItem.host(of: entryURL)
                } else {
                    child.playlistIndex = index
                }
                return child
            }
            added = [group] + (try store.insert(children))
        }
        for item in added {
            guard let id = item.id else { continue }
            items[id] = item
            broadcast(.updated(item))
        }
        refreshGroups(of: added)
        schedule()
        return .added(added.compactMap { $0.id }.compactMap { items[$0] }, notes: resolved.notes)
    }

    /// Aynı link ya da aynı video (yt-dlp kimliği) listede varsa en yenisi için hata; yoksa nil.
    private func duplicate(url: String?, mediaId: String?) -> QueueError? {
        let match = items.values.filter { item in
            item.kind != .group && ((url != nil && item.url == url) || (mediaId != nil && item.mediaId == mediaId))
        }.max { ($0.id ?? 0) < ($1.id ?? 0) }
        guard let match, let id = match.id else { return nil }
        return .duplicate(id, match.state)
    }

    /// Bitmiş ve iptal edilmiş öğeleri listeden siler (dosyalara dokunmaz); boş kalan grup da gider.
    /// Silinen kimlikleri döner.
    public func clean() -> [Int64] {
        let finished = items.values.filter { $0.kind != .group && ($0.state == .done || $0.state == .canceled) }
        let parents = Set(finished.compactMap(\.parentId))
        for id in finished.compactMap(\.id) { removeNow(id) }
        let emptyGroups = parents.filter { parent in !items.values.contains { $0.parentId == parent } }
        for id in emptyGroups { removeNow(id) }
        refreshGroups(ids: Array(parents.subtracting(emptyGroups)))
        return finished.compactMap(\.id) + emptyGroups.sorted()
    }

    /// Aynı klasörde aynı adlı dosya (uzantı ne olursa olsun: "ad.mp4", "ad.f137.mp4.part") ya da kuyruk öğesi
    /// varsa " (2)", " (3)"… ekler. Yoksa yt-dlp "zaten indirilmiş" deyip hiçbir şey indirmeden biter.
    /// Ad noktadan kesilmez: "Mr. Robot" ile "Mr.mp4" çakışmaz.
    func uniqueFilename(_ name: String, in destination: String) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []
        let queued = Set(items.values.filter { $0.destination == destination }.compactMap(\.filename))
        func isTaken(_ candidate: String) -> Bool {
            queued.contains(candidate) || files.contains { $0 == candidate || $0.hasPrefix(candidate + ".") }
        }
        var candidate = name
        var counter = 2
        while isTaken(candidate) {
            candidate = "\(name) (\(counter))"
            counter += 1
        }
        return candidate
    }

    /// Ayarlardan gelen eşzamanlılık sınırları; hemen uygulanır (çalışanlar durdurulmaz).
    public func updateLimits(maxParallel: Int, maxPerHost: Int) {
        config.maxParallel = maxParallel
        config.maxPerHost = maxPerHost
        schedule()
    }

    /// Aktif (inen/işlenen) öğe var mı? Güncelleyici bunu bekler.
    public var hasActiveDownloads: Bool { items.values.contains { $0.kind != .group && $0.state.isActive } }

    /// Bir linkin kalite seçenekleri (kuyruğa bir şey eklemez).
    public nonisolated func qualities(url: URL, cookies: CookiePolicy, context: RequestContext) async throws -> QualityList {
        try await resolver.qualities(url, cookies: cookies, context: context)
    }

    // MARK: - Kullanıcı eylemleri

    /// Grup kimliği verilirse eylem çocuklarına uygulanır (uygun olmayanlar atlanır).
    public func apply(_ action: QueueAction, to ids: [Int64]) throws -> [DownloadItem] {
        // Önce hepsi denetlenir: bulunmayan bir kimlik yüzünden yarısı uygulanıp "başarısız" dönmesin.
        if let missing = ids.first(where: { items[$0] == nil }) { throw QueueError.notFound(missing) }
        var touched: [Int64] = []
        for id in ids {
            guard let item = items[id] else { throw QueueError.notFound(id) }
            if item.kind == .group {
                let children = items.values.filter { $0.parentId == id }.compactMap(\.id).sorted()
                for child in children { try? perform(action, on: child) }
                touched += children
                if action == .remove { removeNow(id) } else { touched.append(id) }
            } else {
                try perform(action, on: id)
                touched.append(id)
            }
        }
        refreshGroups(ids: touched)
        schedule()
        return touched.compactMap { items[$0] }
    }

    private func perform(_ action: QueueAction, on id: Int64) throws {
        guard var item = items[id] else { throw QueueError.notFound(id) }
        switch action {
        case .pause:
            if running[id] != nil {
                try requireTransition(item, .paused)
                stopRunning(id, as: .paused)
            } else {
                try transition(&item, .paused)
                save(item, force: true)
            }
        case .resume:
            // Yalnız duraklatılanlar; hatalı/iptal edilmiş öğe için `retry` kullanılır.
            guard item.state == .paused else { throw QueueError.invalidTransition(id, from: item.state, to: .queued) }
            try transition(&item, .queued)
            item.nextAttemptAt = nil
            save(item, force: true)
        case .cancel:
            // Yarım dosyalar silinir (çalışıyorsa süreç durunca, `finish`'te).
            if running[id] != nil {
                stopRunning(id, as: .canceled)
            } else {
                try transition(&item, .canceled)
                clearSpeed(&item)
                purgePartials(&item)
                save(item, force: true)
            }
        case .retry:
            try transition(&item, .queued)
            item.attempt = 0
            item.lastError = nil
            item.nextAttemptAt = nil
            save(item, force: true)
        case .remove:
            // Bitmemiş öğe silinince yarım dosyaları da gider; bitmiş dosyaya dokunulmaz.
            if running[id] != nil {
                pendingRemove.insert(id)
                if let path = item.partialPath { purgeAfterStop[id] = path }
                stopRunning(id, as: .canceled)
            } else if item.state != .done {
                purgePartials(&item)
            }
            removeNow(id)
        }
    }

    private func stopRunning(_ id: Int64, as state: ItemState) {
        pendingStop[id] = state
        running[id]?.cancel()
    }

    private func removeNow(_ id: Int64) {
        try? store.delete(ids: [id])
        items[id] = nil
        logs?.remove(id)
        broadcast(.removed(id))
    }

    // MARK: - Zamanlama

    func schedule() {
        guard !stopping else { return }
        let now = Date()
        let clock = ContinuousClock.now
        var perHost: [String: Int] = [:]
        for id in running.keys { if let host = items[id]?.host { perHost[host, default: 0] += 1 } }

        let ready = items.values
            .filter { $0.kind != .group && $0.state == .queued && ($0.nextAttemptAt ?? .distantPast) <= now && running[$0.id ?? 0] == nil }
            .sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        for item in ready {
            guard running.count < config.maxParallel else { break }
            guard perHost[item.host, default: 0] < config.maxPerHost else { continue }
            if let last = lastHostStart[item.host], clock - last < config.hostStartGap { continue }
            launch(item)
            perHost[item.host, default: 0] += 1
            lastHostStart[item.host] = clock
        }
    }

    private func launch(_ item: DownloadItem) {
        guard let id = item.id else { return }
        var item = item
        guard (try? transition(&item, .downloading)) != nil else { return }
        item.message = nil
        save(item, force: true)
        refreshGroups(ids: [id])

        let events = executor.run(item)
        running[id] = Task {
            do {
                for try await event in events { self.handle(event, for: id) }
                self.finish(id, error: nil)
            } catch {
                self.finish(id, error: error)
            }
        }
    }

    private func handle(_ event: DownloadEvent, for id: Int64) {
        guard var item = items[id], pendingStop[id] == nil else { return }
        switch event {
        case .progress(let progress):
            let target: ItemState = progress.phase == .postprocess ? .postprocessing : .downloading
            if item.state != target { try? transition(&item, target) }
            if progress.phase != .postprocess || progress.bytesDone > 0 { item.bytesDone = progress.bytesDone }
            if let total = progress.bytesTotal { item.bytesTotal = total }
            if let estimate = progress.bytesTotalEstimate { item.bytesTotalEstimate = estimate }
            item.speed = progress.speed
            item.eta = progress.eta
            item.message = progress.message
            save(item, force: false)
        case .log(let line):
            logs?.append(id, line.text)
        case .started(let file):
            item.partialPath = file.path
            save(item, force: true)
        case .completed(let file):
            Quarantine.mark(file)
            item.outputPath = file.path
            save(item, force: true)
        }
    }

    private func finish(_ id: Int64, error: Error?) {
        running[id] = nil
        let stopState = pendingStop.removeValue(forKey: id)
        if pendingRemove.remove(id) != nil {
            if let path = purgeAfterStop.removeValue(forKey: id) { PartialFiles.remove(for: path) }
            return
        }
        guard var item = items[id] else { return }
        clearSpeed(&item)

        if let stopState {
            try? transition(&item, stopState)
            if stopState == .canceled { purgePartials(&item) }
        } else if let error {
            item.attempt += 1
            // Kullanıcıya Türkçe ve önerili metin; ham hata log'da.
            item.lastError = ErrorText.friendly(error)
            logs?.append(id, "HATA (deneme \(item.attempt)/\(item.maxAttempts)): \(String(describing: error))")
            if Self.isRetryable(error) && item.attempt < item.maxAttempts {
                let delay = min(config.backoffCap, config.backoffBase * pow(2, Double(item.attempt - 1)))
                item.nextAttemptAt = Date().addingTimeInterval(delay)
                try? transition(&item, .queued)
                item.message = "yeniden denenecek (\(item.attempt)/\(item.maxAttempts))"
            } else {
                try? transition(&item, .failed)
            }
        } else {
            try? transition(&item, .done)
            item.finishedAt = Date()
            if let total = item.bytesTotal ?? item.bytesTotalEstimate { item.bytesDone = max(item.bytesDone, total) }
            item.message = nil
        }
        save(item, force: true)
        refreshGroups(ids: [id])
        schedule()
    }

    /// Kalıcı hatalar yeniden denenmez (giriş, eksik araç, desteklenmeyen/olmayan video).
    static func isRetryable(_ error: Error) -> Bool {
        if YtDlpAdapter.isLoginError(error) { return false }
        switch error {
        case EngineError.ffmpegMissing, EngineError.toolMissing, EngineError.loginRequired, EngineError.invalidProbeOutput:
            return false
        case EngineError.toolFailed(_, _, let message):
            let permanent = ["unsupported url", "video unavailable", "private video", "http error 404", "http error 410",
                             "requested format is not available"]
            return !permanent.contains { message.lowercased().contains($0) }
        case is QueueError:
            return false
        default:
            return true
        }
    }

    // MARK: - Yardımcılar

    private func transition(_ item: inout DownloadItem, _ next: ItemState) throws {
        if item.kind == .group || item.state == next {
            item.state = next
            return
        }
        try requireTransition(item, next)
        item.state = next
    }

    private func requireTransition(_ item: DownloadItem, _ next: ItemState) throws {
        guard item.state.canTransition(to: next) else {
            throw QueueError.invalidTransition(item.id ?? 0, from: item.state, to: next)
        }
    }

    /// İptal edilen öğenin yarım dosyalarını siler ve log'a yazar.
    private func purgePartials(_ item: inout DownloadItem) {
        guard let path = item.partialPath else { return }
        let removed = PartialFiles.remove(for: path)
        if let id = item.id, !removed.isEmpty {
            logs?.append(id, "yarım dosyalar silindi: \(removed.map(\.lastPathComponent).joined(separator: ", "))")
        }
        item.partialPath = nil
        item.bytesDone = 0
    }

    private func clearSpeed(_ item: inout DownloadItem) {
        item.speed = nil
        item.eta = nil
    }

    /// Belleği hemen günceller; diske en fazla `persistInterval`'da bir, yayına `broadcastInterval`'da bir yazar.
    private func save(_ item: DownloadItem, force: Bool) {
        guard let id = item.id else { return }
        var item = item
        item.updatedAt = Date()
        items[id] = item
        let now = ContinuousClock.now
        if force || now - (lastPersist[id] ?? now - .seconds(60)) >= config.persistInterval {
            try? store.update(item)
            lastPersist[id] = now
        }
        if force || now - (lastBroadcast[id] ?? now - .seconds(60)) >= config.broadcastInterval {
            broadcast(.updated(item))
            lastBroadcast[id] = now
        }
    }

    private func broadcast(_ event: QueueEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func refreshGroups(of added: [DownloadItem]) {
        refreshGroups(ids: added.compactMap(\.id))
    }

    /// Grup satırının durumu ve baytları çocuklarından hesaplanır.
    private func refreshGroups(ids: [Int64]) {
        let parents = Set(ids.compactMap { items[$0]?.parentId } + ids.filter { items[$0]?.kind == .group })
        for parentId in parents {
            guard var group = items[parentId] else { continue }
            let children = items.values.filter { $0.parentId == parentId }
            guard !children.isEmpty else { continue }
            let states = Set(children.map(\.state))
            group.state = if states.contains(where: \.isActive) { .downloading }
                else if states.contains(.queued) { .queued }
                else if states.contains(.paused) { .paused }
                else if states.contains(.failed) { .failed }
                else if states == [.canceled] { .canceled }
                else { .done }
            group.bytesDone = children.reduce(0) { $0 + $1.bytesDone }
            let done = children.filter { $0.state == .done }.count
            group.message = "\(done)/\(children.count) bitti"
            group.speed = children.compactMap(\.speed).reduce(0, +)
            if group.speed == 0 { group.speed = nil }
            save(group, force: true)
        }
    }
}
