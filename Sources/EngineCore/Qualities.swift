import Foundation

/// Bir video için kullanıcıya sunulan kalite seçeneği. `preset` doğrudan kuyruğa verilir ("1080p", "audio").
public struct QualityOption: Codable, Sendable, Equatable {
    public let preset: String
    public let label: String
    public let height: Int?
    /// Yaklaşık bayt (görüntü + ses); bilinmiyorsa nil.
    public let size: Int64?

    public init(preset: String, label: String, height: Int?, size: Int64?) {
        self.preset = preset
        self.label = label
        self.height = height
        self.size = size
    }
}

public struct QualityList: Codable, Sendable, Equatable {
    public let title: String?
    /// Boşsa sayfa çok videolu (playlist) ya da format bilgisi yok; varsayılan preset kullanılır.
    public let options: [QualityOption]

    public init(title: String?, options: [QualityOption]) {
        self.title = title
        self.options = options
    }
}

/// `yt-dlp -J` çıktısının kalite için gereken kısmı.
struct FormatProbe: Decodable {
    struct Format: Decodable {
        let height: Int?
        let fps: Double?
        let vcodec: String?
        let acodec: String?
        let ext: String?
        let filesize: Double?
        let filesizeApprox: Double?
        let tbr: Double?
        let `protocol`: String?

        enum CodingKeys: String, CodingKey {
            case height, fps, vcodec, acodec, ext, filesize, tbr, `protocol`
            case filesizeApprox = "filesize_approx"
        }

        var hasVideo: Bool { vcodec != nil && vcodec != "none" && (height ?? 0) > 0 }
        var hasAudio: Bool { acodec != nil && acodec != "none" }
        /// yt-dlp aynı kalitede doğrudan https'i m3u8'e tercih eder.
        var isDirect: Bool { `protocol` == "https" || `protocol` == "http" }
    }

    let title: String?
    let type: String?
    let duration: Double?
    let formats: [Format]?

    enum CodingKeys: String, CodingKey {
        case title, duration, formats
        case type = "_type"
    }
}

enum QualityPlanner {
    /// Her yükseklik için preset'in seçeceğine yakın biçimi (≤1080'de H.264 öncelikli) bulur, en iyi sesi ekler.
    static func options(from probe: FormatProbe, limit: Int = 8) -> [QualityOption] {
        let formats = probe.formats ?? []
        func size(_ format: FormatProbe.Format) -> Int64? {
            if let bytes = format.filesize ?? format.filesizeApprox { return Int64(bytes) }
            if let tbr = format.tbr, let duration = probe.duration { return Int64(tbr * duration * 125) }  // kbit/s → bayt
            return nil
        }
        let audios = formats.filter { $0.hasAudio && !$0.hasVideo }
        let bestAudio = audios.filter { $0.ext == "m4a" }.max { ($0.tbr ?? 0) < ($1.tbr ?? 0) }
            ?? audios.max { ($0.tbr ?? 0) < ($1.tbr ?? 0) }
        let audioSize = bestAudio.flatMap(size)

        let videos = formats.filter(\.hasVideo)
        let heights = Set(videos.compactMap(\.height)).sorted(by: >)
        var options: [QualityOption] = heights.prefix(limit).compactMap { height in
            let sameHeight = videos.filter { $0.height == height }
            let direct = sameHeight.filter(\.isDirect)
            let atHeight = direct.isEmpty ? sameHeight : direct
            let preferred = height <= 1080 ? atHeight.filter { $0.vcodec?.hasPrefix("avc1") == true } : []
            guard let chosen = (preferred.isEmpty ? atHeight : preferred).max(by: { ($0.tbr ?? 0) < ($1.tbr ?? 0) }) else { return nil }
            let videoSize = size(chosen)
            let total: Int64? = chosen.hasAudio ? videoSize : videoSize.map { $0 + (audioSize ?? 0) }
            let fps = (chosen.fps ?? 0) > 30 ? String(Int((chosen.fps ?? 0).rounded())) : ""
            return QualityOption(preset: "\(height)p", label: "\(height)p\(fps)", height: height, size: total)
        }
        if bestAudio != nil {
            options.append(QualityOption(preset: "audio", label: "Yalnız ses", height: nil, size: audioSize))
            // mp3 preset'i en iyi VBR (~245 kbit/s) üretir.
            options.append(QualityOption(preset: "mp3", label: "MP3", height: nil, size: probe.duration.map { Int64($0 * 245 * 125) }))
        }
        return options
    }
}

extension YtDlpAdapter {
    /// Videonun indirilebilir kaliteleri (playlist ise boş liste).
    public func qualities(_ url: URL, cookiesFromBrowser: String? = nil, context: RequestContext = RequestContext()) async throws -> QualityList {
        let args = ["-J", "--no-playlist", "--no-warnings"] + Self.cookieArguments(cookiesFromBrowser)
            + Self.headerArguments(context) + ["--", url.absoluteString]
        let process = try runner.start(executable, arguments: args, environment: environment)
        let result = await process.collect()
        guard result.status == 0 else {
            throw EngineError.toolFailed(.ytDlp, status: result.status, message: Self.errorMessage(result.stderr))
        }
        do {
            let probe = try JSONDecoder().decode(FormatProbe.self, from: Data(result.stdout.joined().utf8))
            return QualityList(title: probe.title, options: probe.type == "playlist" ? [] : QualityPlanner.options(from: probe))
        } catch {
            throw EngineError.invalidProbeOutput(String(describing: error))
        }
    }
}
