import AppKit
import EngineCore
import Foundation
import KervanIPC
import Observation
import QueueKit

/// Uygulamanın kervand'a bakan yüzü. Kuyruğun sahibi servistir; burası yalnız gösterir ve komut gönderir.
/// Abonelik ayrı bir iş parçacığında bloklayarak okunur, bağlantı koparsa 2 sn'de bir yeniden denenir.
/// Önce abone olunur, sonra liste alınır: arada olan değişiklik kaçmaz. Olaylar ana kuyruğa sırayla
/// (`DispatchQueue.main`, FIFO) verilir; liste en önce uygulanır, ardından bekleyen olaylar.
@MainActor @Observable
final class QueueStore {
    private(set) var items: [Int64: DownloadItem] = [:]
    private(set) var connected = false
    private(set) var version: String?
    var settings = KervanSettings()
    private(set) var updateState = UpdateState()
    var message: String?
    /// Pencerede ekleme sayfasıyla açılacak link (pano/menü çubuğundan gelen çok videolu sayfa).
    var pendingAdd: String?

    var sorted: [DownloadItem] { items.values.sorted { ($0.id ?? 0) > ($1.id ?? 0) } }
    var active: [DownloadItem] { sorted.filter { $0.kind != .group && $0.state.isActive } }
    var totalSpeed: Double { active.compactMap(\.speed).reduce(0, +) }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Thread.detachNewThread { [weak self] in
            let store = self
            while true {
                do {
                    let events = try IPCClient()
                    guard try events.request(Request(cmd: .subscribe)).ok else { throw SocketError.disconnected }
                    // Ayrı, kısa ömürlü bağlantı: yanıtlar abonelik olaylarına karışmasın; iş bitince kapanır.
                    let (list, settings, version) = try {
                        let client = try IPCClient()
                        return (try client.request(Request(cmd: .list)), try client.request(Request(cmd: .settings)),
                                try client.request(Request(cmd: .ping)).version)
                    }()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { store?.connectedWith(list.items ?? [], settings: settings, version: version) }
                    }
                    while true {
                        let event = try events.nextEvent()
                        DispatchQueue.main.async { MainActor.assumeIsolated { store?.apply(event) } }
                    }
                } catch {
                    DispatchQueue.main.async { MainActor.assumeIsolated { store?.connected = false } }
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private func connectedWith(_ list: [DownloadItem], settings response: Response, version: String?) {
        items = Dictionary(uniqueKeysWithValues: list.compactMap { item in item.id.map { ($0, item) } })
        if let settings = response.settings { self.settings = settings }
        if let update = response.update { updateState = update }
        self.version = version
        connected = true
    }

    private func apply(_ event: Response) {
        for item in event.items ?? [] {
            if let id = item.id { items[id] = item }
        }
        event.removed?.forEach { items[$0] = nil }
    }

    func children(of group: DownloadItem) -> [DownloadItem] {
        items.values.filter { $0.parentId == group.id }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    // MARK: - Komutlar (ana iş parçacığını bloklamadan)

    func send(_ request: Request) async -> Response {
        await Task.detached {
            do {
                return try IPCClient().request(request)
            } catch {
                return Response.failure("kervand çalışmıyor: \(error)")
            }
        }.value
    }

    func perform(_ cmd: Request.Command, ids: [Int64]) async {
        guard !ids.isEmpty else { return }
        let response = await send(Request(cmd: cmd, ids: ids))
        if !response.ok { message = response.error }
    }

    func saveSettings() async {
        let response = await send(Request(cmd: .setSettings, settings: settings))
        if let saved = response.settings { settings = saved } else { message = response.error }
    }

    func updateYtDlp() async {
        message = "yt-dlp güncelleniyor…"
        let response = await send(Request(cmd: .update))
        if let update = response.update { updateState = update }
        message = response.ok ? response.update?.lastResult : response.error
    }

    /// Bitmiş dosyayı açar; yoksa Finder'da gösterir.
    func open(_ item: DownloadItem) {
        guard let path = item.outputPath, FileManager.default.fileExists(atPath: path) else {
            if item.state == .done { message = "Dosya bulunamadı (taşınmış ya da silinmiş olabilir)." }
            return
        }
        NSWorkspace.shared.open(URL(filePath: path))
    }

    func reveal(_ item: DownloadItem) {
        guard let path = item.outputPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    /// Servis kurulu ama çalışmıyorsa launchd'ye başlat der.
    func startService() {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(KervanPaths.launchAgentLabel)"]
        try? process.run()
    }
}

extension DownloadItem {
    var displayTitle: String { title ?? url }

    var sizeText: String {
        if let total = bytesTotal ?? bytesTotalEstimate { return (bytesTotal == nil ? "~" : "") + Format.bytes(total) }
        return bytesDone > 0 ? Format.bytes(bytesDone) : ""
    }

    var speedText: String {
        guard state == .downloading, let speed, speed > 0 else { return "" }
        return Format.bytes(Int64(speed)) + "/s"
    }

    var etaText: String {
        guard state == .downloading, let eta else { return "" }
        return Format.duration(eta)
    }

    /// Duruma göre kullanılabilir eylemler (popup ile aynı mantık).
    var actions: [Request.Command] {
        switch state {
        case .queued, .downloading: [.pause, .cancel]
        case .postprocessing: [.cancel]
        case .paused: [.resume, .cancel]
        case .failed, .canceled: [.retry, .remove]
        case .done: [.reveal, .remove]
        }
    }
}

extension Request.Command {
    /// İnen ya da işlenen öğeyi iptal etmek/silmek onay ister: yarım iş kaybolur.
    func needsConfirmation(for targets: [DownloadItem]) -> Bool {
        (self == .cancel || self == .remove) && targets.contains { $0.state.isActive }
    }

    var title: String {
        switch self {
        case .pause: "Durdur"
        case .resume: "Devam"
        case .cancel: "İptal"
        case .retry: "Yeniden dene"
        case .remove: "Listeden sil"
        case .reveal: "Klasörde göster"
        default: rawValue
        }
    }

    var symbol: String {
        switch self {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .cancel: "xmark"
        case .retry: "arrow.clockwise"
        case .remove: "trash"
        case .reveal: "folder"
        default: "questionmark"
        }
    }
}
