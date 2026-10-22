import Foundation

/// IDM tarzı tür klasörü: ayarda `categorize` açıksa öğe `<indirme klasörü>/<kategori>/` altına iner.
public enum DownloadCategory: String, CaseIterable, Sendable {
    case video = "Video"
    case music = "Müzik"
    case documents = "Belgeler"
    case archives = "Arşivler"
    case programs = "Programlar"
    case other = "Diğer"

    static let extensions: [DownloadCategory: Set<String>] = [
        .video: ["mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "wmv", "ts", "m3u8", "mpd"],
        .music: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "wma"],
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "epub", "txt", "md", "csv", "rtf"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"],
        .programs: ["dmg", "pkg", "app", "exe", "msi", "iso", "apk", "deb", "rpm", "appimage"],
    ]

    /// yt-dlp öğeleri preset'e göre Video/Müzik; düz dosyalar uzantıya göre.
    public static func of(kind: ItemKind, presetId: String, url: URL) -> DownloadCategory {
        if kind != .http { return presetId == "audio" || presetId == "mp3" ? .music : .video }
        let ext = url.pathExtension.lowercased()
        return extensions.first { $0.value.contains(ext) }?.key ?? .other
    }
}
