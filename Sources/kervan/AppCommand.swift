import ArgumentParser
import Foundation
import KervanIPC

struct AppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Menü çubuğu uygulamasını (Kervan.app) kurar.",
        subcommands: [Install.self]
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "~/Applications/Kervan.app'i kurar ve açar.")

        func run() throws {
            let app = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Kervan.app")
            try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Açıksa kapat; yoksa eski ikili çalışmaya devam eder.
            let quit = Process()
            quit.executableURL = URL(filePath: "/usr/bin/pkill")
            quit.arguments = ["-x", "KervanApp"]
            try? quit.run()
            quit.waitUntilExit()
            try AppBundle.build(at: app, executable: "KervanApp", bundleID: "com.dogukan.kervan", from: AppBundle.buildDirectory,
                                dock: true)
            let open = Process()
            open.executableURL = URL(filePath: "/usr/bin/open")
            open.arguments = [app.path]
            try open.run()
            open.waitUntilExit()
            print("✓ \(app.path) kuruldu ve açıldı (menü çubuğunda ↓ simgesi).")
            if IPCClient.ping() == nil { print("  Servis çalışmıyor: kervan service install") }
        }
    }
}
