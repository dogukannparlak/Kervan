import Foundation

public enum Tool: String, CaseIterable, Sendable {
    case ytDlp = "yt-dlp"
    case ffmpeg
    case aria2c
    case deno

    /// Örn. `KERVAN_YT_DLP=/yol/yt-dlp` aramayı geçersiz kılar.
    public var overrideVariable: String {
        "KERVAN_" + rawValue.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    public var versionArguments: [String] { self == .ffmpeg ? ["-version"] : ["--version"] }
}

/// Dış araçları bulur ve onlara verilecek ortamı hazırlar.
/// Sıra: `KERVAN_<ARAÇ>` → Application Support/Kervan/bin/yt-dlp-dir → bin → Homebrew → PATH.
public struct ToolLocator: Sendable {
    public let searchDirectories: [URL]
    private let baseEnvironment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        baseEnvironment = environment
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var paths = [
            appSupport.appending(path: "Kervan/bin/yt-dlp-dir").path,
            appSupport.appending(path: "Kervan/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        paths += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        searchDirectories = paths.filter { !$0.isEmpty && seen.insert($0).inserted }.map { URL(filePath: $0) }
    }

    public func locate(_ tool: Tool) -> URL? {
        if let override = baseEnvironment[tool.overrideVariable] {
            return FileManager.default.isExecutableFile(atPath: override) ? URL(filePath: override) : nil
        }
        return searchDirectories
            .map { $0.appending(path: tool.rawValue) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Alt süreçlerin ortamı: PATH arama dizinlerini içerir (yt-dlp deno'yu böyle bulur).
    public var environment: [String: String] {
        var env = baseEnvironment
        env["PATH"] = searchDirectories.map(\.path).joined(separator: ":")
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }
}
