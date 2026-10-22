import ArgumentParser
import Foundation
import KervanIPC

struct Extension: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tarayıcı eklentisinin köprüsünü (Native Messaging) kurar.",
        subcommands: [Install.self, Uninstall.self]
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "kervan-native-host'u kopyalar, Brave/Chrome/Edge için köprü manifest'ini yazar."
        )

        func run() throws {
            let paths = KervanPaths()
            let fileManager = FileManager.default
            guard let here = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else {
                throw CLIError("kervan'ın yeri bulunamadı.")
            }
            let source = here.appending(path: "kervan-native-host")
            guard fileManager.isExecutableFile(atPath: source.path) else {
                throw CLIError("\(source.path) yok. Önce derle: swift build -c release")
            }
            try fileManager.createDirectory(at: paths.bin, withIntermediateDirectories: true)
            let host = paths.bin.appending(path: "kervan-native-host")
            try? fileManager.removeItem(at: host)
            try fileManager.copyItem(at: source, to: host)

            let manifest: [String: Any] = [
                "name": KervanPaths.nativeHostName,
                "description": "Kervan indirme yöneticisi köprüsü",
                "path": host.path,
                "type": "stdio",
                "allowed_origins": ["chrome-extension://\(KervanPaths.extensionID)/"],
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            var installed: [String] = []
            for browser in KervanPaths.browserDirectories {
                let browserDir = support.appending(path: browser)
                guard fileManager.fileExists(atPath: browserDir.path) else { continue }
                let hosts = browserDir.appending(path: "NativeMessagingHosts")
                try fileManager.createDirectory(at: hosts, withIntermediateDirectories: true)
                try data.write(to: hosts.appending(path: "\(KervanPaths.nativeHostName).json"))
                installed.append(browser)
            }
            guard !installed.isEmpty else { throw CLIError("Desteklenen tarayıcı bulunamadı (Brave, Chrome, Edge, Chromium, Vivaldi).") }
            print("✓ köprü kuruldu: \(installed.joined(separator: ", "))")

            let folder = Self.extensionFolder(near: here)
            print("""

            Eklentiyi bir kez yükle (Brave):
              1. brave://extensions aç
              2. Sağ üstten "Geliştirici modu"nu aç
              3. "Paketlenmemiş öğe yükle" → \(folder ?? "repo içindeki extension/ klasörü")
            Kimlik \(KervanPaths.extensionID) olmalı. Servis çalışmıyorsa: kervan service install
            """)
        }

        /// .build/<yapı>/kervan → repo/extension
        static func extensionFolder(near binary: URL) -> String? {
            var dir = binary
            for _ in 0..<4 {
                dir = dir.deletingLastPathComponent()
                let candidate = dir.appending(path: "extension/manifest.json")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate.deletingLastPathComponent().path }
            }
            return nil
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Köprü manifest'lerini siler (eklentiyi tarayıcıdan sen kaldırırsın).")

        func run() throws {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            for browser in KervanPaths.browserDirectories {
                try? FileManager.default.removeItem(at: support.appending(path: "\(browser)/NativeMessagingHosts/\(KervanPaths.nativeHostName).json"))
            }
            try? FileManager.default.removeItem(at: KervanPaths().bin.appending(path: "kervan-native-host"))
            print("✓ köprü kaldırıldı")
        }
    }
}
