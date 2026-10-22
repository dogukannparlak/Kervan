import Foundation

/// `yt-dlp -J --flat-playlist` çıktısının ihtiyacımız olan kısmı.
public struct ProbeResult: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public let id: String?
        public let title: String?
        public let url: String?
    }

    public let id: String?
    public let title: String?
    public let extractor: String?
    public let type: String?
    public let direct: Bool?
    public let duration: Double?
    public let webpageURL: String?
    public let entries: [Entry]?

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

    public init(executable: URL, ffmpeg: URL?, runner: any ProcessRunning = SystemProcessRunner(), environment: [String: String]) {
        self.executable = executable
        self.ffmpeg = ffmpeg
        self.runner = runner
        self.environment = environment
    }

    public func probe(_ url: URL) async throws -> ProbeResult {
        let process = try runner.start(executable, arguments: ["-J", "--flat-playlist", "--no-warnings", url.absoluteString],
                                       environment: environment)
        let result = await process.collect()
        guard result.status == 0 else {
            throw EngineError.toolFailed(.ytDlp, status: result.status, message: Self.errorMessage(result.stderr))
        }
        do {
            return try JSONDecoder().decode(ProbeResult.self, from: Data(result.stdout.joined().utf8))
        } catch {
            throw EngineError.invalidProbeOutput(String(describing: error))
        }
    }

    public func download(_ url: URL, preset: Preset, to directory: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if preset.requiresFFmpeg && ffmpeg == nil { throw EngineError.ffmpegMissing }
                    let process = try runner.start(executable, arguments: downloadArguments(url, preset: preset, to: directory),
                                                   environment: environment)
                    var tracker = YtDlpProgressTracker()
                    var stderr: [String] = []
                    await withTaskCancellationHandler {
                        for await line in process.output {
                            if line.source == .stderr { stderr.append(line.text) }
                            continuation.yield(tracker.consume(line) ?? .log(line))
                        }
                    } onCancel: {
                        Task { await process.terminate() }
                    }
                    let status = await process.waitUntilExit()
                    try Task.checkCancellation()
                    guard status == 0 else {
                        throw EngineError.toolFailed(.ytDlp, status: status, message: Self.errorMessage(stderr))
                    }
                    guard let file = tracker.outputFile else { throw EngineError.noOutputFile }
                    continuation.yield(.completed(file))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func downloadArguments(_ url: URL, preset: Preset, to directory: URL) -> [String] {
        var args = [
            "--newline", "--progress", "--color", "never", "--no-playlist",
            "--retries", "10", "--fragment-retries", "10",
            "-f", preset.format,
            "-P", directory.path,
            "-o", "%(title).200B [%(id)s].%(ext)s",
            "--progress-template", "download:\(YtDlpProgressTracker.downloadPrefix)|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:\(YtDlpProgressTracker.postprocessPrefix)|%(progress.status)s|%(progress.postprocessor)s",
            "--print", "video:\(YtDlpProgressTracker.infoPrefix)|%(format_id)s|%(filesize,filesize_approx)s",
            "--print", "after_move:\(YtDlpProgressTracker.filePrefix)|%(filepath)s",
        ]
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        if let container = preset.container { args += ["--merge-output-format", container] }
        return args + preset.extraArgs + ["--", url.absoluteString]
    }

    static func errorMessage(_ stderr: [String]) -> String {
        stderr.last { $0.hasPrefix("ERROR:") } ?? stderr.last ?? "ayrıntı yok"
    }
}

/// yt-dlp'nin `KERVAN_*` satırlarını ilerleme olaylarına çevirir.
/// Video + ses ayrı parçalar halinde iner; toplam, `KERVAN_INFO`'daki yaklaşık boyuttan gelir.
struct YtDlpProgressTracker {
    static let infoPrefix = "KERVAN_INFO"
    static let downloadPrefix = "KERVAN_DL"
    static let postprocessPrefix = "KERVAN_PP"
    static let filePrefix = "KERVAN_FILE"

    private(set) var outputFile: URL?
    private var parts = 1
    private var finishedParts = 0
    private var finishedBytes: Int64 = 0
    private var approximateTotal: Int64?

    mutating func consume(_ line: OutputLine) -> DownloadEvent? {
        let fields = line.text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch fields.first {
        case Self.infoPrefix where fields.count >= 3:
            parts = fields[1].split(separator: "+").count
            approximateTotal = Int64(fields[2])
            return .progress(ProgressEvent(phase: .download, bytesTotalEstimate: approximateTotal, message: partMessage))

        case Self.downloadPrefix where fields.count >= 7:
            let downloaded = Int64(fields[2]) ?? 0
            let partTotal = Int64(fields[3]) ?? Int64(fields[4])
            var event = ProgressEvent(phase: .download, bytesDone: finishedBytes + downloaded,
                                      speed: Double(fields[5]), eta: Int(fields[6]), message: partMessage)
            if parts == 1, let total = Int64(fields[3]) {
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
            let path = line.text.dropFirst(Self.filePrefix.count + 1)
            outputFile = URL(filePath: String(path))
            return .log(line)

        default:
            return nil
        }
    }

    private var partMessage: String? {
        parts > 1 ? "parça \(min(finishedParts + 1, parts))/\(parts)" : nil
    }
}
