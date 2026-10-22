import Foundation

/// Bütün adapter'ların ortak ilerleme dili. Kuyruk (M2) buna öğe kimliğini ekler.
public struct ProgressEvent: Sendable, Equatable {
    public enum Phase: String, Sendable { case probe, download, postprocess }

    public var phase: Phase
    public var bytesDone: Int64
    public var bytesTotal: Int64?
    public var bytesTotalEstimate: Int64?
    /// bayt/sn
    public var speed: Double?
    /// saniye
    public var eta: Int?
    public var message: String?

    public init(phase: Phase, bytesDone: Int64 = 0, bytesTotal: Int64? = nil, bytesTotalEstimate: Int64? = nil,
                speed: Double? = nil, eta: Int? = nil, message: String? = nil) {
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.bytesTotalEstimate = bytesTotalEstimate
        self.speed = speed
        self.eta = eta
        self.message = message
    }

    public var fraction: Double? {
        guard let total = bytesTotal ?? bytesTotalEstimate, total > 0 else { return nil }
        return min(1, Double(bytesDone) / Double(total))
    }
}

/// Tarayıcıdan gelen bağlam: Referer/User-Agent (hotlink korumalı CDN'ler) ve dosya adı ipucu (sayfa başlığı).
public struct RequestContext: Sendable, Codable, Equatable {
    public var referer: String?
    public var userAgent: String?
    /// Uzantısız dosya adı; nil ise aracın kendi adı (yt-dlp başlığı, URL'deki ad).
    public var filename: String?

    public init(referer: String? = nil, userAgent: String? = nil, filename: String? = nil) {
        self.referer = referer
        self.userAgent = userAgent
        self.filename = filename.map(Self.sanitize).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Dosya sistemi ve yt-dlp şablonu için güvenli ad: `/ : \` ve kontrol karakterleri atılır, en fazla 150 karakter.
    public static func sanitize(_ name: String) -> String {
        let cleaned = name.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || "/\\:*?\"<>|".unicodeScalars.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(150)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// Tarayıcı kimliği verilmediyse kullanılan değer. Bazı sunucular aracın kendi kimliğini
    /// (ör. `aria2/1.37.0`) 403 ile reddediyor (w3schools, 2026-10-23).
    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    var httpHeaders: [String: String] {
        var headers: [String: String] = [:]
        if let referer { headers["Referer"] = referer }
        if let userAgent { headers["User-Agent"] = userAgent }
        return headers
    }
}

public enum DownloadEvent: Sendable, Equatable {
    case progress(ProgressEvent)
    /// Ayrıştırılmayan araç çıktısı (log halkası için).
    case log(OutputLine)
    case completed(URL)
}

public enum EngineError: Error, Equatable, CustomStringConvertible {
    case toolMissing(Tool)
    case ffmpegMissing
    case toolFailed(Tool, status: Int32, message: String)
    case noOutputFile
    case invalidProbeOutput(String)
    case aria2NotReady
    case loginRequired(browser: String, detail: String)

    public var description: String {
        switch self {
        case .toolMissing(let tool): "\(tool.rawValue) bulunamadı. `scripts/install-deps.sh` çalıştır."
        case .ffmpegMissing: "Bu preset ffmpeg istiyor ama ffmpeg bulunamadı (`brew install ffmpeg`)."
        case .toolFailed(let tool, let status, let message): "\(tool.rawValue) hata verdi (çıkış \(status)): \(message)"
        case .noOutputFile: "İndirme bitti ama çıktı dosyası bildirilmedi."
        case .invalidProbeOutput(let detail): "yt-dlp metadata çıktısı okunamadı: \(detail)"
        case .aria2NotReady: "aria2 RPC sunucusu başlamadı."
        case .loginRequired(let browser, let detail):
            "\(browser) çerezleri yetmedi: \(browser)'da bu siteye giriş yapıp tekrar dene "
                + "(başka tarayıcı: --cookies firefox).\n\(detail)"
        }
    }
}
