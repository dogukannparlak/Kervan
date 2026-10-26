import EngineCore
import Foundation
import GRDB

public enum ItemKind: String, Codable, Sendable, DatabaseValueConvertible {
    case video
    case http
    /// Playlist / çok videolu sayfa başlığı; kendisi inmez, çocukları iner.
    case group
}

public enum ItemState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// `waiting`: kullanıcı "beklemede ekle" dedi; ayarları seçilip başlatılana kadar inmez (duraklatılmış değil).
    case queued, downloading, postprocessing, paused, waiting, failed, canceled, done

    /// İzinli geçişler. `done` terminaldir; `canceled` yalnız elle yeniden denemeyle döner.
    public func canTransition(to next: ItemState) -> Bool {
        switch (self, next) {
        case (.queued, .downloading), (.queued, .paused), (.queued, .canceled): true
        case (.downloading, .postprocessing), (.downloading, .done), (.downloading, .failed),
             (.downloading, .queued), (.downloading, .paused), (.downloading, .canceled): true
        case (.postprocessing, .downloading), (.postprocessing, .done), (.postprocessing, .failed),
             (.postprocessing, .queued), (.postprocessing, .paused), (.postprocessing, .canceled): true
        case (.paused, .queued), (.paused, .canceled): true
        case (.waiting, .queued), (.waiting, .canceled): true
        case (.failed, .queued), (.failed, .canceled): true
        case (.canceled, .queued): true
        default: false
        }
    }

    public var isActive: Bool { self == .downloading || self == .postprocessing }
    public var isFinished: Bool { self == .done || self == .canceled || self == .failed }
}

public struct DownloadItem: Codable, Sendable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "item"

    public var id: Int64?
    public var url: String
    public var kind: ItemKind
    public var parentId: Int64?
    /// URL'si olmayan playlist girişleri için yt-dlp `--playlist-items` sırası.
    public var playlistIndex: Int?
    public var title: String?
    public var host: String
    public var presetId: String
    public var cookiesBrowser: String?
    /// Tarayıcı eklentisinden: sayfa adresi, tarayıcı kimliği, sayfa başlığından dosya adı.
    public var referer: String?
    public var userAgent: String?
    public var filename: String?
    /// Gömülecek altyazı dilleri ("tr,en"); nil ise altyazı yok.
    public var subtitles: String?
    public var destination: String
    public var state: ItemState
    public var attempt: Int
    public var maxAttempts: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
    public var bytesDone: Int64
    public var bytesTotal: Int64?
    public var bytesTotalEstimate: Int64?
    public var speed: Double?
    public var eta: Int?
    public var message: String?
    public var outputPath: String?
    /// Aracın yazdığı (henüz bitmemiş) dosya; iptalde yarım dosyalar bununla bulunur.
    public var partialPath: String?
    /// "<çıkarıcı>:<video kimliği>" (yt-dlp); aynı videonun tekrar eklenmesini fark etmek için.
    public var mediaId: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?

    public init(url: String, kind: ItemKind, host: String, presetId: String, destination: String,
                cookiesBrowser: String? = nil, title: String? = nil, maxAttempts: Int = 3, now: Date = Date()) {
        self.url = url
        self.kind = kind
        self.host = host
        self.presetId = presetId
        self.destination = destination
        self.cookiesBrowser = cookiesBrowser
        self.title = title
        self.maxAttempts = maxAttempts
        state = .queued
        attempt = 0
        bytesDone = 0
        createdAt = now
        updatedAt = now
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var context: RequestContext {
        RequestContext(referer: referer, userAgent: userAgent, filename: filename)
    }

    public var fraction: Double? {
        guard let total = bytesTotal ?? bytesTotalEstimate, total > 0 else { return state == .done ? 1 : nil }
        return min(1, Double(bytesDone) / Double(total))
    }

    /// Bu durum değişikliği bildirilmeli mi? (başlık, gövde) Yalnız bitiş ve kalıcı hata; playlist çocukları
    /// tek tek değil grup bitince; `previous` nil ise (servis yeni açıldı) bildirilmez.
    public func notification(previous: ItemState?) -> (title: String, body: String)? {
        guard let previous, previous != state, parentId == nil else { return nil }
        let name = title ?? url
        switch state {
        case .done where kind == .group: return ("Kervan: liste bitti", "\(name) · \(message ?? "")")
        case .done: return ("Kervan: indirme bitti", name)
        case .failed: return ("Kervan: indirme başarısız", "\(name) — \(lastError ?? "")")
        default: return nil
        }
    }

    /// "www." öneki atılmış host; site başına eşzamanlılık bununla sayılır.
    public static func host(of url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
