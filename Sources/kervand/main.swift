import Darwin
import EngineCore
import Foundation
import KervanIPC
import QueueKit

// kervand: kuyruğun tek sahibi. LaunchAgent olarak çalışır (`kervan service install`),
// geliştirmede ön planda da çalıştırılabilir: `swift run kervand`.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let paths = KervanPaths()

func log(_ message: String) {
    print("\(Date().formatted(.iso8601)) \(message)")
}

/// kervand.log 5 MB'ı geçince kervand.log.1'e kopyalanır (öncekinin yerine) ve sıfırlanır. launchd dosyayı
/// O_APPEND ile açtığı için servis aynı dosyaya baştan yazmaya devam eder.
func rotateLog(_ file: URL, limit: Int = 5 * 1024 * 1024) {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > limit else { return }
    let previous = file.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: previous)
    guard (try? FileManager.default.copyItem(at: file, to: previous)) != nil else { return }
    truncate(file.path, 0)
    log("kervand.log döndürüldü (\(size / 1024 / 1024) MB → kervand.log.1)")
}

do {
    try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    // Kuyruk, loglar ve soket yalnız kullanıcıya açık (KERVAN_HOME başka yerdeyse de).
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.home.path)
    if let version = IPCClient.ping(paths: paths) {
        log("kervand zaten çalışıyor (\(version)); çıkılıyor.")
        exit(0)
    }

    ChildRegistry.configure(file: paths.children)
    let reaped = ChildRegistry.reapOrphans()
    if !reaped.isEmpty { log("önceki çalışmadan kalan \(reaped.count) süreç durduruldu: \(reaped)") }

    let executor = try EngineExecutor(locator: ToolLocator())
    let logs = try LogStore(directory: paths.logs)
    let engine = try QueueEngine(store: ItemStore(path: paths.database), executor: executor,
                                 resolver: executor.resolver, logs: logs)
    let pruned = logs.prune(keeping: Set(await engine.list().compactMap(\.id)))
    if pruned > 0 { log("\(pruned) eski/sahipsiz öğe log'u silindi") }
    rotateLog(paths.home.appending(path: "kervand.log"))
    Task {
        while true {
            try? await Task.sleep(for: .seconds(24 * 3600))
            rotateLog(paths.home.appending(path: "kervand.log"))
        }
    }
    let settings = SettingsStore(paths: paths) { new in
        await engine.updateLimits(maxParallel: new.maxParallel, maxPerHost: new.maxPerHost)
    }
    await engine.updateLimits(maxParallel: settings.value.maxParallel, maxPerHost: settings.value.maxPerHost)
    await engine.start()
    let updater = AutoUpdater(engine: engine, settings: settings, paths: paths)
    let server = try IPCServer(path: paths.socket, engine: engine, settings: settings, updater: { try await updater.runNow() })
    server.start()
    updater.start()
    log("kervand \(kervanVersion) hazır: \(paths.socket.path)")

    let notifier = Notifier()
    await notifier.start(engine: engine)

    // SIGTERM (launchd durdurma) / SIGINT (Ctrl-C): çalışan indirmeleri kuyruğa geri koy, temiz çık.
    var sources: [DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            log("sinyal \(signalNumber); kapanıyor")
            Task {
                await engine.stop()
                unlink(paths.socket.path)
                exit(0)
            }
        }
        source.resume()
        sources.append(source)
    }

    while true { try await Task.sleep(for: .seconds(3600)) }
} catch {
    log("başlatılamadı: \(error)")
    exit(1)
}
