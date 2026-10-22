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

do {
    try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    if let version = IPCClient.ping(paths: paths) {
        log("kervand zaten çalışıyor (\(version)); çıkılıyor.")
        exit(0)
    }

    ChildRegistry.configure(file: paths.children)
    let reaped = ChildRegistry.reapOrphans()
    if !reaped.isEmpty { log("önceki çalışmadan kalan \(reaped.count) süreç durduruldu: \(reaped)") }

    let executor = try EngineExecutor(locator: ToolLocator())
    let engine = try QueueEngine(store: ItemStore(path: paths.database), executor: executor,
                                 resolver: executor.resolver, logs: LogStore(directory: paths.logs))
    await engine.start()
    let server = try IPCServer(path: paths.socket, engine: engine)
    server.start()
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
