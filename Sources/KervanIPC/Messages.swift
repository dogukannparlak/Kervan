import EngineCore
import Foundation
import QueueKit

public let kervanVersion = "0.5.0"

/// Kervan'ın dosya yerleri. `KERVAN_HOME` ile değiştirilebilir (geliştirme/test).
public struct KervanPaths: Sendable {
    public static let launchAgentLabel = "com.dogukan.kervand"
    public static let nativeHostName = "com.dogukan.kervan"
    /// `extension/manifest.json` içindeki `key`'den türeyen sabit kimlik.
    public static let extensionID = "ifkabkcjdlkjbgijfnphgecoggfjdgek"
    /// Native Messaging manifest'lerinin gideceği tarayıcı klasörleri (Application Support altında).
    public static let browserDirectories = [
        "BraveSoftware/Brave-Browser", "Google/Chrome", "Chromium", "Microsoft Edge", "Vivaldi",
    ]

    public let home: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let custom = environment["KERVAN_HOME"] {
            home = URL(filePath: custom)
        } else {
            home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Kervan")
        }
    }

    public var database: URL { home.appending(path: "kervan.sqlite") }
    public var socket: URL { home.appending(path: "kervand.sock") }
    public var logs: URL { home.appending(path: "logs") }
    public var children: URL { home.appending(path: "children.txt") }
    public var bin: URL { home.appending(path: "bin") }
    public var settings: URL { home.appending(path: "settings.json") }
    public var updateState: URL { home.appending(path: "update-state.json") }
    public var launchAgentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(Self.launchAgentLabel).plist")
    }
}

/// İstemci → servis. Soket üzerinden satır başına bir JSON.
public struct Request: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        case ping, add, list, log, subscribe
        case pause, resume, cancel, retry, remove
        /// Bitmiş dosyayı Finder'da gösterir (yol istekten değil kuyruktan alınır).
        case reveal
        /// Linkin kalite seçenekleri (yt-dlp formatları).
        case formats
        /// Ayarları oku / yaz (`settings` alanı).
        case settings, setSettings
        /// yt-dlp'yi şimdi güncelle.
        case update
    }

    public var cmd: Command
    public var url: String?
    public var preset: String?
    public var dir: String?
    public var cookies: String?
    /// Çok videolu sayfada seçim: "all", "1,3", "2-5".
    public var items: String?
    public var ids: [Int64]?
    public var lines: Int?
    /// Tarayıcı eklentisinden gelen bağlam.
    public var referer: String?
    public var userAgent: String?
    /// Dosya adı ipucu (sayfa başlığı).
    public var title: String?
    /// Altyazı gömülsün mü; nil ise ayardaki değer.
    public var subtitles: Bool?
    public var settings: KervanSettings?
    /// Native host koyar: istek bir web sayfası bağlamından geldi (yerel ağ adresleri reddedilir).
    public var fromExtension: Bool?

    public init(cmd: Command, url: String? = nil, preset: String? = nil, dir: String? = nil, cookies: String? = nil,
                items: String? = nil, ids: [Int64]? = nil, lines: Int? = nil, referer: String? = nil,
                userAgent: String? = nil, title: String? = nil, subtitles: Bool? = nil, settings: KervanSettings? = nil) {
        self.cmd = cmd
        self.url = url
        self.preset = preset
        self.dir = dir
        self.cookies = cookies
        self.items = items
        self.ids = ids
        self.lines = lines
        self.referer = referer
        self.userAgent = userAgent
        self.title = title
        self.subtitles = subtitles
        self.settings = settings
    }
}

/// Servis → istemci. `subscribe` sonrası her değişiklik `event: true` ile gelir.
public struct Response: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var event: Bool?
    public var version: String?
    public var items: [DownloadItem]?
    public var removed: [Int64]?
    public var title: String?
    public var entries: [ProbeResult.Entry]?
    public var notes: [String]?
    public var log: [String]?
    public var qualities: QualityList?
    public var settings: KervanSettings?
    public var update: UpdateState?
    /// Site giriş istedi; istemci kullanıcıya "tarayıcı çerezleriyle dene" sunabilir (`cookies: "fallback"`).
    public var loginRequired: Bool?

    public init(ok: Bool, error: String? = nil, event: Bool? = nil, version: String? = nil, items: [DownloadItem]? = nil,
                removed: [Int64]? = nil, title: String? = nil, entries: [ProbeResult.Entry]? = nil,
                notes: [String]? = nil, log: [String]? = nil, qualities: QualityList? = nil, settings: KervanSettings? = nil,
                update: UpdateState? = nil) {
        self.ok = ok
        self.error = error
        self.event = event
        self.version = version
        self.items = items
        self.removed = removed
        self.title = title
        self.entries = entries
        self.notes = notes
        self.log = log
        self.qualities = qualities
        self.settings = settings
        self.update = update
    }

    public static func failure(_ message: String) -> Response { Response(ok: false, error: message) }
}

enum IPCCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
