import Foundation
import KervanIPC

// Brave/Chrome Native Messaging köprüsü: tarayıcı bu programı eklenti başına başlatır,
// stdin'den 4 bayt uzunluk (yerel bayt sırası) + JSON okur, aynı biçimde yanıt yazar.
// İstekler kervand soketine iletilir. Köprüyü yalnız manifest'teki eklenti kimliği çağırabilir
// (`allowed_origins`). `subscribe` (popup'ın kalıcı bağlantısı, `connectNative`) bağlantı açık kaldıkça
// kuyruk değişikliklerini akıtır.
// Eklenti web sayfası bağlamında çalıştığı için istekler daraltılır: klasör ve ayar verilemez, çerez yalnız
// kullanıcının açık onayıyla ("fallback"), yerel ağ adresleri servis tarafında reddedilir (`fromExtension`).

let allowed: Set<Request.Command> = [
    .ping, .add, .list, .log, .pause, .resume, .cancel, .retry, .remove, .reveal, .formats, .settings, .subscribe, .clean,
]
var subscribed = false

while let message = Browser.readMessage() {
    guard var request = try? JSONDecoder().decode(Request.self, from: message) else {
        Browser.write(.failure("Geçersiz istek."))
        continue
    }
    guard allowed.contains(request.cmd) else {
        Browser.write(.failure("Eklentiden bu komut kullanılamaz: \(request.cmd.rawValue)"))
        continue
    }
    if request.cmd == .subscribe {
        if subscribed { Browser.write(Response(ok: true)) } else {
            subscribed = true
            Browser.subscribe()
        }
        continue
    }
    request.fromExtension = true
    request.dir = nil
    request.settings = nil
    request.cookies = request.cookies == "fallback" ? "fallback" : "none"
    do {
        Browser.write(try IPCClient().request(request))
    } catch {
        Browser.write(.failure("kervand çalışmıyor. Terminalde: kervan service install"))
    }
}
