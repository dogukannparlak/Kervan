import Foundation

/// `yt-dlp -J --flat-playlist` çıktısının ihtiyacımız olan kısmı.
public struct ProbeResult: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let id: String?
        public let title: String?
        public let url: String?

        public init(id: String?, title: String?, url: String?) {
            self.id = id
            self.title = title
            self.url = url
        }
    }

    public let id: String?
    public let title: String?
    public let extractor: String?
    public let type: String?
    public let direct: Bool?
    public let duration: Double?
    public let webpageURL: String?
    public let entries: [Entry]?
    /// Tek videoda kalite seçenekleri ve yaklaşık boyutları (aynı `-J` çıktısından); kuyruktaki öğenin boyutu
    /// indirme başlamadan bununla gösterilir.
    public var qualities: [QualityOption]? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, extractor, direct, duration, entries
        case type = "_type"
        case webpageURL = "webpage_url"
    }

    public var isPlaylist: Bool { type == "playlist" }
}

public struct YtDlpAdapter: Sendable {
    let executable: URL
    let ffmpeg: URL?
    let runner: any ProcessRunning
    let environment: [String: String]
    /// Aynı linkin `-J` çıktısı kısa süre saklanır: kalite listesi, sınıflandırma ve ekleme tek çıkarma yapar.
    let probeCache = ProbeCache()

    public init(executable: URL, ffmpeg: URL?, runner: any ProcessRunning = SystemProcessRunner(), environment: [String: String]) {
        self.executable = executable
        self.ffmpeg = ffmpeg
        self.runner = runner
        self.environment = environment
    }

    /// `cookiesFromBrowser`: yt-dlp `--cookies-from-browser` değeri (ör. "brave").
    public func probe(_ url: URL, cookiesFromBrowser: String? = nil, context: RequestContext = RequestContext()) async throws -> ProbeResult {
        let data = try await probeJSON(url, cookiesFromBrowser: cookiesFromBrowser, context: context)
        do {
            var probe = try JSONDecoder().decode(ProbeResult.self, from: data)
            if !probe.isPlaylist, let formats = try? JSONDecoder().decode(FormatProbe.self, from: data) {
                probe.qualities = QualityPlanner.options(from: formats)
            }
            return probe
        } catch {
            throw EngineError.invalidProbeOutput(String(describing: error))
        }
    }

    /// `yt-dlp -J --flat-playlist` çıktısı; aynı (link, çerez, başlık) için 5 dakika önbellekten gelir.
    /// `singleVideo`: link bir listeye de işaret etse (`&list=…`, karışık liste) yalnız o videoyu çıkarır.
    func probeJSON(_ url: URL, cookiesFromBrowser: String?, context: RequestContext, singleVideo: Bool = false) async throws -> Data {
        let args = ["-J", "--flat-playlist", "--no-warnings"] + (singleVideo ? ["--no-playlist"] : [])
            + Self.cookieArguments(cookiesFromBrowser)
            + Self.headerArguments(context) + ["--", url.absoluteString]
        let key = args.joined(separator: "\u{1F}")
        return try await probeCache.value(for: key) {
            let process = try runner.start(executable, arguments: args, environment: environment)
            let result = await process.collect()
            guard result.status == 0 else {
                throw EngineError.toolFailed(.ytDlp, status: result.status, message: Self.errorMessage(result.stderr))
            }
            return Data(result.stdout.joined().utf8)
        }
    }

