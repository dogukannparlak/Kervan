@testable import EngineCore
import Foundation
@testable import KervanIPC
@testable import QueueKit
import Testing

@Suite struct CategoryTests {
    @Test(arguments: [
        (ItemKind.video, "1080p", "https://youtube.com/watch?v=1", DownloadCategory.video),
        (.video, "mp3", "https://youtube.com/watch?v=1", .music),
        (.video, "audio", "https://x.com/a", .music),
        (.http, "1080p", "https://x.com/a.tar.gz", .archives),
        (.http, "1080p", "https://x.com/kitap.PDF", .documents),
        (.http, "1080p", "https://x.com/App.dmg", .programs),
        (.http, "1080p", "https://x.com/film.mkv", .video),
        (.http, "1080p", "https://x.com/sarki.flac", .music),
        (.http, "1080p", "https://x.com/dosya", .other),
    ])
    func category(kind: ItemKind, preset: String, url: String, expected: DownloadCategory) {
        #expect(DownloadCategory.of(kind: kind, presetId: preset, url: URL(string: url)!) == expected)
    }

    @Test func engineAppliesCategoryAndSubtitles() async throws {
        let engine = try makeEngine(FakeExecutor())
        let outcome = try await engine.add(url: URL(string: "https://youtube.com/watch")!, options: AddOptions(
            presetId: "mp3", destination: "/tmp/kervan-test", cookies: CookiePolicy("none"), subtitles: "tr,en", categorize: true))
        guard case .added(let items, _) = outcome else { return }
        #expect(items.first?.destination == "/tmp/kervan-test/Müzik")
        #expect(items.first?.subtitles == "tr,en")
    }
}

@Suite struct SettingsTests {
    @Test func oldFilesKeepDefaultsForMissingKeys() throws {
        let settings = try JSONDecoder().decode(KervanSettings.self, from: Data(#"{"maxParallel": 50, "categorize": false}"#.utf8))
        #expect(settings.categorize == false)
        #expect(settings.autoUpdate == true)
        #expect(settings.subtitleLanguages == "tr,en")
        #expect(settings.normalized.maxParallel == 10)
        #expect(settings.normalized.maxPerHost == 2)
    }

    @Test func subtitlesOnlyForVideoPresets() throws {
        let adapter = YtDlpAdapter(executable: URL(filePath: "/usr/bin/false"), ffmpeg: nil, runner: SystemProcessRunner(), environment: [:])
        let video = try #require(try PresetStore.named("1080p"))
        let mp3 = try #require(try PresetStore.named("mp3"))
        let videoArgs = adapter.downloadArguments(URL(string: "https://x/v")!, preset: video, to: URL(filePath: "/tmp"), subtitles: "tr,en")
        #expect(videoArgs.contains("--embed-subs"))
        #expect(videoArgs.firstIndex(of: "--sub-langs").map { videoArgs[$0 + 1] } == "tr,en")
        let audioArgs = adapter.downloadArguments(URL(string: "https://x/v")!, preset: mp3, to: URL(filePath: "/tmp"), subtitles: "tr,en")
        #expect(!audioArgs.contains("--embed-subs"))
        #expect(audioArgs.contains("--audio-format"))
    }

    @Test func serverUsesSettingsWhenNoDirectory() async throws {
        let engine = try makeEngine(FakeExecutor())
        let store = SettingsStore()
        var settings = KervanSettings()
        settings.downloadDirectory = "/tmp/kervan-ayar"
        settings.subtitles = true
        settings.defaultPreset = "720p"
        try await store.update(settings)
        let server = IPCServer(engine: engine, settings: store)
        let response = await server.handle(Request(cmd: .add, url: "https://youtube.com/watch", cookies: "none"))
        let item = try #require(response.items?.first)
        #expect(item.destination == "/tmp/kervan-ayar/Video")
        #expect(item.presetId == "720p")
        #expect(item.subtitles == "tr,en")

        let explicit = await server.handle(Request(cmd: .add, url: "https://youtube.com/watch2", dir: "/tmp/elle", cookies: "none", subtitles: false))
        #expect(explicit.items?.first?.destination == "/tmp/elle")
        #expect(explicit.items?.first?.subtitles == nil)

        let bad = await server.handle(Request(cmd: .setSettings, settings: { var s = settings; s.defaultPreset = "yok"; return s }()))
        #expect(!bad.ok)
    }
}

@Suite struct UpdaterTests {
    @Test func brewInstallIsDetected() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "kervan-up-\(UUID().uuidString)")
        let cellar = tmp.appending(path: "Cellar/yt-dlp/2026.08.19/bin")
        try FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data().write(to: cellar.appending(path: "yt-dlp"))
        let link = tmp.appending(path: "yt-dlp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cellar.appending(path: "yt-dlp"))
        let brew = URL(filePath: "/opt/homebrew/bin/brew")
        #expect(ToolUpdater.method(for: link, brew: brew) == .homebrew(brew: brew))
        #expect(ToolUpdater.method(for: link, brew: nil) == .selfUpdate)
        #expect(ToolUpdater.method(for: URL(filePath: "/usr/local/bin/yt-dlp_macos"), brew: brew) == .selfUpdate)
        #expect(ToolUpdater.ageInDays(version: "2026.08.19", now: Date(timeIntervalSince1970: 1_792_800_000)) != nil)
        let sums = "ab12  yt-dlp\nCD34  yt-dlp_macos\nef56  yt-dlp_macos.zip\n"
        #expect(ToolUpdater.checksum(for: "yt-dlp_macos", in: sums) == "cd34")
        #expect(ToolUpdater.checksum(for: "yok", in: sums) == nil)
    }
}
