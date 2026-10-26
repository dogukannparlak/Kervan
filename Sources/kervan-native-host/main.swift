import Foundation
import KervanIPC

// Brave/Chrome Native Messaging köprüsü: tarayıcı bu programı eklenti başına başlatır,
// stdin'den 4 bayt uzunluk (yerel bayt sırası) + JSON okur, aynı biçimde yanıt yazar.
// İstekler kervand soketine iletilir. Köprüyü yalnız manifest'teki eklenti kimliği çağırabilir
// (`allowed_origins`); akış isteyen `subscribe` dışındaki komutlar açıktır.
// Eklenti web sayfası bağlamında çalıştığı için istekler daraltılır: klasör ve ayar verilemez, çerez yalnız
// kullanıcının açık onayıyla ("fallback"), yerel ağ adresleri servis tarafında reddedilir (`fromExtension`).

let allowed: Set<Request.Command> = [.ping, .add, .list, .log, .pause, .resume, .cancel, .retry, .remove, .reveal, .formats, .settings]
let input = FileHandle.standardInput
let output = FileHandle.standardOutput

func readMessage() -> Data? {
    guard let header = try? input.read(upToCount: 4), header.count == 4 else { return nil }
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    guard length > 0, length < 4 * 1024 * 1024 else { return nil }
    guard let body = try? input.read(upToCount: Int(length)), body.count == Int(length) else { return nil }
    return body
}

func write(_ response: Response) {
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
    output.write(Data(bytes: &length, count: 4))
    output.write(body)
}

while let message = readMessage() {
    guard var request = try? JSONDecoder().decode(Request.self, from: message) else {
        write(.failure("Geçersiz istek."))
        continue
    }
    guard allowed.contains(request.cmd) else {
        write(.failure("Eklentiden bu komut kullanılamaz: \(request.cmd.rawValue)"))
        continue
    }
    request.fromExtension = true
    request.dir = nil
    request.settings = nil
    request.cookies = request.cookies == "fallback" ? "fallback" : "none"
    do {
        write(try IPCClient().request(request))
    } catch {
        write(.failure("kervand çalışmıyor. Terminalde: kervan service install"))
    }
}
