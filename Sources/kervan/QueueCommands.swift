import ArgumentParser
import Foundation
import KervanIPC
import QueueKit

/// Servise bağlanır; çalışmıyorsa ne yapılacağını söyler.
func connect() throws -> IPCClient {
    setvbuf(stdout, nil, _IOLBF, 0)
    do {
        return try IPCClient()
    } catch {
        throw CLIError("kervand çalışmıyor. Kur ve başlat: kervan service install\n(ya da ön planda dene: swift run kervand)")
    }
}

@discardableResult
func send(_ request: Request, with client: IPCClient? = nil) throws -> Response {
    let response = try (client ?? connect()).request(request)
    guard response.ok else { throw CLIError(response.error ?? "bilinmeyen hata") }
    return response
}

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Linki kuyruğa ekler (servis indirir).")

    @Argument(help: "Bir ya da daha çok link.")
    var urls: [String]

    @OptionGroup var options: DownloadOptions

    @Flag(name: .shortAndLong, help: "Ekledikten sonra bitene kadar izle.")
    var watch = false

    func run() throws {
        _ = try options.validatedPreset()
        let client = try connect()
        var added: [Int64] = []
        for text in urls {
            let url = try parseURL(text)
            let response = try send(Request(cmd: .add, url: url.absoluteString, preset: options.preset, dir: options.directory.path,
                                            cookies: options.cookies, items: options.selection, referer: options.referer,
                                            title: options.name), with: client)
            response.notes?.forEach { print("→ \($0)") }
            if let entries = response.entries {
                printSelectionHint(title: response.title, entries: entries)
                continue
            }
            for item in response.items ?? [] {
                print("+ #\(item.id ?? 0)\(item.parentId == nil ? "" : "  ") \(item.title ?? item.url)")
                if let id = item.id { added.append(id) }
            }
        }
        if watch && !added.isEmpty { try QueueWatcher(ids: Set(added)).run() }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Kuyruğu listeler.", aliases: ["ls"])

    @Flag(help: "Bitmiş ve iptal edilmişleri de göster.")
    var all = false

    func run() throws {
        let items = try send(Request(cmd: .list)).items ?? []
        let shown = all ? items : items.filter { $0.state != .done && $0.state != .canceled || $0.finishedAt.map { -$0.timeIntervalSinceNow < 3600 } == true }
        if shown.isEmpty {
            print(items.isEmpty ? "Kuyruk boş." : "Etkin öğe yok (hepsi: kervan list --all).")
            return
        }
        QueueTable.print(shown)
    }
}

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Kuyruğu canlı izler (Ctrl-C ile çık).")

    @Argument(help: "Yalnız bu öğeler; verilirse hepsi bitince çıkar.")
    var ids: [Int64] = []

    func run() throws {
        try QueueWatcher(ids: ids.isEmpty ? nil : Set(ids)).run()
    }
}

/// pause/resume/cancel/retry/remove için ortak gövde.
protocol ItemActionCommand: ParsableCommand {
    static var command: Request.Command { get }
    static var verb: String { get }
    var ids: [Int64] { get }
}

extension ItemActionCommand {
    func run() throws {
        let items = try send(Request(cmd: Self.command, ids: ids)).items ?? []
        // Çalışan süreç birkaç saniyede durur; o yüzden anlık durum değil, istenen eylem yazılır.
        if Self.command == .remove {
            print("\(Self.verb): \(ids.map { "#\($0)" }.joined(separator: " "))")
        } else {
            items.forEach { print("\(Self.verb): #\($0.id ?? 0) \($0.title ?? $0.url)") }
        }
    }
}

struct Pause: ItemActionCommand {
    static let configuration = CommandConfiguration(abstract: "Duraklatır (devamı .part dosyasından).")
    static let command = Request.Command.pause
    static let verb = "duraklatıldı"
    @Argument var ids: [Int64]
}

struct Resume: ItemActionCommand {
    static let configuration = CommandConfiguration(abstract: "Duraklatılanı kuyruğa geri koyar.")
    static let command = Request.Command.resume
    static let verb = "devam"
    @Argument var ids: [Int64]
}

struct Cancel: ItemActionCommand {
    static let configuration = CommandConfiguration(abstract: "İptal eder (inen parça diskte kalır).")
    static let command = Request.Command.cancel
    static let verb = "iptal"
    @Argument var ids: [Int64]
}

struct Retry: ItemActionCommand {
    static let configuration = CommandConfiguration(abstract: "Hatalı ya da iptal edilmiş öğeyi yeniden kuyruğa alır.")
    static let command = Request.Command.retry
    static let verb = "yeniden"
    @Argument var ids: [Int64]
}

struct Remove: ItemActionCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Kuyruktan siler (indirilen dosyaya dokunmaz).",
                                                    aliases: ["rm"])
    static let command = Request.Command.remove
    static let verb = "silindi"
    @Argument var ids: [Int64]
}

