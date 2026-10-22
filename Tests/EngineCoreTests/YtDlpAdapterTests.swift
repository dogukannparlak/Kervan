@testable import EngineCore
import Foundation
import Testing

/// Satırlar 2026-10-23'te yt-dlp 2026.08.19 ile gerçek bir indirmeden (jNQXAC9IVRw) alındı.
let realDownloadLines: [OutputLine] = [
    OutputLine(.stdout, "KERVAN_INFO|395+251|475961"),
    OutputLine(.stdout, "KERVAN_DL|downloading|1024|223779|NA|24715.822251890386|9"),
    OutputLine(.stdout, "KERVAN_DL|finished|223779|223779|NA|517981.88151501055|NA"),
    OutputLine(.stdout, "KERVAN_DL|downloading|2048|252182|NA|30000.5|8"),
    OutputLine(.stdout, "KERVAN_DL|finished|252182|252182|NA|1021843.8798010274|NA"),
    OutputLine(.stderr, "KERVAN_PP|started|Merger"),
    OutputLine(.stderr, "KERVAN_PP|finished|Merger"),
    OutputLine(.stdout, "KERVAN_FILE|/tmp/Me at the zoo | 2005 [jNQXAC9IVRw].mp4"),
]

let fakeYtDlp = URL(filePath: "/usr/bin/false")
let preset1080 = Preset(id: "1080p", label: "", format: "bv*+ba/b", container: "mp4", requiresFFmpeg: true)

@Suite struct YtDlpProgressTrackerTests {
    @Test func twoPartDownloadAccumulatesBytes() {
        var tracker = YtDlpProgressTracker()
        let events = realDownloadLines.compactMap { tracker.consume($0) }.compactMap { event -> ProgressEvent? in
            if case .progress(let progress) = event { progress } else { nil }
        }
        let downloads = events.filter { $0.phase == .download }
        #expect(downloads.map(\.bytesDone) == [0, 1024, 223779, 223779 + 2048, 475961])
        #expect(downloads.allSatisfy { $0.bytesTotalEstimate == 475961 })
        #expect(downloads[1].message == "parça 1/2")
        #expect(downloads[3].message == "parça 2/2")
        #expect(downloads.last?.fraction == 1)
        #expect(events.last?.phase == .postprocess)
        #expect(events.last?.message == "Merger")
    }

    @Test func fileLineCompletesWithPipeInName() {
        var tracker = YtDlpProgressTracker()
        #expect(tracker.consume(realDownloadLines.last!) == .completed(URL(filePath: "/tmp/Me at the zoo | 2005 [jNQXAC9IVRw].mp4")))
    }

    @Test func secondVideoResetsParts() {
        var tracker = YtDlpProgressTracker()
        realDownloadLines.forEach { _ = tracker.consume($0) }
        _ = tracker.consume(OutputLine(.stdout, "KERVAN_INFO|18|1000"))
        let event = tracker.consume(OutputLine(.stdout, "KERVAN_DL|downloading|100|1000|NA|NA|NA"))
        #expect(event == .progress(ProgressEvent(phase: .download, bytesDone: 100, bytesTotal: 1000, message: "video 2")))
    }

    @Test func singleFileUsesExactTotal() {
        var tracker = YtDlpProgressTracker()
        _ = tracker.consume(OutputLine(.stdout, "KERVAN_INFO|140|NA"))
        guard case .progress(let event)? = tracker.consume(OutputLine(.stdout, "KERVAN_DL|downloading|500|1000|NA|NA|NA")) else {
            Issue.record("ilerleme olayı yok")
            return
        }
        #expect(event.bytesTotal == 1000)
        #expect(event.fraction == 0.5)
        #expect(event.speed == nil)
        #expect(event.eta == nil)
    }

    @Test func fragmentedDownloadUsesEstimate() {
        var tracker = YtDlpProgressTracker()
        let event = tracker.consume(OutputLine(.stdout, "KERVAN_DL|downloading|300|NA|1200|100.0|9"))
        #expect(event == .progress(ProgressEvent(phase: .download, bytesDone: 300, bytesTotalEstimate: 1200, speed: 100, eta: 9)))
    }

    /// 2026-10-23, yt-dlp 2026.08.19, Apple bipbop HLS: tahmin ve eta ondalıklı.
    @Test func hlsFloatEstimateAndEta() {
        var tracker = YtDlpProgressTracker()
        let event = tracker.consume(OutputLine(.stdout, "KERVAN_DL|downloading|671250|NA|38573366.66666667|282500.27|121.98|2|100"))
        #expect(event == .progress(ProgressEvent(phase: .download, bytesDone: 671250, bytesTotalEstimate: 38573366, speed: 282500.27, eta: 122)))
    }

