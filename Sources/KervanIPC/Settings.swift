import Foundation

/// Kullanıcı ayarları: `~/Library/Application Support/Kervan/settings.json`. Servis okur ve uygular;
/// CLI (`kervan config`) ve uygulama `settings` / `setSettings` komutlarıyla değiştirir.
/// Dosyada olmayan alanlar varsayılan değeri alır (eski dosyalar bozulmaz).
public struct KervanSettings: Codable, Sendable, Equatable {
    public var downloadDirectory: String
    /// IDM gibi tür klasörleri: Video, Müzik, Belgeler, Arşivler, Programlar, Diğer.
    public var categorize: Bool
    public var defaultPreset: String
    public var subtitles: Bool
    public var subtitleLanguages: String
    public var autoUpdate: Bool
    public var maxParallel: Int
    public var maxPerHost: Int
    /// Uygulama: panoya video/dosya linki kopyalanınca "Kervan'a ekle?" önerisi.
    public var clipboardWatch: Bool

    public init() {
        downloadDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads/Kervan").path
        categorize = true
        defaultPreset = "1080p"
        subtitles = false
        subtitleLanguages = "tr,en"
        autoUpdate = true
        maxParallel = 3
        maxPerHost = 2
        clipboardWatch = true
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadDirectory = try container.decodeIfPresent(String.self, forKey: .downloadDirectory) ?? downloadDirectory
        categorize = try container.decodeIfPresent(Bool.self, forKey: .categorize) ?? categorize
        defaultPreset = try container.decodeIfPresent(String.self, forKey: .defaultPreset) ?? defaultPreset
        subtitles = try container.decodeIfPresent(Bool.self, forKey: .subtitles) ?? subtitles
        subtitleLanguages = try container.decodeIfPresent(String.self, forKey: .subtitleLanguages) ?? subtitleLanguages
        autoUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? autoUpdate
        maxParallel = try container.decodeIfPresent(Int.self, forKey: .maxParallel) ?? maxParallel
        maxPerHost = try container.decodeIfPresent(Int.self, forKey: .maxPerHost) ?? maxPerHost
        clipboardWatch = try container.decodeIfPresent(Bool.self, forKey: .clipboardWatch) ?? clipboardWatch
    }

    /// Sınırları makul aralığa çeker.
    public var normalized: KervanSettings {
        var copy = self
        copy.maxParallel = min(max(maxParallel, 1), 10)
        copy.maxPerHost = min(max(maxPerHost, 1), copy.maxParallel)
        copy.downloadDirectory = NSString(string: downloadDirectory).expandingTildeInPath
        return copy
    }

    public static func load(paths: KervanPaths = KervanPaths()) -> KervanSettings {
        guard let data = try? Data(contentsOf: paths.settings),
              let settings = try? JSONDecoder().decode(KervanSettings.self, from: data) else { return KervanSettings() }
        return settings.normalized
    }

    public func save(paths: KervanPaths = KervanPaths()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try encoder.encode(normalized).write(to: paths.settings, options: .atomic)
    }
}

/// Otomatik güncellemenin son durumu (`update-state.json`).
public struct UpdateState: Codable, Sendable {
    public var lastCheck: Date?
    public var lastResult: String?

    public init(lastCheck: Date? = nil, lastResult: String? = nil) {
        self.lastCheck = lastCheck
        self.lastResult = lastResult
    }

    public static func load(paths: KervanPaths = KervanPaths()) -> UpdateState {
        guard let data = try? Data(contentsOf: paths.updateState) else { return UpdateState() }
        return (try? IPCCoding.decoder().decode(UpdateState.self, from: data)) ?? UpdateState()
    }

    public func save(paths: KervanPaths = KervanPaths()) {
        try? IPCCoding.encoder().encode(self).write(to: paths.updateState, options: .atomic)
    }
}

/// Servisin canlı ayarları: değişiklik diske yazılır ve `onChange` ile uygulanır (ör. eşzamanlılık).
public final class SettingsStore: @unchecked Sendable {
    public let paths: KervanPaths
    private let lock = NSLock()
    private var current: KervanSettings
    private let onChange: @Sendable (KervanSettings) async -> Void
    private let persist: Bool

    /// Testler için: diske yazmayan, bellek içi.
    public init() {
        paths = KervanPaths()
        current = KervanSettings()
        onChange = { _ in }
        persist = false
    }

    public init(paths: KervanPaths, onChange: @escaping @Sendable (KervanSettings) async -> Void) {
        self.paths = paths
        current = KervanSettings.load(paths: paths)
        self.onChange = onChange
        persist = true
    }

    public var value: KervanSettings { lock.withLock { current } }

    public func update(_ settings: KervanSettings) async throws {
        let normalized = settings.normalized
        if persist { try normalized.save(paths: paths) }
        lock.withLock { current = normalized }
        await onChange(normalized)
    }
}
