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
        let events: AsyncThrowingStream<DownloadEvent, Error>
        switch try await tools.classifier.classify(url) {
        case .http:
            print("→ düz dosya (aria2)")
            events = try tools.aria2().download(url, to: directory)
        case .video(let info):
            print("→ \(info.title ?? url.absoluteString)  [\(info.extractor ?? "?") · \(preset.id)]")
            events = tools.ytDlp.download(url, preset: preset, to: directory)
        case .playlist(let info):
            throw ValidationError("Playlist (\(info.entries?.count ?? 0) giriş) M2'de gelecek. Tek video linki ver.")
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

    func run() async throws {
        let url = try parseURL(url)
        let tools = try Toolbox()
        switch try await tools.classifier.classify(url) {
        case .http:
            print("tür: http (aria2)")
        case .video(let info):
            print("tür: video\nbaşlık: \(info.title ?? "-")\nsite: \(info.extractor ?? "-")")
            if let duration = info.duration { print("süre: \(Format.duration(Int(duration)))") }
        case .playlist(let info):
            print("tür: playlist\nbaşlık: \(info.title ?? "-")\nsite: \(info.extractor ?? "-")\ngiriş: \(info.entries?.count ?? 0)")
        }
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
    let classifier: URLClassifier

    init() throws {
        guard let ytDlpPath = locator.locate(.ytDlp) else { throw EngineError.toolMissing(.ytDlp) }
        let ytDlp = YtDlpAdapter(executable: ytDlpPath, ffmpeg: locator.locate(.ffmpeg), environment: locator.environment)
        self.ytDlp = ytDlp
        classifier = URLClassifier(probe: { try await ytDlp.probe($0) })
    }

    func aria2() throws -> Aria2Adapter {
        guard let path = locator.locate(.aria2c) else { throw EngineError.toolMissing(.aria2c) }
        return Aria2Adapter(executable: path, environment: locator.environment)
    }
}
