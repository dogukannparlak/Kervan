import EngineCore
import Foundation

/// yt-dlp/aria2 hatalarını kullanıcıya gösterilecek Türkçe, önerili metne çevirir (uygulama, eklenti, bildirim).
/// Ham hata kaybolmaz: öğe log'una (`kervan log <id>`) ve yanıtın `detail` alanına yazılır.
public enum ErrorText {
    public static func friendly(_ error: Error) -> String {
        switch error {
        case EngineError.loginRequired(let browser, _):
            return "\(browser) çerezleriyle de giriş istendi: \(browser)'da bu siteye giriş yapıp yeniden dene."
        case EngineError.toolFailed(_, _, let message):
            return friendly(message: message) ?? String(describing: error)
        default:
            return String(describing: error)
        }
    }

    /// Çevrilmiş metin ham hatadan farklıysa ham hata (ayrıntı olarak gösterilir); değilse nil.
    public static func detail(_ error: Error) -> String? {
        let raw = String(describing: error)
        return raw == friendly(error) ? nil : raw
    }

    /// Bilinen kalıplar, sırayla: ilk eşleşen kazanır (özel olan genelden önce). Bilinmeyense nil.
    static func friendly(message: String) -> String? {
        let text = message.lowercased()
        return rules.first { rule in rule.0.contains { text.contains($0) } }?.1
    }

    static let rules: [([String], String)] = [
        (["requested format is not available", "requested format not available"],
         "Seçilen kalite bu videoda yok: başka bir kalite seç."),
        (["confirm your age", "age-restricted", "age restricted"],
         "Yaş sınırlı video: tarayıcıda bu siteye giriş yapıp yeniden dene."),
        (["not a bot"],
         "Site bot denetimi istiyor: tarayıcıda bu siteye giriş yapıp tarayıcı çerezleriyle yeniden dene."),
        (["private video", "video is private"],
         "Video gizli: yalnız sahibi ve izin verdiği hesaplar görebilir."),
        (["members-only", "join this channel"],
         "Video yalnız kanal üyelerine açık: üye hesapla tarayıcıda giriş yapıp yeniden dene."),
        (["available in your country", "geo restrict", "geo-restrict", "geoblock"],
         "Video bu ülkede yayınlanmıyor (bölge kısıtlaması)."),
        (["premieres in", "live event will begin", "this live event"],
         "Yayın henüz başlamadı; başladıktan sonra yeniden dene."),
        (["video unavailable", "video is unavailable", "is not available", "has been removed", "no longer available"],
         "Video kaldırılmış ya da erişime kapalı."),
        (["--cookies", "logged-in", "login required", "log in", "sign in", "authentication"],
         "Site giriş istiyor: tarayıcıda bu siteye giriş yapıp tarayıcı çerezleriyle yeniden dene."),
        (["http error 403", "status=403", "403: forbidden", "403 forbidden"],
         "Erişim reddedildi (403): sayfayı yenileyip eklentiden yeniden gönder."),
        (["http error 404", "status=404", "resource not found"],
         "Dosya bulunamadı (404): link eskimiş olabilir; sayfayı yenileyip yeniden gönder."),
        (["http error 410", "status=410"],
         "Dosya artık sunucuda yok (410)."),
        (["http error 429", "status=429", "too many requests"],
         "Site çok fazla istek dedi (429): biraz bekleyip yeniden dene."),
        (["unsupported url"],
         "Bu site ya da link desteklenmiyor."),
        (["no space left on device"],
         "Diskte yer kalmadı: yer açıp yeniden dene."),
        (["permission denied", "operation not permitted", "read-only file system"],
         "Klasöre yazılamıyor: indirme klasörünü ayarlardan değiştir."),
        (["timed out", "timeout", "connection reset", "connection refused", "network is unreachable",
          "temporary failure in name resolution", "nodename nor servname", "getaddrinfo failed", "name or service not known"],
         "Bağlantı sorunu: internet bağlantını kontrol edip yeniden dene."),
        (["http error 500", "http error 502", "http error 503", "http error 504", "status=5"],
         "Sitenin sunucusu hata verdi: biraz sonra yeniden dene."),
        (["unable to extract", "unable to download webpage", "unable to download json", "extractorerror"],
         "Site değişmiş olabilir: yt-dlp'yi güncelle (Ayarlar → Şimdi güncelle) ve yeniden dene."),
    ]
}
