@testable import EngineCore
import Foundation
import Testing

@Suite struct QualityTests {
    /// Fixture: `yt-dlp -J aqz-KE-bpKQ` (2026-10-23, yt-dlp 2026.08.19); 1080p -p 1080p ile gerçekte 268 281 336 bayt indi.
    func bigBuckBunny() throws -> FormatProbe {
        let url = try #require(Bundle.module.url(forResource: "bbb-formats", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(FormatProbe.self, from: Data(contentsOf: url))
    }

    @Test func optionsMatchRealDownload() throws {
        let options = QualityPlanner.options(from: try bigBuckBunny())
        #expect(options.first?.label == "2160p60")
        #expect(options.suffix(2).map(\.preset) == ["audio", "mp3"])
        let hd = try #require(options.first { $0.preset == "1080p" })
        #expect(hd.label == "1080p60")
        let size = Double(try #require(hd.size))
        #expect(abs(size - 268_281_336) / 268_281_336 < 0.02)
    }

    @Test func presetSizeEstimate() throws {
        let options = QualityPlanner.options(from: try bigBuckBunny())
        let hd = try #require(options.first { $0.preset == "1080p" }?.size)
        #expect(options.estimatedSize(for: "1080p") == hd)
        #expect(options.estimatedSize(for: "best") == options.first?.size)
        #expect(options.estimatedSize(for: "1100p") == hd)  // tam yoksa altındaki en yüksek
        #expect(options.estimatedSize(for: "mp3") != nil)
        #expect(options.estimatedSize(for: "50p") == nil)
    }

    @Test func probeCarriesQualities() async throws {
        let url = try #require(Bundle.module.url(forResource: "bbb-formats", withExtension: "json", subdirectory: "Fixtures"))
        let json = try String(contentsOf: url, encoding: .utf8)
        let adapter = YtDlpAdapter(executable: URL(filePath: "/bin/yt-dlp"), ffmpeg: nil,
                                   runner: MockRunner(lines: [OutputLine(.stdout, json)], status: 0), environment: [:])
        let probe = try await adapter.probe(URL(string: "https://youtube.com/watch?v=aqz-KE-bpKQ")!)
        #expect(probe.qualities?.estimatedSize(for: "1080p") != nil)
    }

    @Test func heightPresetsAreSynthesized() throws {
        let sd = try #require(try PresetStore.named("480p"))
        #expect(sd.format.contains("height<=480"))
        #expect(sd.container == "mp4")
        #expect(try PresetStore.named("1440p")?.container == "mkv")
        #expect(try PresetStore.named("1080p")?.label.contains("H.264") == true)  // hazır preset öncelikli
        #expect(try PresetStore.named("abc") == nil)
        #expect(try PresetStore.named("99999p") == nil)
    }

    @Test func playlistHasNoOptions() throws {
        let probe = try JSONDecoder().decode(FormatProbe.self, from: Data(#"{"_type":"playlist","title":"L"}"#.utf8))
        #expect(QualityPlanner.options(from: probe).isEmpty)
    }
}
