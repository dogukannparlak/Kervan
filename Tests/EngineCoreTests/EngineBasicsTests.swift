@testable import EngineCore
import Foundation
import Testing

@Suite struct ProcessRunnerTests {
    @Test func capturesBothStreamsAndExitCode() async throws {
        let process = try SystemProcessRunner().start(URL(filePath: "/bin/sh"), arguments: ["-c", "echo bir; echo iki >&2; printf 'üç\\rdört'; exit 3"],
                                                      environment: [:])
        let result = await process.collect()
        #expect(result.stdout == ["bir", "üç", "dört"])
        #expect(result.stderr == ["iki"])
        #expect(result.status == 3)
    }

    @Test func terminateStopsLongProcess() async throws {
        let process = try SystemProcessRunner().start(URL(filePath: "/bin/sleep"), arguments: ["30"], environment: [:])
        let start = ContinuousClock.now
        await process.terminate(grace: .seconds(2))
        _ = await process.waitUntilExit()
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func splitterHandlesChunkedInput() {
        let splitter = LineSplitter()
        #expect(splitter.feed(Data("ab".utf8)) == [])
        #expect(splitter.feed(Data("c\r\nd".utf8)) == ["abc"])
        #expect(splitter.finish() == ["d"])
    }
}

@Suite struct PresetTests {
    @Test func builtInPresetsLoad() throws {
        let presets = try PresetStore.builtIn()
        #expect(presets.map(\.id) == ["1080p", "720p", "audio", "best", "mp3"])
        #expect(try PresetStore.named("audio")?.requiresFFmpeg == false)
    }
}

@Suite struct ToolLocatorTests {
    @Test func overrideWinsAndInvalidOverrideMeansMissing() {
        #expect(ToolLocator(environment: ["KERVAN_FFMPEG": "/bin/sh"]).locate(.ffmpeg)?.path == "/bin/sh")
        #expect(ToolLocator(environment: ["KERVAN_FFMPEG": "/yok/ffmpeg"]).locate(.ffmpeg) == nil)
        #expect(Tool.ytDlp.overrideVariable == "KERVAN_YT_DLP")
    }

    @Test func environmentIncludesHomebrew() {
        let env = ToolLocator(environment: ["PATH": "/usr/bin"]).environment
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(env["PYTHONIOENCODING"] == "utf-8")
    }
}

@Suite struct Aria2StatusTests {
    @Test func statusMapsToProgress() throws {
        let json = #"{"status":"active","totalLength":"1000","completedLength":"250","downloadSpeed":"50","files":[{"path":""}]}"#
        let status = try JSONDecoder().decode(Aria2Status.self, from: Data(json.utf8))
        #expect(status.event == ProgressEvent(phase: .download, bytesDone: 250, bytesTotal: 1000, speed: 50, eta: 15))
    }

    @Test func unknownLengthHasNoTotal() throws {
        let json = #"{"status":"active","totalLength":"0","completedLength":"0","downloadSpeed":"0","files":[]}"#
        let status = try JSONDecoder().decode(Aria2Status.self, from: Data(json.utf8))
        #expect(status.event.bytesTotal == nil)
        #expect(status.event.eta == nil)
    }
}

@Suite struct RequestContextTests {
    @Test func filenameIsSanitized() {
        #expect(RequestContext(filename: "  Film: Bölüm 1/2 | \"HD\"  ").filename == "Film Bölüm 1 2 HD")
        #expect(RequestContext(filename: "...").filename == nil)
        #expect(RequestContext.sanitize(String(repeating: "a", count: 300)).count == 150)
    }

    @Test func headersReachYtDlpArguments() {
        let adapter = YtDlpAdapter(executable: fakeYtDlp, ffmpeg: nil, runner: MockRunner(lines: [], status: 0), environment: [:])
        let args = adapter.downloadArguments(URL(string: "https://x/v.m3u8")!, preset: preset1080, to: URL(filePath: "/tmp"),
                                             context: RequestContext(referer: "https://site/page", userAgent: "UA", filename: "Ad %50"))
        #expect(args.contains("Referer:https://site/page"))
        #expect(args.contains("User-Agent:UA"))
        #expect(args.firstIndex(of: "-o").map { args[$0 + 1] } == "Ad %%50.%(ext)s")
    }
}
