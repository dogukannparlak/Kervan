import Foundation
import KervanIPC

/// SwiftPM çıktısından macOS uygulama paketi kurar: Contents/{MacOS/<ikili>, Resources/*.bundle + AppIcon.icns,
/// Info.plist}, ad-hoc imzalı. Servis ("Kervan Agent.app") ve uygulama ("Kervan.app") aynı yolu kullanır.
enum AppBundle {
    static func build(at app: URL, executable: String, bundleID: String, from here: URL) throws {
        let fileManager = FileManager.default
        let contents = app.appending(path: "Contents")
        try? fileManager.removeItem(at: app)
        for dir in ["MacOS", "Resources"] {
            try fileManager.createDirectory(at: contents.appending(path: dir), withIntermediateDirectories: true)
        }
        let binary = here.appending(path: executable)
        guard fileManager.isExecutableFile(atPath: binary.path) else {
            throw CLIError("\(binary.path) yok. Önce derle: swift build -c release")
        }
        try fileManager.copyItem(at: binary, to: contents.appending(path: "MacOS/\(executable)"))
        for name in ["Kervan_EngineCore.bundle", "GRDB_GRDB.bundle"] where fileManager.fileExists(atPath: here.appending(path: name).path) {
            try fileManager.copyItem(at: here.appending(path: name), to: contents.appending(path: "Resources/\(name)"))
        }
        if let icon = repoFile("resources/AppIcon.icns", near: here) {
            try fileManager.copyItem(at: icon, to: contents.appending(path: "Resources/AppIcon.icns"))
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Kervan",
            "CFBundleDisplayName": "Kervan",
            "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": kervanVersion,
            "CFBundleVersion": kervanVersion,
            "LSUIElement": true,  // Dock'ta değil, menü çubuğunda
            "LSMinimumSystemVersion": "15.0",
            "NSHighResolutionCapable": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let sign = Process()
        sign.executableURL = URL(filePath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--deep", "--sign", "-", app.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw CLIError("codesign başarısız: \(app.path)") }
    }

    /// .build/<yapı>/kervan → repo/<yol>
    static func repoFile(_ relative: String, near binary: URL) -> URL? {
        var dir = binary
        for _ in 0..<4 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appending(path: relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static var buildDirectory: URL {
        get throws {
            guard let here = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else {
                throw CLIError("kervan'ın yeri bulunamadı.")
            }
            return here
        }
    }
}
