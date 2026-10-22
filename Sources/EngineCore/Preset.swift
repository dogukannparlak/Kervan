import Foundation

/// Kalite ön ayarı. Değerler `Resources/presets/*.json` dosyalarından gelir.
public struct Preset: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    /// yt-dlp `-f` ifadesi.
    public let format: String
    /// `--merge-output-format`; nil ise birleştirme yok (ör. yalnız ses).
    public let container: String?
    public let requiresFFmpeg: Bool
    public let extraArgs: [String]

    public init(id: String, label: String, format: String, container: String?, requiresFFmpeg: Bool, extraArgs: [String] = []) {
        self.id = id
        self.label = label
        self.format = format
        self.container = container
        self.requiresFFmpeg = requiresFFmpeg
        self.extraArgs = extraArgs
    }
}

public enum PresetStore {
    public static func builtIn() throws -> [Preset] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "presets") ?? []
        let decoder = JSONDecoder()
        return try urls
            .map { try decoder.decode(Preset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id < $1.id }
    }

    public static func named(_ id: String) throws -> Preset? {
        try builtIn().first { $0.id == id }
    }
}
