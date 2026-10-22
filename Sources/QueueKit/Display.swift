import Foundation

/// CLI, uygulama ve eklentinin ortak gösterim biçimleri.
public enum Format {
    /// 1000 tabanlı: "267.9 MB".
    public static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value)
        var unit = 0
        while size >= 1000, unit < units.count - 1 {
            size /= 1000
            unit += 1
        }
        return unit == 0 ? "\(value) B" : String(format: "%.1f %@", size, units[unit])
    }

    /// "2:05" ya da "1:02:05".
    public static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension ItemState {
    public var label: String {
        switch self {
        case .queued: "sırada"
        case .downloading: "iniyor"
        case .postprocessing: "işleniyor"
        case .paused: "duraklatıldı"
        case .failed: "hata"
        case .canceled: "iptal"
        case .done: "bitti"
        }
    }
}

/// Pano izleme: kopyalanan link indirilecek bir şey gibi mi görünüyor?
/// Her http linkinde öneri çıkması rahatsız eder; video siteleri ve dosya uzantıları seçilir.
public enum ClipboardHeuristics {
    static let videoHosts: [String: [String]] = [
        "youtube.com": ["/watch", "/shorts/", "/playlist", "/live/"],
        "youtu.be": [""],
        "instagram.com": ["/reel/", "/reels/", "/p/", "/tv/"],
        "tiktok.com": ["/video/", "/@"],
        "x.com": ["/status/"],
        "twitter.com": ["/status/"],
        "vimeo.com": [""],
        "dailymotion.com": ["/video/"],
        "twitch.tv": ["/videos/", "/clip/"],
        "reddit.com": ["/comments/"],
        "facebook.com": ["/watch", "/videos/", "/reel/"],
        "soundcloud.com": [""],
        "bilibili.com": ["/video/"],
        "streamable.com": [""],
        "kick.com": ["/videos/", "/clips/"],
    ]

    public static func looksDownloadable(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let rawHost = url.host()?.lowercased()
        else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost.replacingOccurrences(of: "m.", with: "", options: .anchored)
        if let paths = videoHosts.first(where: { host == $0.key || host.hasSuffix("." + $0.key) })?.value {
            let path = url.path()
            return path.count > 1 && paths.contains { $0.isEmpty || path.hasPrefix($0) || path.contains($0) } ? url : nil
        }
        return DownloadCategory.of(kind: .http, presetId: "", url: url) == .other ? nil : url
    }
}
