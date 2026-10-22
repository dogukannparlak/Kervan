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
