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

            try fileManager.createDirectory(at: paths.bin, withIntermediateDirectories: true)
            // Preset'ler kervand'ın yanındaki kaynak paketinden okunur.
            for name in ["kervand", "Kervan_EngineCore.bundle", "GRDB_GRDB.bundle"] {
                let from = here.appending(path: name), to = paths.bin.appending(path: name)
                guard fileManager.fileExists(atPath: from.path) else { continue }
                try? fileManager.removeItem(at: to)
                try fileManager.copyItem(at: from, to: to)
            }

            try fileManager.createDirectory(at: paths.launchAgentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": KervanPaths.launchAgentLabel,
                "ProgramArguments": [paths.bin.appending(path: "kervand").path],
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