    /// `playlistItems`: yt-dlp `--playlist-items` ifadesi ("1,3", "1:5"); nil ise yalnız tek video.
    /// Her biten dosya için bir `.completed` olayı gelir.
    public func download(_ url: URL, preset: Preset, to directory: URL, cookiesFromBrowser: String? = nil,
                         playlistItems: String? = nil, context: RequestContext = RequestContext(),
                         subtitles: String? = nil) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if preset.requiresFFmpeg && ffmpeg == nil { throw EngineError.ffmpegMissing }
                    let args = downloadArguments(url, preset: preset, to: directory, cookiesFromBrowser: cookiesFromBrowser,
                                                 playlistItems: playlistItems, context: context, subtitles: subtitles)
                    let process = try runner.start(executable, arguments: args, environment: environment)
                    var tracker = YtDlpProgressTracker()
                    var stderr: [String] = []
                    var completed = 0
                    await withTaskCancellationHandler {
                        for await line in process.output {
                            if line.source == .stderr { stderr.append(line.text) }
                            let event = tracker.consume(line) ?? .log(line)
                            if case .completed = event { completed += 1 }
                            continuation.yield(event)
                        }
                    } onCancel: {
                        Task { await process.terminate() }
                    }
                    let status = await process.waitUntilExit()
                    try Task.checkCancellation()
                    guard status == 0 else {
                        throw EngineError.toolFailed(.ytDlp, status: status, message: Self.errorMessage(stderr))
                    }
                    guard completed > 0 else { throw EngineError.noOutputFile }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func downloadArguments(_ url: URL, preset: Preset, to directory: URL, cookiesFromBrowser: String? = nil,
                           playlistItems: String? = nil, context: RequestContext = RequestContext(),
                           subtitles: String? = nil) -> [String] {
        // yt-dlp şablonunda % özel karakter; ipucu adında %% olarak kaçırılır.
        let template = context.filename.map { $0.replacingOccurrences(of: "%", with: "%%") + ".%(ext)s" }
            ?? "%(title).200B [%(id)s].%(ext)s"
        let playlist = playlistItems.map { ["--yes-playlist", "--playlist-items", $0] } ?? ["--no-playlist"]
        var args = [
            "--newline", "--progress", "--color", "never",
            "--retries", "10", "--fragment-retries", "10",
            "-f", preset.format,
            "-P", directory.path,
            "-o", template,
            "--progress-template", "download:\(YtDlpProgressTracker.downloadPrefix)|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.fragment_index)s|%(progress.fragment_count)s",
            "--progress-template", "postprocess:\(YtDlpProgressTracker.postprocessPrefix)|%(progress.status)s|%(progress.postprocessor)s",
            "--print", "video:\(YtDlpProgressTracker.infoPrefix)|%(format_id)s|%(filesize,filesize_approx)s",
            "--print", "before_dl:\(YtDlpProgressTracker.pathPrefix)|%(filename)s",
            "--print", "after_move:\(YtDlpProgressTracker.filePrefix)|%(filepath)s",
        ]
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        if let container = preset.container { args += ["--merge-output-format", container] }
        // Altyazı yalnız görüntülü preset'lerde gömülür (mp4/mkv kabı); ses preset'lerinde atlanır.
        if let subtitles, preset.container != nil {
            args += ["--write-subs", "--sub-langs", subtitles, "--embed-subs"]
        }
        return args + playlist + Self.cookieArguments(cookiesFromBrowser) + Self.headerArguments(context)
            + preset.extraArgs + ["--", url.absoluteString]
    }

    static func headerArguments(_ context: RequestContext) -> [String] {
        context.httpHeaders.sorted { $0.key < $1.key }.flatMap { ["--add-headers", "\($0.key):\($0.value)"] }
    }

    static func cookieArguments(_ browser: String?) -> [String] {
        browser.map { ["--cookies-from-browser", $0] } ?? []
    }

    static func errorMessage(_ stderr: [String]) -> String {
        stderr.last { $0.hasPrefix("ERROR:") } ?? stderr.last ?? "ayrıntı yok"
    }

    /// Site giriş istiyor mu? (yt-dlp mesajları: "--cookies-from-browser", "logged-in", "authentication").
    public static func isLoginError(_ error: Error) -> Bool {
        guard case EngineError.toolFailed(.ytDlp, _, let message) = error else { return false }
        let text = message.lowercased()
        return ["cookies", "logged-in", "log in", "login", "authentication", "sign in"].contains { text.contains($0) }
    }
}

