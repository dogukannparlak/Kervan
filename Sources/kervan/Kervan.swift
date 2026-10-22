import ArgumentParser
import EngineCore
import Foundation

@main
struct KervanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kervan",
        abstract: "yt-dlp + aria2 tabanlı indirme yöneticisi.",
        version: "0.1.0",
        subcommands: [Get.self, Probe.self, Doctor.self, Presets.self]
    )
}

struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tek bir linki ön planda indirir.")

    @Argument(help: "Video sayfası ya da doğrudan dosya linki.")
    var url: String

    @Option(name: .shortAndLong, help: "Kalite ön ayarı (`kervan presets`).")
    var preset = "1080p"

    @Option(name: .shortAndLong, help: "Hedef klasör.")
    var dir = "~/Downloads/Kervan"

    @Option(help: "Tarayıcı çerezleri: auto (giriş isterse Brave), none ya da brave/chrome/firefox/safari/edge.")
    var cookies = "auto"

    @Flag(help: "Sayfadaki/playlist'teki bütün videoları indir.")
    var all = false

    @Option(help: "Yalnız seçilen videolar, ör. 1,3 ya da 2-5.")
    var items: String?

    @Flag(name: .shortAndLong, help: "Araç çıktısını da göster.")
    var verbose = false

    func run() async throws {
        let url = try parseURL(url)
        guard let preset = try PresetStore.named(preset) else {
            throw ValidationError("Bilinmeyen preset: \(self.preset). Liste: kervan presets")
        }
        let directory = URL(filePath: NSString(string: dir).expandingTildeInPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tools = try Toolbox()
        let (kind, browser) = try await tools.classify(url, cookies: CookieOption(cookies))
        let events: AsyncThrowingStream<DownloadEvent, Error>
        switch kind {
        case .http:
            print("→ düz dosya (aria2)")
            events = try tools.aria2().download(url, to: directory)
        case .video(let info):
            print("→ \(info.title ?? url.absoluteString)  [\(info.extractor ?? "?") · \(preset.id)]")
            events = tools.ytDlp.download(url, preset: preset, to: directory, cookiesFromBrowser: browser)
        case .playlist(let info):
            let entries = info.entries ?? []
            guard all || items != nil else {
                print("Bu sayfada \(entries.count) video var:")
                printEntries(entries)
                print("İndirmek için: --all ya da --items 1,3")
                return
            }
            let selection = items ?? "1-\(entries.count)"
            print("→ \(info.title ?? url.absoluteString)  [\(info.extractor ?? "?") · \(preset.id) · video \(selection)]")
            events = tools.ytDlp.download(url, preset: preset, to: directory, cookiesFromBrowser: browser, playlistItems: selection)
        }

        let renderer = ProgressRenderer()
        for try await event in events {
            switch event {
            case .progress(let progress): renderer.update(progress)
            case .log(let line): if verbose { renderer.log(line.text) }
            case .completed(let file):
                renderer.finish()
                print("✓ \(file.path)")
            }
        }
    }
}

struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Linkin türünü ve metadata'sını gösterir, indirmez.")

    @Argument var url: String

    @Option(help: "Tarayıcı çerezleri: auto, none ya da tarayıcı adı.")
    var cookies = "auto"

    func run() async throws {
        let url = try parseURL(url)
        let tools = try Toolbox()
        let (kind, browser) = try await tools.classify(url, cookies: CookieOption(cookies))
        switch kind {
        case .http:
            print("tür: http (aria2)")
        case .video(let info):
            print("tür: video\nbaşlık: \(info.title ?? "-")\nsite: \(info.extractor ?? "-")")
            if let duration = info.duration { print("süre: \(Format.duration(Int(duration)))") }
        case .playlist(let info):
            print("tür: çok videolu sayfa / playlist\nbaşlık: \(info.title ?? "-")\nsite: \(info.extractor ?? "-")")
            printEntries(info.entries ?? [])
        }
        if let browser { print("çerez: \(browser)") }
    }
}

func printEntries(_ entries: [ProbeResult.Entry], limit: Int = 50) {
    for (index, entry) in entries.prefix(limit).enumerated() {
        print("  \(index + 1). \(entry.title ?? entry.url ?? entry.id ?? "?")")
    }
    if entries.count > limit { print("  … +\(entries.count - limit)") }
}

