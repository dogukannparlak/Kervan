import ArgumentParser
import Foundation
import KervanIPC

struct Service: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "kervand arka plan servisini (LaunchAgent) yönetir.",
        subcommands: [Install.self, Uninstall.self, Status.self]
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "kervand'ı Application Support/Kervan/bin'e kopyalar ve oturum açılışında başlatır."
        )

        /// Servisi kimlikli, Dock'ta görünmeyen bir uygulama paketine koyar (Etkinlik Monitörü'nde "Kervan" görünür,
        /// M4 uygulamasının temeli):
        /// Kervan Agent.app/Contents/{MacOS/kervand, Resources/*.bundle, Resources/AppIcon.icns, Info.plist}.
        static func buildAgentApp(from here: URL, paths: KervanPaths) throws -> URL {
            let fileManager = FileManager.default
            let app = paths.home.appending(path: "Kervan Agent.app")
            let contents = app.appending(path: "Contents")
            try? fileManager.removeItem(at: app)
            for dir in ["MacOS", "Resources"] {
                try fileManager.createDirectory(at: contents.appending(path: dir), withIntermediateDirectories: true)
            }
            try fileManager.copyItem(at: here.appending(path: "kervand"), to: contents.appending(path: "MacOS/kervand"))
            for name in ["Kervan_EngineCore.bundle", "GRDB_GRDB.bundle"] where fileManager.fileExists(atPath: here.appending(path: name).path) {
                try fileManager.copyItem(at: here.appending(path: name), to: contents.appending(path: "Resources/\(name)"))
            }
            if let icon = Self.repoFile("resources/AppIcon.icns", near: here) {
                try fileManager.copyItem(at: icon, to: contents.appending(path: "Resources/AppIcon.icns"))
            }
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.dogukan.kervan.agent",
                "CFBundleName": "Kervan",
                "CFBundleDisplayName": "Kervan",
                "CFBundleExecutable": "kervand",
                "CFBundlePackageType": "APPL",
                "CFBundleIconFile": "AppIcon",
                "CFBundleShortVersionString": kervanVersion,
                "CFBundleVersion": kervanVersion,
                "LSUIElement": true,
                "LSMinimumSystemVersion": "15.0",
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
            // Ad-hoc imza: paket bütünlüğü.
            let sign = Process()
            sign.executableURL = URL(filePath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--deep", "--sign", "-", app.path]
            sign.standardError = FileHandle.nullDevice
            try sign.run()
            sign.waitUntilExit()
            guard sign.terminationStatus == 0 else { throw CLIError("codesign başarısız: \(app.path)") }
            // Köprü kuruluysa onu da güncelle: eski köprü yeni komutları "Geçersiz istek" diye reddeder.
            let host = paths.bin.appending(path: "kervan-native-host")
            if fileManager.fileExists(atPath: host.path), fileManager.fileExists(atPath: here.appending(path: "kervan-native-host").path) {
                try? fileManager.removeItem(at: host)
                try fileManager.copyItem(at: here.appending(path: "kervan-native-host"), to: host)
            }
            // Eski yerleşimden (bin/kervand) kalanlar.
            for name in ["kervand", "Kervan_EngineCore.bundle", "GRDB_GRDB.bundle"] {
                try? fileManager.removeItem(at: paths.bin.appending(path: name))
            }
            return app
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

        func run() throws {
            let paths = KervanPaths()
            let fileManager = FileManager.default
            guard let here = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else {
                throw CLIError("kervan'ın yeri bulunamadı.")
            }
            let source = here.appending(path: "kervand")
            guard fileManager.isExecutableFile(atPath: source.path) else {
                throw CLIError("\(source.path) yok. Önce derle: swift build -c release")
            }

            let agent = try Self.buildAgentApp(from: here, paths: paths)

            try fileManager.createDirectory(at: paths.launchAgentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": KervanPaths.launchAgentLabel,
                "ProgramArguments": [agent.appending(path: "Contents/MacOS/kervand").path],
                "RunAtLoad": true,
                "KeepAlive": true,
                "StandardOutPath": paths.home.appending(path: "kervand.log").path,
                "StandardErrorPath": paths.home.appending(path: "kervand.log").path,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: paths.launchAgentPlist)

            // bootout eşzamansızdır: eski servis kapanırken bootstrap reddedilir, kalkmasını bekle.
            let service = "gui/\(getuid())/\(KervanPaths.launchAgentLabel)"
            _ = launchctl(["bootout", service])
            for _ in 0..<100 where launchctl(["print", service]) == 0 {
                Thread.sleep(forTimeInterval: 0.1)
            }
            var bootstrapped = false
            for _ in 0..<5 {
                if launchctl(["bootstrap", "gui/\(getuid())", paths.launchAgentPlist.path]) == 0 {
                    bootstrapped = true
                    break
                }
                Thread.sleep(forTimeInterval: 1)
            }
            guard bootstrapped else {
                throw CLIError("launchctl bootstrap başarısız. Log: \(paths.home.appending(path: "kervand.log").path)")
            }
            for _ in 0..<50 {
                if let version = IPCClient.ping(paths: paths) {
                    print("✓ kervand \(version) çalışıyor (\(paths.launchAgentPlist.path))")
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw CLIError("kervand başlatıldı ama yanıt vermiyor. Log: \(paths.home.appending(path: "kervand.log").path)")
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Servisi durdurur ve kaldırır (kuyruk veritabanı kalır).")

        func run() throws {
            let paths = KervanPaths()
            _ = launchctl(["bootout", "gui/\(getuid())/\(KervanPaths.launchAgentLabel)"])
            try? FileManager.default.removeItem(at: paths.launchAgentPlist)
            print("✓ kervand durduruldu ve kaldırıldı. Kuyruk: \(paths.database.path)")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Servis çalışıyor mu?")

        func run() throws {
            let paths = KervanPaths()
            if let version = IPCClient.ping(paths: paths) {
                print("✓ kervand \(version) çalışıyor")
            } else {
                print("✗ kervand çalışmıyor")
                print(FileManager.default.fileExists(atPath: paths.launchAgentPlist.path)
                      ? "  LaunchAgent kurulu; log: \(paths.home.appending(path: "kervand.log").path)"
                      : "  Kur: kervan service install")
                throw ExitCode.failure
            }
        }
    }
}

@discardableResult
func launchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}