/// yt-dlp'nin `KERVAN_*` satırlarını ilerleme olaylarına çevirir.
/// Video + ses ayrı parçalar halinde iner; toplam, `KERVAN_INFO`'daki yaklaşık boyuttan gelir.
/// Çok videolu indirmede her `KERVAN_INFO` yeni bir videoyu başlatır.
struct YtDlpProgressTracker {
    static let infoPrefix = "KERVAN_INFO"
    static let downloadPrefix = "KERVAN_DL"
    static let postprocessPrefix = "KERVAN_PP"
    static let filePrefix = "KERVAN_FILE"
    static let pathPrefix = "KERVAN_PATH"

    private var videos = 0
    private var parts = 1
    private var finishedParts = 0
    private var finishedBytes: Int64 = 0
    private var approximateTotal: Int64?

    mutating func consume(_ line: OutputLine) -> DownloadEvent? {
        let fields = line.text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch fields.first {
        case Self.infoPrefix where fields.count >= 3:
            videos += 1
            parts = fields[1].split(separator: "+").count
            finishedParts = 0
            finishedBytes = 0
            approximateTotal = Self.bytes(fields[2])
            return .progress(ProgressEvent(phase: .download, bytesTotalEstimate: approximateTotal, message: partMessage))

        case Self.downloadPrefix where fields.count >= 7:
            // HLS/DASH'te tahmin ve kalan süre ondalıklı gelir ("71900.0", "121.98"); hepsi Double'dan okunur.
            let downloaded = Self.bytes(fields[2]) ?? 0
            var estimate = Self.bytes(fields[4])
            if estimate == nil, fields.count >= 9, let index = Double(fields[7]), let count = Double(fields[8]), index > 0, count > 0 {
                estimate = Int64(Double(downloaded) * count / index)  // parça oranından kaba tahmin
            }
            let partTotal = Self.bytes(fields[3]) ?? estimate
            var event = ProgressEvent(phase: .download, bytesDone: finishedBytes + downloaded,
                                      speed: Double(fields[5]), eta: Double(fields[6]).map { Int($0.rounded()) }, message: partMessage)
            if parts == 1, let total = Self.bytes(fields[3]) {
                event.bytesTotal = total
            } else if let approximateTotal {
                event.bytesTotalEstimate = max(approximateTotal, event.bytesDone)
            } else if let partTotal {
                event.bytesTotalEstimate = finishedBytes + partTotal
            }
            if fields[1] == "finished" {
                finishedBytes += partTotal ?? downloaded
                finishedParts += 1
            }
            return .progress(event)

        case Self.postprocessPrefix where fields.count >= 3:
            guard fields[1] == "started" else { return .log(line) }
            return .progress(ProgressEvent(phase: .postprocess, bytesDone: finishedBytes, message: fields[2]))

        case Self.filePrefix:
            return .completed(URL(filePath: String(line.text.dropFirst(Self.filePrefix.count + 1))))

        case Self.pathPrefix:
            return .started(URL(filePath: String(line.text.dropFirst(Self.pathPrefix.count + 1))))

        default:
            return nil
        }
    }

    static func bytes(_ field: String) -> Int64? {
        Double(field).flatMap { $0.isFinite && $0 >= 0 ? Int64($0) : nil }
    }

    private var partMessage: String? {
        var labels: [String] = []
        if videos > 1 { labels.append("video \(videos)") }
        if parts > 1 { labels.append("parça \(min(finishedParts + 1, parts))/\(parts)") }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
}


/// Başarılı `-J` çıktılarını kısa süre tutar; aynı anda gelen istekler tek çıkarmayı bekler. Hata saklanmaz.
final class ProbeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: (Task<Data, Error>, Date)] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 300) { self.ttl = ttl }

    func value(for key: String, _ fetch: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let task: Task<Data, Error> = lock.withLock {
            let now = Date()
            tasks = tasks.filter { now.timeIntervalSince($0.value.1) < ttl }
            if let hit = tasks[key] { return hit.0 }
            let created = Task { try await fetch() }
            tasks[key] = (created, now)
            return created
        }
        do {
            return try await task.value
        } catch {
            lock.withLock { tasks[key] = nil }
            throw error
        }
    }
}
