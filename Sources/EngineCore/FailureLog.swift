import Foundation

/// yt-dlp hatalarının kalıcı kaydı: `<Kervan>/yt-dlp-hatalar.log`.
/// Öğe log'u (`logs/<id>.log`) silinince ya da hata kalite sorgusunda (öğe yokken) olunca kaybolmasın diye
/// her hata tam stderr, çıkış kodu ve yt-dlp sürümüyle buraya eklenir. Header değerleri (Cookie vb.) gizlenir.
public struct FailureLog: Sendable {
    public let url: URL
    static let maxBytes = 512 * 1024  // aşılırsa eski yarısı atılır

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        let home = ProcessInfo.processInfo.environment["KERVAN_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Kervan")
        return home.appending(path: "yt-dlp-hatalar.log")
    }

    public func record(kind: String, executable: URL, arguments: [String], status: Int32, stderr: [String]) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var text = "=== \(stamp) · \(kind) · çıkış \(status) · yt-dlp \(Self.version(of: executable))\n"
        text += "komut: yt-dlp \(Self.redacted(arguments).joined(separator: " "))\n"
        text += stderr.suffix(80).joined(separator: "\n") + "\n\n"
        append(text)
    }

    static func redacted(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var maskNext = false
        for argument in arguments {
            if maskNext, let colon = argument.firstIndex(of: ":") {
                result.append("\(argument[..<colon]):***")
            } else {
                result.append(argument)
            }
            maskNext = argument == "--add-headers"
        }
        return result
    }

    /// Sürüm, yt-dlp'nin ana dizinindeki dosya adından/`--version` çıktısından değil, ucuz yoldan: çalıştır, 2 sn.
    static func version(of executable: URL) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "?" }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return "?" }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func append(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxBytes,
           let old = try? Data(contentsOf: url) {
            try? old.suffix(Self.maxBytes / 2).write(to: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
