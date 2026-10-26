import ArgumentParser
import EngineCore
import Foundation
import KervanIPC
import QueueKit

@main
struct KervanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kervan",
        abstract: "yt-dlp + aria2 tabanlı indirme yöneticisi.",
        discussion: "Kuyruk komutları (add, list, watch…) arka plandaki kervand servisine bağlanır: kervan service install.",
        version: kervanVersion,
        subcommands: [
            Add.self, List.self, Watch.self, Pause.self, Resume.self, Cancel.self, Retry.self, Remove.self, Reveal.self, Log.self,
            Get.self, Probe.self, Formats.self, Update.self, Config.self, Service.self, AppCommand.self, Extension.self, Doctor.self, Presets.self,
        ]
    )
}

/// `add` ve `get`'in ortak seçenekleri.
struct DownloadOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Kalite: best, 1080p, 720p, audio, mp3 ya da herhangi bir yükseklik (480p). Varsayılan: ayardaki.")
    var preset: String?

    @Option(name: .shortAndLong, help: "Hedef klasör. Verilmezse ayardaki klasör (+ açıksa Video/Müzik… tür klasörü).")
    var dir: String?

    @Flag(name: .customLong("subs"), inversion: .prefixedNo, help: "Altyazıyı göm (diller ayardan). Verilmezse ayardaki değer.")
    var subtitles: Bool?

    @Option(help: "Tarayıcı çerezleri: auto (giriş isterse Brave), none ya da brave/chrome/firefox/safari/edge.")
    var cookies = "auto"

    @Flag(help: "Sayfadaki/playlist'teki bütün videolar.")
    var all = false

    @Option(help: "Yalnız seçilen videolar, ör. 1,3 ya da 2-5.")
    var items: String?

    @Option(help: "Referer başlığı (hotlink korumalı dosyalar için sayfa adresi).")
    var referer: String?

    @Option(help: "Dosya adı (uzantısız); verilmezse sitenin başlığı.")
    var name: String?

    var context: RequestContext { RequestContext(referer: referer, filename: name) }

    var settings: KervanSettings { KervanSettings.load() }
    var presetId: String { preset ?? settings.defaultPreset }
    /// Yalnız `-d` verildiyse; servis kendi ayarını kullansın diye nil gönderilir.
    var explicitDirectory: URL? { dir.map { URL(filePath: NSString(string: $0).expandingTildeInPath) } }
    var directory: URL { explicitDirectory ?? URL(filePath: settings.downloadDirectory) }
    var selection: String? { items ?? (all ? "all" : nil) }

    func validatedPreset() throws -> Preset {
        guard let found = try PresetStore.named(presetId) else {
            throw ValidationError("Bilinmeyen preset: \(presetId). Liste: kervan presets")
        }
        return found
    }
}

struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Bir linki servis olmadan, ön planda indirir.")

    @Argument(help: "Video sayfası ya da doğrudan dosya linki.")
    var url: String

    @OptionGroup var options: DownloadOptions

    @Flag(name: .shortAndLong, help: "Araç çıktısını da göster.")
    var verbose = false

    func run() async throws {
        let url = try parseURL(url)
        let preset = try options.validatedPreset()
        let directory = options.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tools = try Toolbox()
        let context = options.context
        let resolved = try await tools.resolver.resolve(url, cookies: CookiePolicy(options.cookies), context: context)
        resolved.notes.forEach { print("→ \($0)") }
        let events: AsyncThrowingStream<DownloadEvent, Error>
        switch resolved.kind {
        case .http:
            print("→ düz dosya (aria2)")
            events = try tools.aria2().download(url, to: directory, context: context)
        case .video(let info):
            print("→ \(info.title ?? url.absoluteString)  [\(info.extractor ?? "?") · \(preset.id)]")
            events = tools.ytDlp.download(url, preset: preset, to: directory, cookiesFromBrowser: resolved.cookiesBrowser,
                                          context: context)
        case .playlist(let info):
            let entries = info.entries ?? []
            guard let selection = options.selection else {
                printSelectionHint(title: info.title, entries: entries)
                return
            }
            let items = selection == "all" ? "1-\(entries.count)" : selection
            print("→ \(info.title ?? url.absoluteString)  [\(info.extractor ?? "?") · \(preset.id) · video \(items)]")
            events = tools.ytDlp.download(url, preset: preset, to: directory, cookiesFromBrowser: resolved.cookiesBrowser,
                                          playlistItems: items)
        }

        let renderer = ProgressRenderer()
        for try await event in events {
            switch event {
            case .progress(let progress): renderer.update(progress)
            case .log(let line): if verbose { renderer.log(line.text) }
            case .completed(let file):
                Quarantine.mark(file)
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
        let resolved = try await Toolbox().resolver.resolve(url, cookies: CookiePolicy(cookies))
        resolved.notes.forEach { print("→ \($0)") }
        switch resolved.kind {
        case .http:
            print("tür: http (aria2)")
        case .video(let info):
            print("tür: video\nbaşlık: \(info.title ?? "-")\nsite: \(info.extractor ?? "-")")
            if let duration = info.duration { print("süre: \(Format.duration(Int(duration)))") }
        case .playlist(let info):
            print("tür: çok videolu sayfa / playlist\nbaşlık: \(info.title ?? "-")\nsite: \(info.extractor ?? "-")")
            printEntries(info.entries ?? [])
        }
        if let browser = resolved.cookiesBrowser { print("çerez: \(browser)") }
    }
}

struct Formats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Videonun kalite seçeneklerini ve yaklaşık boyutlarını listeler.")

    @Argument var url: String

    @Option(help: "Tarayıcı çerezleri: auto, none ya da tarayıcı adı.")
    var cookies = "auto"

    func run() async throws {
        let list = try await Toolbox().resolver.qualities(try parseURL(url), cookies: CookiePolicy(cookies), context: RequestContext())
        if let title = list.title { print(title) }
        guard !list.options.isEmpty else {
            print("Kalite bilgisi yok (çok videolu sayfa olabilir: kervan probe).")
            return
        }
        for option in list.options {
            let size = option.size.map { "~" + Format.bytes($0) } ?? "?"
            print("  \(option.label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(size.padding(toLength: 10, withPad: " ", startingAt: 0)) -p \(option.preset)")
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Dış araçları, sürümlerini ve servisi denetler.")

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
            if tool == .ytDlp, let age = ToolUpdater.ageInDays(version: version), age > 60 {
                print("  ! yt-dlp \(age) günlük; YouTube bozulabilir → kervan update")
            }
        }
        if let version = IPCClient.ping() {
            print("✓ kervand: çalışıyor (\(version))")
            let update = UpdateState.load()
            let auto = KervanSettings.load().autoUpdate ? "açık" : "kapalı"
            print("  otomatik güncelleme \(auto); son kontrol: \(update.lastCheck?.formatted() ?? "henüz yok") \(update.lastResult.map { "· \($0)" } ?? "")")
        } else {
            print("· kervand: çalışmıyor (kuyruk komutları için: kervan service install)")
        }
        if missing { throw ExitCode.failure }
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

func printEntries(_ entries: [ProbeResult.Entry], limit: Int = 50) {
    for (index, entry) in entries.prefix(limit).enumerated() {
        print("  \(index + 1). \(entry.title ?? entry.url ?? entry.id ?? "?")")
    }
    if entries.count > limit { print("  … +\(entries.count - limit)") }
}

func printSelectionHint(title: String?, entries: [ProbeResult.Entry]) {
    print("\(title.map { "\"\($0)\": " } ?? "")bu sayfada \(entries.count) video var:")
    printEntries(entries)
    print("İndirmek için: --all ya da --items 1,3")
}

/// Bulunan araçlardan adapter'ları kurar (servissiz `get` / `probe` için).
struct Toolbox {
    let locator = ToolLocator()
    let ytDlp: YtDlpAdapter

    init() throws {
        setvbuf(stdout, nil, _IOLBF, 0)  // pipe'ta da satır sırası stderr ile karışmasın
        guard let ytDlpPath = locator.locate(.ytDlp) else { throw EngineError.toolMissing(.ytDlp) }
        ytDlp = YtDlpAdapter(executable: ytDlpPath, ffmpeg: locator.locate(.ffmpeg), environment: locator.environment)
    }

    var resolver: LinkResolver { LinkResolver(ytDlp: ytDlp) }

    func aria2() throws -> Aria2Adapter {
        guard let path = locator.locate(.aria2c) else { throw EngineError.toolMissing(.aria2c) }
        return Aria2Adapter(executable: path, environment: locator.environment)
    }
}