    @Test func fragmentRatioWhenNoEstimate() {
        var tracker = YtDlpProgressTracker()
        guard case .progress(let event)? = tracker.consume(OutputLine(.stdout, "KERVAN_DL|downloading|5000|NA|NA|NA|NA|5|100")) else {
            Issue.record("ilerleme yok")
            return
        }
        #expect(event.bytesTotalEstimate == 100_000)
        #expect(event.fraction == 0.05)
    }

    @Test func otherLinesAreNotParsed() {
        var tracker = YtDlpProgressTracker()
        #expect(tracker.consume(OutputLine(.stderr, "WARNING: something")) == nil)
    }
}

@Suite struct YtDlpAdapterTests {
    @Test func downloadEmitsCompletedFile() async throws {
        let runner = MockRunner(lines: realDownloadLines, status: 0)
        let adapter = YtDlpAdapter(executable: fakeYtDlp, ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"), runner: runner, environment: [:])
        var last: DownloadEvent?
        for try await event in adapter.download(URL(string: "https://example.com/v")!, preset: preset1080, to: URL(filePath: "/tmp")) {
            last = event
        }
        #expect(last == .completed(URL(filePath: "/tmp/Me at the zoo | 2005 [jNQXAC9IVRw].mp4")))
        let args = try #require(runner.recorder.last)
        #expect(args.suffix(2) == ["--", "https://example.com/v"])
        #expect(args.contains("--merge-output-format"))
        #expect(args.contains("--ffmpeg-location"))
        #expect(args.contains("--no-playlist"))
        #expect(!args.contains("--cookies-from-browser"))
    }

    @Test func cookiesAndPlaylistItemsReachArguments() {
        let adapter = YtDlpAdapter(executable: fakeYtDlp, ffmpeg: nil, runner: MockRunner(lines: [], status: 0), environment: [:])
        let args = adapter.downloadArguments(URL(string: "https://x/p")!, preset: preset1080, to: URL(filePath: "/tmp"),
                                             cookiesFromBrowser: "brave", playlistItems: "1,3")
        #expect(args.contains("--yes-playlist"))
        #expect(!args.contains("--no-playlist"))
        #expect(args.firstIndex(of: "--playlist-items").map { args[$0 + 1] } == "1,3")
        #expect(args.firstIndex(of: "--cookies-from-browser").map { args[$0 + 1] } == "brave")
    }

    /// Mesajlar 2026-10-23'te yt-dlp 2026.08.19'dan alındı.
    @Test(arguments: [
        ("ERROR: [vimeo] 1: The web client only works when logged-in. Use --cookies, --cookies-from-browser", true),
        ("ERROR: [Reddit] 1: Account authentication is required. Use --cookies-from-browser", true),
        ("ERROR: [dailymotion] x: Not found.", false),
    ])
    func loginErrorDetection(message: String, expected: Bool) {
        #expect(YtDlpAdapter.isLoginError(EngineError.toolFailed(.ytDlp, status: 1, message: message)) == expected)
        #expect(!YtDlpAdapter.isLoginError(EngineError.toolFailed(.aria2c, status: 1, message: message)))
    }

    @Test func missingFFmpegRejectsVideoPreset() async {
        let adapter = YtDlpAdapter(executable: fakeYtDlp, ffmpeg: nil, runner: MockRunner(lines: [], status: 0), environment: [:])
        await #expect(throws: EngineError.ffmpegMissing) {
            for try await _ in adapter.download(URL(string: "https://example.com/v")!, preset: preset1080, to: URL(filePath: "/tmp")) {}
        }
    }

    @Test func failureReportsErrorLine() async {
        let lines = [OutputLine(.stderr, "WARNING: x"), OutputLine(.stderr, "ERROR: [youtube] abc: Video unavailable")]
        let adapter = YtDlpAdapter(executable: fakeYtDlp, ffmpeg: nil, runner: MockRunner(lines: lines, status: 1), environment: [:])
        await #expect(throws: EngineError.toolFailed(.ytDlp, status: 1, message: "ERROR: [youtube] abc: Video unavailable")) {
            try await adapter.probe(URL(string: "https://example.com/v")!)
        }
    }

    @Test func probeDecodesPlaylist() async throws {
        let json = #"{"_type":"playlist","title":"Liste","extractor":"youtube:tab","entries":[{"id":"a","title":"A","url":"https://y/a"},{"id":"b"}]}"#
        let adapter = YtDlpAdapter(executable: fakeYtDlp, ffmpeg: nil, runner: MockRunner(lines: [OutputLine(.stdout, json)], status: 0), environment: [:])
        let result = try await adapter.probe(URL(string: "https://example.com/list")!)
        #expect(result.isPlaylist)
        #expect(result.entries?.count == 2)
    }
}
