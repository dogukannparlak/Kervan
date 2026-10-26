import Foundation
import KervanIPC

/// Tarayıcıyla Native Messaging: 4 bayt uzunluk (yerel bayt sırası) + JSON. Abonelik iş parçacığı ile
/// ana döngü aynı anda yazabildiği için yazma kilitlidir.
enum Browser {
    private static let writeLock = NSLock()

    static func readMessage() -> Data? {
        let input = FileHandle.standardInput
        guard let header = try? input.read(upToCount: 4), header.count == 4 else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length > 0, length < 4 * 1024 * 1024 else { return nil }
        guard let body = try? input.read(upToCount: Int(length)), body.count == Int(length) else { return nil }
        return body
    }

    static func write(_ response: Response) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var body = try? encoder.encode(response) else { return }
        // Tarayıcıya giden mesaj en fazla 1 MB olabilir; uzun listeyi kırp.
        if body.count > 1_000_000, var items = response.items {
            items = Array(items.suffix(200))
            var trimmed = response
            trimmed.items = items
            body = (try? encoder.encode(trimmed)) ?? body
        }
        var length = UInt32(body.count)
        let header = Data(bytes: &length, count: 4)
        writeLock.withLock {
            FileHandle.standardOutput.write(header)
            FileHandle.standardOutput.write(body)
        }
    }

    /// Kuyruk değişikliklerini tarayıcıya akıtır (popup açıkken). Abonelik kurulana kadar bekler: ardından
    /// gelen `list` yanıtı abonelikten sonraki durumu gösterir, arada değişiklik kaçmaz.
    static func subscribe() {
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do {
                let events = try IPCClient()
                let ack = try events.request(Request(cmd: .subscribe))
                write(ack)
                ready.signal()
                guard ack.ok else { return }
                while true { write(try events.nextEvent()) }
            } catch {
                write(.failure("kervand bağlantısı koptu. Terminalde: kervan service status"))
                ready.signal()
            }
        }
        ready.wait()
    }
}
