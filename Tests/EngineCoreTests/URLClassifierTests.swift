@testable import EngineCore
import Foundation
import Testing

struct StubHead: HeadFetching {
    let info: HeadInfo?

    func head(_ url: URL, headers: [String: String]) async throws -> HeadInfo {
        guard let info else { throw URLError(.badServerResponse) }
        return info
    }
}

private func probeResult(type: String? = nil, direct: Bool? = nil) throws -> ProbeResult {
    var object: [String: Any] = ["title": "t"]
    if let type { object["_type"] = type }
    if let direct { object["direct"] = direct }
    return try JSONDecoder().decode(ProbeResult.self, from: JSONSerialization.data(withJSONObject: object))
}

@Suite struct URLClassifierTests {
    @Test(arguments: [
        ("application/zip", nil, true),
        ("application/octet-stream", nil, true),
        ("video/mp4", nil, true),
        ("text/html; charset=utf-8", nil, false),
        ("application/vnd.apple.mpegurl", nil, false),
        ("application/dash+xml", nil, false),
        ("text/plain", "attachment; filename=a.txt", true),
        (nil, nil, false),
    ] as [(String?, String?, Bool)])
    func directFileDetection(contentType: String?, disposition: String?, expected: Bool) {
        let info = HeadInfo(statusCode: 200, contentType: contentType, contentDisposition: disposition)
        #expect(URLClassifier.isDirectFile(info) == expected)
    }

    @Test func errorStatusIsNeverDirect() {
        #expect(!URLClassifier.isDirectFile(HeadInfo(statusCode: 404, contentType: "application/zip", contentDisposition: nil)))
    }

    @Test func headSaysFileSkipsProbe() async throws {
        let classifier = URLClassifier(head: StubHead(info: HeadInfo(statusCode: 200, contentType: "application/gzip", contentDisposition: nil)),
                                       probe: { _ in Issue.record("probe çağrılmamalı"); throw URLError(.unknown) })
        #expect(try await classifier.classify(URL(string: "https://x/a.tar.gz")!) == .http)
    }

    @Test func probeDirectMeansHTTP() async throws {
        let result = try probeResult(direct: true)
        let classifier = URLClassifier(head: StubHead(info: nil), probe: { _ in result })
        #expect(try await classifier.classify(URL(string: "https://x/a")!) == .http)
    }

    @Test func htmlPageIsVideoOrPlaylist() async throws {
        let html = StubHead(info: HeadInfo(statusCode: 200, contentType: "text/html", contentDisposition: nil))
        let video = try probeResult()
        let playlist = try probeResult(type: "playlist")
        #expect(try await URLClassifier(head: html, probe: { _ in video }).classify(URL(string: "https://x/v")!) == .video(video))
        #expect(try await URLClassifier(head: html, probe: { _ in playlist }).classify(URL(string: "https://x/p")!) == .playlist(playlist))
    }

    @Test func probeFailurePropagates() async {
        let html = StubHead(info: HeadInfo(statusCode: 200, contentType: "text/html", contentDisposition: nil))
        let classifier = URLClassifier(head: html, probe: { _ in throw EngineError.toolFailed(.ytDlp, status: 1, message: "ERROR: Unsupported URL") })
        await #expect(throws: EngineError.self) { try await classifier.classify(URL(string: "https://x/page")!) }
    }
}

@Suite struct LocalNetworkTests {
    @Test(arguments: [
        "http://localhost:8080/a", "http://127.0.0.1/", "http://127.1/", "http://0x7f.0.0.1/", "http://2130706433/",
        "http://10.0.0.5/x.mp4", "http://172.20.1.1/", "http://192.168.1.10/", "http://169.254.169.254/latest",
        "http://0.0.0.0/", "http://[::1]/", "http://[fd12::1]/", "http://[fe80::1]/", "http://[::ffff:192.168.1.1]/",
        "http://nas/", "http://nas.local/", "http://router.lan/", "http://foo.localhost/",
    ])
    func local(_ link: String) {
        #expect(LocalNetwork.isLocal(URL(string: link)!))
    }

    @Test(arguments: [
        "https://youtube.com/watch?v=1", "https://8.8.8.8/", "http://172.32.0.1/", "http://192.169.0.1/",
        "https://[2001:db8::1]/", "https://cdn.example.com/a.mp4",
    ])
    func remote(_ link: String) {
        #expect(!LocalNetwork.isLocal(URL(string: link)!))
    }
}

@Suite struct CookiePolicyTests {
    @Test func values() {
        #expect(CookiePolicy("auto", environment: [:]) == CookiePolicy(explicit: nil, fallback: "brave"))
        #expect(CookiePolicy("none", environment: [:]) == CookiePolicy(explicit: nil, fallback: nil))
        // Eklentide kullanıcı "tarayıcı çerezleriyle dene" dediğinde.
        #expect(CookiePolicy("fallback", environment: ["KERVAN_COOKIES_BROWSER": "firefox"]) == CookiePolicy(explicit: "firefox", fallback: nil))
        #expect(CookiePolicy("Chrome", environment: [:]) == CookiePolicy(explicit: "chrome", fallback: nil))
    }
}