/// `--cookies` değeri: auto → önce çerezsiz, giriş hatasında yedek tarayıcı.
struct CookieOption {
    let explicit: String?
    let fallback: String?

    init(_ value: String) {
        switch value.lowercased() {
        case "auto":
            explicit = nil
            fallback = ProcessInfo.processInfo.environment["KERVAN_COOKIES_BROWSER"] ?? "brave"
        case "none":
            explicit = nil
            fallback = nil
        default:
            explicit = value.lowercased()
            fallback = nil
        }
    }
}

/// Probe sırasında hangi tarayıcının çerezinin kullanıldığını indirmeye taşır.
private final class CookieChoice: @unchecked Sendable {
    private let lock = NSLock()
    private var browser: String?

    init(_ browser: String?) { self.browser = browser }

    var value: String? {
        get { lock.withLock { browser } }
        set { lock.withLock { browser = newValue } }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Dış araçları ve sürümlerini denetler.")

    func run() async throws {
        let locator = ToolLocator()
        var missing = false
        for tool in Tool.allCases {
            guard let path = locator.locate(tool) else {
                print("✗ \(tool.rawValue): bulunamadı")
                missing = true
                continue
            }
            let process = try SystemProcessRunner().start(path, arguments: tool.versionArguments, environment: locator.environment)
            let version = await process.collect().stdout.first ?? "?"
            print("✓ \(tool.rawValue): \(version)  (\(path.path))")
            if tool == .ytDlp, let age = Self.ageInDays(ytDlpVersion: version), age > 60 {
                print("  ! yt-dlp \(age) günlük; YouTube bozulabilir → brew upgrade yt-dlp")
            }
        }
        if missing { throw ExitCode.failure }
    }

    /// "2026.08.19" → bugüne kaç gün.
    static func ageInDays(ytDlpVersion: String) -> Int? {
        let parts = ytDlpVersion.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: .now).day
    }
}

struct Presets: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Kalite ön ayarlarını listeler.")

    func run() throws {
        for preset in try PresetStore.builtIn() {
            print("\(preset.id.padding(toLength: 8, withPad: " ", startingAt: 0)) \(preset.label)")
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}

func parseURL(_ text: String) throws -> URL {
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
        throw ValidationError("Geçerli bir http(s) linki değil: \(text)")
    }
    return url
}

/// Bulunan araçlardan adapter'ları kurar.
struct Toolbox {
    let locator = ToolLocator()
    let ytDlp: YtDlpAdapter

    init() throws {
        setvbuf(stdout, nil, _IOLBF, 0)  // pipe'ta da satır sırası stderr ile karışmasın
        guard let ytDlpPath = locator.locate(.ytDlp) else { throw EngineError.toolMissing(.ytDlp) }
        ytDlp = YtDlpAdapter(executable: ytDlpPath, ffmpeg: locator.locate(.ffmpeg), environment: locator.environment)
    }

    /// Sınıflandırır; site giriş isterse yedek tarayıcının çereziyle bir kez daha dener.
    /// Dönen tarayıcı adı indirmede de kullanılır.
    func classify(_ url: URL, cookies: CookieOption) async throws -> (DownloadKind, String?) {
        let choice = CookieChoice(cookies.explicit)
        let ytDlp = ytDlp
        let classifier = URLClassifier(probe: { url in
            do {
                return try await ytDlp.probe(url, cookiesFromBrowser: choice.value)
            } catch let error where choice.value == nil && YtDlpAdapter.isLoginError(error) {
                guard let fallback = cookies.fallback else { throw error }
                print("→ site giriş istiyor; \(fallback) çerezleriyle yeniden deneniyor")
                choice.value = fallback
                do {
                    return try await ytDlp.probe(url, cookiesFromBrowser: fallback)
                } catch let error where YtDlpAdapter.isLoginError(error) {
                    throw CLIError("\(fallback) çerezleri yetmedi: \(fallback)'da bu siteye giriş yapıp tekrar dene "
                                   + "(başka tarayıcı için --cookies firefox).\n\(error)")
                }
            }
        })
        return (try await classifier.classify(url), choice.value)
    }

    func aria2() throws -> Aria2Adapter {
        guard let path = locator.locate(.aria2c) else { throw EngineError.toolMissing(.aria2c) }
        return Aria2Adapter(executable: path, environment: locator.environment)
    }
}
