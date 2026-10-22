import Foundation

public enum DownloadKind: Sendable, Equatable {
    /// Düz dosya → aria2.
    case http
    case video(ProbeResult)
    case playlist(ProbeResult)
}

public struct HeadInfo: Sendable, Equatable {
    public let statusCode: Int
    public let contentType: String?
    public let contentDisposition: String?

    public init(statusCode: Int, contentType: String?, contentDisposition: String?) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.contentDisposition = contentDisposition
    }
}

public protocol HeadFetching: Sendable {
    func head(_ url: URL) async throws -> HeadInfo
}

public struct URLSessionHeadFetcher: HeadFetching {
    public init() {}

    public func head(_ url: URL) async throws -> HeadInfo {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return HeadInfo(statusCode: http?.statusCode ?? 0,
                        contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                        contentDisposition: http?.value(forHTTPHeaderField: "Content-Disposition"))
    }
}

/// Sıra: HEAD düz dosya diyorsa http; değilse yt-dlp probe (`direct` → http, playlist, video).
/// `yt-dlp -J` düz linklerde de başarılı döndüğü için probe hatası "http" anlamına gelmez.
public struct URLClassifier: Sendable {
    let head: any HeadFetching
    let probe: @Sendable (URL) async throws -> ProbeResult

    public init(head: any HeadFetching = URLSessionHeadFetcher(), probe: @escaping @Sendable (URL) async throws -> ProbeResult) {
        self.head = head
        self.probe = probe
    }

    public func classify(_ url: URL) async throws -> DownloadKind {
        if let info = try? await head.head(url), Self.isDirectFile(info) { return .http }
        return Self.kind(for: try await probe(url))
    }

    /// HTML, JSON ve akış manifestleri (m3u8, mpd) yt-dlp'ye gider; gerisi düz dosyadır.
    static func isDirectFile(_ info: HeadInfo) -> Bool {
        guard (200..<300).contains(info.statusCode) else { return false }
        if info.contentDisposition?.lowercased().contains("attachment") == true { return true }
        guard let raw = info.contentType else { return false }
        let type = raw.split(separator: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        let handledByYtDlp = [
            "application/xhtml+xml", "application/json",
            "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl",
            "application/dash+xml",
        ]
        return !type.hasPrefix("text/") && !handledByYtDlp.contains(type)
    }

    static func kind(for result: ProbeResult) -> DownloadKind {
        if result.direct == true { return .http }
        return result.isPlaylist ? .playlist(result) : .video(result)
    }
}
