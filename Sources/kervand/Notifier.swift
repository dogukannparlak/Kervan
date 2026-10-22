import Foundation
import QueueKit

/// İndirme bitince ya da kalıcı hata verince macOS bildirimi gösterir (`osascript display notification`).
///
/// Neden UserNotifications değil: 2026-10-23'te macOS 27'de servis paketi (ad-hoc ya da Apple Development
/// imzalı, launchd ya da `open` ile başlatılmış, NSApplication kayıtlı) her durumda
/// "Notifications are not allowed for this application" (UNErrorDomain 1) aldı; izin penceresi hiç çıkmadı.
/// Bu yolun bedeli: bildirime tıklayınca dosya açılmaz; "Klasörde göster" eklenti penceresinde.
/// Playlist çocukları tek tek değil, grup bitince bir kez bildirilir.
final class Notifier: Sendable {
    func start(engine: QueueEngine) async {
        // Açılışta bitmiş olanlar yeniden bildirilmesin diye başlangıç durumları alınır.
        var states: [Int64: ItemState] = [:]
        for item in await engine.list() { if let id = item.id { states[id] = item.state } }
        let events = await engine.subscribe()
        Task {
            for await event in events {
                switch event {
                case .updated(let item):
                    guard let id = item.id else { continue }
                    let previous = states[id]
                    states[id] = item.state
                    if let message = item.notification(previous: previous) { Self.show(message) }
                case .removed(let id):
                    states[id] = nil
                }
            }
        }
    }

    static func show(_ message: (title: String, body: String)) {
        func quoted(_ text: String) -> String {
            "\"" + String(text.prefix(220)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(message.body)) with title \(quoted(message.title)) sound name \"Glass\""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
