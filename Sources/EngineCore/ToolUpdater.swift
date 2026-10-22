import CryptoKit
import Foundation

/// yt-dlp'yi günceller. YouTube çıkarıcısı sık bozulduğu için servis bunu günde bir kez yapar.
///
/// Homebrew formülü haftalarca geride kalabiliyor (2026-10-23: brew 2026.8.19, GitHub 2026.10.21).
/// Bu yüzden Kervan kendi kopyasını kullanır: resmi `yt-dlp_macos` `Application Support/Kervan/bin/yt-dlp`'ye
/// indirilir (SHA2-256SUMS ile doğrulanır), sonra `yt-dlp -U` ile kendini günceller. `ToolLocator` bu
/// klasöre Homebrew'dan önce bakar. İndirme başarısız olursa yedek `brew upgrade yt-dlp`.
public struct ToolUpdater: Sendable {
    public enum Method: Equatable, Sendable {
        case homebrew(brew: URL)
        case selfUpdate
    }

    public struct Result: Sendable, Equatable {
        public let before: String?
        public let after: String?
        public var changed: Bool { before != after && after != nil }
    }

    static let releaseBase = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/")!
    static let assetName = "yt-dlp_macos"

    let locator: ToolLocator
    let runner: any ProcessRunning
    let binDirectory: URL

    public init(locator: ToolLocator = ToolLocator(), runner: any ProcessRunning = SystemProcessRunner(), binDirectory: URL? = nil) {
        self.locator = locator
        self.runner = runner
        self.binDirectory = binDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Kervan/bin")
    }

    var standalone: URL { binDirectory.appending(path: "yt-dlp") }

    /// Bağlantıyı çözüp Homebrew'un Cellar'ında mı diye bakar.
    public static func method(for ytDlp: URL, brew: URL?) -> Method {
        let resolved = ytDlp.resolvingSymlinksInPath().path
        if let brew, resolved.contains("/Cellar/yt-dlp/") { return .homebrew(brew: brew) }
        return .selfUpdate
    }

    public func version() async -> String? {
        guard let ytDlp = locator.locate(.ytDlp),
              let process = try? runner.start(ytDlp, arguments: ["--version"], environment: locator.environment) else { return nil }
        return await process.collect().stdout.first?.trimmingCharacters(in: .whitespaces)
    }

    public func update() async throws -> Result {
        let before = await version()
        do {
            if FileManager.default.isExecutableFile(atPath: standalone.path) {
                try await run(standalone, ["-U"])
            } else {
                try await installStandalone()
            }
        } catch {
            // Kendi kopyamız kurulamadıysa en azından Homebrew'dakini güncelle.
            guard let ytDlp = locator.locate(.ytDlp), case .homebrew(let brew) = Self.method(for: ytDlp, brew: Self.brew) else { throw error }
            try await run(brew, ["upgrade", "yt-dlp"])
        }
        return Result(before: before, after: await version())
    }

    /// Resmi `yt-dlp_macos`'u indirir, SHA-256'yı yayımlanan listeyle karşılaştırır, `bin/yt-dlp` olarak kurar.
    func installStandalone() async throws {
        let (sums, _) = try await URLSession.shared.data(from: Self.releaseBase.appending(path: "SHA2-256SUMS"))
        guard let expected = Self.checksum(for: Self.assetName, in: String(decoding: sums, as: UTF8.self)) else {
            throw EngineError.toolFailed(.ytDlp, status: -1, message: "SHA2-256SUMS içinde \(Self.assetName) yok")
        }
        let (download, _) = try await URLSession.shared.download(from: Self.releaseBase.appending(path: Self.assetName))
        defer { try? FileManager.default.removeItem(at: download) }
        let digest = SHA256.hash(data: try Data(contentsOf: download, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw EngineError.toolFailed(.ytDlp, status: -1, message: "indirilen yt-dlp'nin SHA-256'sı tutmuyor")
        }
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let staged = binDirectory.appending(path: "yt-dlp.new")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: download, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        try await run(staged, ["--version"])  // çalışmayan dosyayı yerine koyma
        _ = try? FileManager.default.removeItem(at: standalone)
        try FileManager.default.moveItem(at: staged, to: standalone)
    }

    /// "<sha256>  yt-dlp_macos" satırından özet.
    static func checksum(for asset: String, in sums: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[1] == asset { return parts[0].lowercased() }
        }
        return nil
    }

    static var brew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map { URL(filePath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func run(_ executable: URL, _ arguments: [String]) async throws {
        var environment = locator.environment
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        let result = try await runner.start(executable, arguments: arguments, environment: environment).collect()
        guard result.status == 0 else {
            let tail = (result.stderr + result.stdout).suffix(3).joined(separator: " ")
            throw EngineError.toolFailed(.ytDlp, status: result.status, message: "güncelleme: \(tail)")
        }
    }

    /// "2026.08.19" → bugüne kaç gün.
    public static func ageInDays(version: String, now: Date = .now) -> Int? {
        let parts = version.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: now).day
    }
}
