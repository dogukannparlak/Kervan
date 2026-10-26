import CryptoKit
import Foundation

/// yt-dlp'yi günceller. YouTube çıkarıcısı sık bozulduğu için servis bunu günde bir kez yapar.
///
/// Homebrew formülü haftalarca geride kalabiliyor (2026-10-23: brew 2026.8.19, GitHub 2026.10.21).
/// Bu yüzden Kervan kendi kopyasını kullanır: resmi `yt-dlp_macos` `Application Support/Kervan/bin/yt-dlp`'ye
/// indirilir ve aynı yolla güncellenir: SHA2-256SUMS'un imzası yt-dlp'nin anahtarıyla (gpg varsa) ve dosyanın
/// SHA-256'sı doğrulanır; kurulu kopya listedekiyle aynıysa indirilmez. (`yt-dlp -U` imza denetlemediği için
/// kullanılmaz.) `ToolLocator` bu klasöre Homebrew'dan önce bakar. Başarısız olursa yedek `brew upgrade yt-dlp`.
public struct ToolUpdater: Sendable {
    public enum Method: Equatable, Sendable {
        case homebrew(brew: URL)
        case selfUpdate
    }

    public struct Result: Sendable, Equatable {
        public let before: String?
        public let after: String?
        /// SHA2-256SUMS'un gpg imzası doğrulandı mı (gpg yoksa ya da Homebrew yoluysa false).
        public var signatureChecked = false
        public var changed: Bool { before != after && after != nil }
    }

    static let releaseBase = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/")!
    static let assetName = "yt-dlp_macos"
    /// yt-dlp imza anahtarının parmak izi (`Resources/yt-dlp-public.key`, github.com/yt-dlp/yt-dlp/blob/master/public.key).
    static let signingKey = "AC0CBBE6848D6A873464AF4E57CF65933B5A7581"

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
        var signatureChecked = false
        do {
            signatureChecked = try await installStandalone()
        } catch {
            // Kendi kopyamız kurulamadıysa en azından Homebrew'dakini güncelle.
            guard let ytDlp = locator.locate(.ytDlp), case .homebrew(let brew) = Self.method(for: ytDlp, brew: Self.brew) else { throw error }
            try await run(brew, ["upgrade", "yt-dlp"])
        }
        var result = Result(before: before, after: await version())
        result.signatureChecked = signatureChecked
        return result
    }

    /// Resmi `yt-dlp_macos`'un son sürümünü `bin/yt-dlp` olarak kurar: listenin imzasını ve dosyanın SHA-256'sını
    /// doğrular; kurulu kopya zaten listedekiyse bir şey indirmez. İmza denetlendiyse true.
    @discardableResult
    func installStandalone() async throws -> Bool {
        let (sums, _) = try await URLSession.shared.data(from: Self.releaseBase.appending(path: "SHA2-256SUMS"))
        let signatureChecked = try await verifySignature(of: sums)
        guard let expected = Self.checksum(for: Self.assetName, in: String(decoding: sums, as: UTF8.self)) else {
            throw EngineError.toolFailed(.ytDlp, status: -1, message: "SHA2-256SUMS içinde \(Self.assetName) yok")
        }
        if FileManager.default.isExecutableFile(atPath: standalone.path), (try? Self.sha256(of: standalone)) == expected {
            return signatureChecked  // zaten son sürüm
        }
        let (download, _) = try await URLSession.shared.download(from: Self.releaseBase.appending(path: Self.assetName))
        defer { try? FileManager.default.removeItem(at: download) }
        let digest = try Self.sha256(of: download)
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
        return signatureChecked
    }

    static func sha256(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA2-256SUMS'un yt-dlp imzasını (SHA2-256SUMS.sig) gpg ile doğrular. gpg kurulu değilse false döner
    /// (SHA-256 yine denetlenir); gpg varsa imza geçersizse ya da başka anahtardansa hata verir.
    func verifySignature(of sums: Data) async throws -> Bool {
        guard let gpg = Self.gpg, let key = PresetStore.resources.url(forResource: "yt-dlp-public", withExtension: "key") else {
            return false
        }
        let (signature, _) = try await URLSession.shared.data(from: Self.releaseBase.appending(path: "SHA2-256SUMS.sig"))
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appending(path: "kervan-gpg-\(UUID().uuidString)")
        let home = work.appending(path: "gnupg")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: work) }
        let sumsFile = work.appending(path: "SHA2-256SUMS")
        let signatureFile = work.appending(path: "SHA2-256SUMS.sig")
        try sums.write(to: sumsFile)
        try signature.write(to: signatureFile)
        // Kullanıcının anahtarlığına dokunulmaz: yalnız yt-dlp anahtarını içeren geçici bir gpg klasörü.
        let base = ["--homedir", home.path, "--batch", "--no-tty"]
        let importer = try runner.start(gpg, arguments: base + ["--import", key.path], environment: locator.environment)
        _ = await importer.collect()
        let verifier = try runner.start(gpg, arguments: base + ["--status-fd", "1", "--verify", signatureFile.path, sumsFile.path],
                                        environment: locator.environment)
        let result = await verifier.collect()
        guard result.status == 0, Self.isSigned(by: Self.signingKey, status: result.stdout) else {
            throw EngineError.toolFailed(.ytDlp, status: result.status,
                                         message: "SHA2-256SUMS imzası yt-dlp anahtarıyla doğrulanamadı; güncelleme yapılmadı")
        }
        return true
    }

    /// gpg `--status-fd` çıktısında "[GNUPG:] VALIDSIG <imzalayan> … <birincil anahtar>" satırı.
    static func isSigned(by fingerprint: String, status: [String]) -> Bool {
        status.contains { line in
            let parts = line.split(separator: " ").map(String.init)
            return parts.count >= 3 && parts[0] == "[GNUPG:]" && parts[1] == "VALIDSIG"
                && (parts[2] == fingerprint || parts.last == fingerprint)
        }
    }

    static var gpg: URL? {
        ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg", "/usr/local/MacGPG2/bin/gpg"].map { URL(filePath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
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
