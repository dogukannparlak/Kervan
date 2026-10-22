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
    /// Kaynak paketi: önce .app içindeki Contents/Resources (servis paketi), sonra çalıştırılabilir dosyanın
    /// yanı; ikisi de yoksa SwiftPM'in `Bundle.module`'ü (derleme klasörü).
    static let resources: Bundle = {
        let name = "Kervan_EngineCore.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appending(path: name),
            Bundle.main.executableURL?.deletingLastPathComponent().appending(path: name),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.module
    }()

    public static func builtIn() throws -> [Preset] {
        let urls = resources.urls(forResourcesWithExtension: "json", subdirectory: "presets") ?? []
        let decoder = JSONDecoder()
        return try urls
            .map { try decoder.decode(Preset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id < $1.id }
    }

    /// Hazır preset yoksa "480p", "1440p" gibi yükseklik adlarından üretir (kalite listesi bunları kullanır).
    public static func named(_ id: String) throws -> Preset? {
        if let preset = try builtIn().first(where: { $0.id == id }) { return preset }
        guard id.hasSuffix("p"), let height = Int(id.dropLast()), (100...4320).contains(height) else { return nil }
        return height <= 1080
            ? Preset(id: id, label: "En fazla \(id), H.264 + AAC öncelikli (mp4)",
                     format: "bv*[height<=\(height)][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=\(height)]+ba/b[height<=\(height)]/b",
                     container: "mp4", requiresFFmpeg: true)
            : Preset(id: id, label: "En fazla \(id) (mkv)", format: "bv*[height<=\(height)]+ba/b[height<=\(height)]/b",
                     container: "mkv", requiresFFmpeg: true)
    }
}
