# Kervan — Yapılacaklar

> Doğukan'ın 2026-10-23 kararı: aşağıdaki tur "daha sonra" yapılacak. Sıra önerilen sıradır.
> Bir madde bitince `[x]` yap, kısa sonuç ve commit'i yaz. Ayrıntılı geçmiş: `docs/ROADMAP.md`.

## 0. Önce: menü çubuğu simgesinin görünmesi

- [ ] Doğukan'ın Mac'inde simge görünmüyor. Öğe var (Accessibility'de "status menu"), ama Thaw ya da
  çentik gizliyor olabilir. 5. madde Dock'u kaldıracağı için menü çubuğu tek giriş olacak; önce bu çözülmeli.
  - Kontrol: `osascript -e 'tell application "System Events" to tell process "KervanApp" to get description of every menu bar item of menu bar 2'`

## Sonraki tur (1–5)

- [ ] **1. İptal/silmede yarım dosyaları temizle**
  - Sorun: iptal edilen öğe klasörde `.part`, `.ytdl`, `*.part-Frag*.part` bırakıyor (ör. "Joker…" indirmesi).
  - Nasıl: `QueueEngine.perform(.cancel/.remove)` sonrasında, öğenin `destination`'ında `filename`
    (ya da yt-dlp'nin çıktı adı) ile başlayan yarım dosyaları sil. Kesin adı bilmek için yt-dlp'ye
    `--print "before_dl:KERVAN_PATH|%(filename)s"` eklenip öğeye `partialPath` olarak kaydedilebilir.
  - Arayüz: iptal/silmede "yarım dosyaları da sil" seçeneği (CLI `--purge`, popup ve uygulamada onay).
  - Test: sahte klasörde `.part` dosyası oluştur → iptal → silindi mi.

- [ ] **2. Aynı linki tekrar ekleme uyarısı + temizlik**
  - Kuyrukta ya da bitenlerde aynı URL (ya da aynı yt-dlp `id`) varsa `add` yanıtı uyarı dönsün:
    "zaten indirildi (#12), yine de?" → istemci `force: true` ile yeniden gönderir.
  - "Bitenleri temizle": `done` ve `canceled` öğeleri kuyruktan siler (dosyalara dokunmaz). CLI `kervan clean`,
    uygulama araç çubuğu, popup.
  - Log temizliği: servis açılışında 30 günden eski `logs/<id>.log` ve kuyrukta olmayan logları siler;
    `kervand.log` 5 MB'ı geçince döndürülür.

- [ ] **3. Boyut ve yüzde gösterimi**
  - Doğukan: "sadece videonun boyutunu yazsın ve inerken yüzdede göstersin" (disk alanı uyarısı istenmedi;
    bu yorum Doğukan'la teyit edilecek).
  - Nasıl: `add` sırasında kalite listesindeki tahmini boyut (`QualityPlanner`) öğeye `bytesTotalEstimate`
    olarak yazılsın; böylece öğe "sırada" iken de boyut görünür. İnerken yüzde zaten var; yüzde olmayan
    durumları (mp3 dönüşümü, boyutu bilinmeyen HLS) gözden geçir.

- [ ] **4. Türkçe hata mesajları + öneri**
  - yt-dlp/aria2 ham hatalarını (`ERROR: Video unavailable`, `HTTP Error 403`, `Sign in to confirm…`)
    Türkçe ve önerili metne çeviren bir eşleme: `QueueKit/ErrorText.swift` (testli).
  - Örnekler: "Video kaldırılmış ya da gizli", "Site giriş istiyor: Brave'de giriş yap",
    "Erişim reddedildi (403): sayfayı yenileyip eklentiden tekrar gönder".
  - Ham hata `kervan log <id>`'de kalsın.

- [ ] **5. Dock'ta görünmesin, yalnız menü çubuğu**
  - 297d503'teki Dock değişikliğini geri al: `AppCommand` → `AppBundle.build(..., dock: false)` (LSUIElement).
  - Pencere yine Kervan.app'e tıklanınca ve menüden "Pencereyi aç" ile açılsın (`applicationShouldHandleReopen`).
  - Dock rozeti bu yüzden düştü.
  - Açık deneme: bildirimi servis yerine uygulama UserNotifications ile gönderirse macOS izin veriyor mu?
    (servis paketinde vermedi, bkz. ARCHITECTURE 4c). İzin verirse bildirime tıklayınca dosya açılır.

## Daha sonra

- [ ] Hız sınırı ve zamanlayıcı (aria2 canlı, yt-dlp `--limit-rate` + `.part`'tan yeniden başlatma; `pmset sleepnow`)
- [ ] Sürükle-bırak ile ekleme (pencere ve menü çubuğu)
- [ ] Pano izlemede "bu siteyi önerme" listesi
- [ ] Tarayıcı indirmelerini yakalama (eklentiye `downloads` izni)
- [ ] Video indirmede paralel parça (`-N 4`), etkisi ölçülerek
- [ ] İnen dosyalara macOS karantina etiketi (Gatekeeper kontrolü)
- [ ] GitHub Actions: her push'ta `swift test` + `node --test extension/test/`
- [ ] Firefox/Safari çerezlerini dene, `cookies.txt` içe aktarma, elle User-Agent
- [ ] M7 dağıtım: dmg + codesign + notarization (Apple Developer hesabı Doğukan'da)