struct Reveal: ItemActionCommand {
    static let configuration = CommandConfiguration(abstract: "Bitmiş dosyayı Finder'da gösterir.")
    static let command = Request.Command.reveal
    static let verb = "Finder'da"
    @Argument var ids: [Int64]
}

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Bir öğenin araç log'unu gösterir.")

    @Argument var id: Int64

    @Option(name: [.customShort("n"), .long], help: "Son kaç satır.")
    var lines = 50

    func run() throws {
        let item = try send(Request(cmd: .list)).items?.first { $0.id == id }
        if let error = item?.lastError { print("son hata: \(error)\n") }
        (try send(Request(cmd: .log, ids: [id], lines: lines)).log ?? []).forEach { print($0) }
    }
}

/// Servisten olay akışını alıp tabloyu yeniden çizer.
struct QueueWatcher {
    /// nil → bütün kuyruk, Ctrl-C'ye kadar.
    let ids: Set<Int64>?

    func run() throws {
        let client = try connect()
        var items: [Int64: DownloadItem] = [:]
        for item in try send(Request(cmd: .list), with: client).items ?? [] {
            if let id = item.id, ids == nil || ids!.contains(id) || ids!.contains(item.parentId ?? -1) { items[id] = item }
        }
        let interactive = isatty(STDOUT_FILENO) == 1
        var lastDraw = ContinuousClock.now - .seconds(10)
        var drawnLines = 0

        func draw(force: Bool) {
            let now = ContinuousClock.now
            guard force || now - lastDraw >= (interactive ? .milliseconds(300) : .seconds(3)) else { return }
            lastDraw = now
            let visible = items.values.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
                .filter { ids != nil || !$0.state.isFinished || $0.finishedAt.map { -$0.timeIntervalSinceNow < 600 } == true }
            let lines = QueueTable.lines(visible)
            if interactive && drawnLines > 0 { Swift.print("\u{1B}[\(drawnLines)A\u{1B}[J", terminator: "") }
            lines.forEach { Swift.print($0) }
            if !interactive { Swift.print("") }
            drawnLines = lines.count
        }

        func finished() -> Bool {
            guard let ids else { return false }
            return ids.allSatisfy { id in items[id].map { $0.kind == .group || $0.state.isFinished } ?? true }
                && items.values.filter { $0.kind != .group }.allSatisfy { $0.state.isFinished || $0.state == .paused }
        }

        draw(force: true)
        if finished() { return }
        try client.subscribe { event in
            for item in event.items ?? [] {
                guard let id = item.id, ids == nil || ids!.contains(id) || ids!.contains(item.parentId ?? -1) else { continue }
                items[id] = item
            }
            event.removed?.forEach { items[$0] = nil }
            let done = finished()
            draw(force: done)
            return !done
        }
    }
}

enum QueueTable {
    static func label(_ state: ItemState) -> String {
        switch state {
        case .queued: "sırada"
        case .downloading: "iniyor"
        case .postprocessing: "işleniyor"
        case .paused: "duraklatıldı"
        case .failed: "hata"
        case .canceled: "iptal"
        case .done: "bitti"
        }
    }

    static func print(_ items: [DownloadItem]) {
        lines(items).forEach { Swift.print($0) }
    }

    static func lines(_ items: [DownloadItem]) -> [String] {
        let width = (try? terminalWidth()) ?? 100
        return items.map { item in
            let indent = item.parentId == nil ? "" : "  "
            let id = "\(indent)#\(item.id ?? 0)".padding(toLength: 6, withPad: " ", startingAt: 0)
            let state = label(item.state).padding(toLength: 12, withPad: " ", startingAt: 0)
            let percent = item.fraction.map { String(format: "%5.1f%%", $0 * 100) } ?? "     -"
            let size = item.kind == .group ? "" : (item.bytesTotal ?? item.bytesTotalEstimate).map { Format.bytes($0) } ?? Format.bytes(item.bytesDone)
            var extra: [String] = []
            if let speed = item.speed, speed > 0 { extra.append(Format.bytes(Int64(speed)) + "/s") }
            if let eta = item.eta, item.state == .downloading { extra.append("kalan \(Format.duration(eta))") }
            if let message = item.message { extra.append(message) }
            if item.state == .failed, let error = item.lastError { extra.append(error.replacingOccurrences(of: "\n", with: " ")) }
            let head = "\(id) \(state) \(percent)  \(size.padding(toLength: 9, withPad: " ", startingAt: 0))  "
            let tail = ([item.title ?? item.url] + extra).joined(separator: "  ·  ")
            return String((head + tail).prefix(width))
        }
    }

    private static func terminalWidth() throws -> Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 20 else { return 100 }
        return Int(size.ws_col)
    }
}
