# Kervan — Yol Haritası

> Her aşama tek oturumda bitirilebilecek küçüklükte tutuldu. "Bitti kriteri" bölümleri,
> aşamayı kutlamanın ötesinde — işlendikten sonra bile objektif olarak test edilebilecek
> göstergeler içerir.

## M0 — Plan & Mimari ✅ (şu an buradayız)
- README, ARCHITECTURE, ROADMAP yazıldı
- klasör iskeleti kuruldu (kod yok)
- bağımlılık envanteri: yt-dlp ✅ · aria2 ✅ · ffmpeg ❌ (M6'da)

## M1 — kervan-cli MVP
Amaç: motoru GUI olmadan test etmek — CLI hızlıdır, hatalar görünürdür, iterasyon ucuzdur.
- Swift Package (engine/) kurulur: ProcessRunner + YtDlpAdapter (probe/download)
- komutlar: `kervan add <url> [--preset 1080p]`, `kervan list`, `kervan watch <id>`
- tek indirme Sekansı: metadata → format seçimi → indirme → ProgressEvent akışı
- klasik HTTP linki → Aria2Adapter'a yönlendirme (URLClassifier v0)
- `resources/presets/*.json` ilk doldurma (best / 1080p / 720p-safe / audio)
- scripts/: `install-deps.sh` (yt-dlp/aria2 kontrol + `brew upgrade`),
  `run-cli.sh` (debug koşumu)

**Bitti kriteri:** terminalden bir YouTube videosu 1080p hedefiyle iner; ilerleme
satırı saniyede birkaç kez güncellenir; düz bir HTTP zip linki aria2 ile iner.

## M2 — Kuyruk Zaferi
Amaç: "şu an 12 şey iniyor" hâlini güvenilir kılmak.
- QueueKit: SQLite (GRDB) kalıcılığı — uygulama restart'ı atlatır
- state machine: pause/resume/cancel/retry + exponential backoff
- eşzamanlılık: maxParallel=3 + site başına yumuşatma (aynı siteye eşzamanlı script)
- playlist: `--flat-playlist` → her giriş ayrı kuyruk öğesi (çocuk-ata bağlantısı)
- log ring buffer + `kervan log <id>`

**Bitti kriteri:** 5 öğeli kuyruk indirilirken uygulama kapatılır; yeniden açılışta
3. öğe kaldığı yerden devam eder; başarısız bir öğe 3 deneme sonrası `failed` olur
ve elle yeniden kuyruklanabilir.

## M3 — SwiftUI App MVP
Amaç: CLI'daki her şey pencereye, renkli ve çubuklu girer.
- macOS app hedefi (Kervan.app) — engine paketine Consumer olur; UI-only katman
- ekranlar: AddSheet (URL + preset + hedef klasör), QueueList (satır: başlık, bar,
  hız, ETA, butonlar), DetailSheet (log izleyicisi), Settings (limitler, klasörler)
- uygulama yaşam döngüsü: pencere kapansa da kuyruk sürsün (dock'ya devam)

**Bitti kriteri:** hiç terminal kullanmadan bir video CLI'sız indirilir; kuyruk
Pause/Resume düğmelerinden yönetilir.

## M4 — UX Cila
- macOS bildirimleri (tamamlanınca), Dock badge (eşzamanlı sayı veya toplam %)
- ClipboardWatcher: panoya link kopyalanınca "Link algılandı → ekle?" çıkarımı
  + yok sayma listesi (github.com, docs siteleri…)
- sürükle-bırak: Finder'dan ve tarayıcıdan link bırakma
- indirme klasörü seçici (Security-scoped bookmark ile kalıcı erişim)

**Bitti kriteri:** linki kopyala → panoyu sezerek çıkan öneriyle 3 saniyede
kuyruğa düşer; tamamlanınca macOS bildirimi gelir; dock ikonunda yüzde görünür.

## M5 — "Her şey" (kapsam sözünün tamamlanması)
- çerez taşıma: Safari önce (keychain onay akışı), sonra Firefox; Chrome için
  cookie-dosyası (Netscape formatı) yolu + README notu (Chrome 127+ kısıtı)
- altyazı: `--write-subs --sub-langs tr,en` varsayılan; preset'te seçilebilir
- playlist UX: grup başlıkları, "x/45 indirildi" göstergesi, sadece başarızları tekrar
- doğrudan HTTP: referer/User-Agent değerleri, yönlendirmeleri destekleme

**Bitti kriteri:** üyelik gerektiren bir içerik, çerez taşıma ile iner; altyazılı
bir video inip altyazı dosyası hedef klasörde görünür.

## M6 — ffmpeg Postprocess
- `brew install ffmpeg` — `scripts/install-deps.sh` içine eklenir
- birleştirme (remux — transcode yok, hızlı ve kalite kayıpsız):
  4K/best preset tek dosyaya toparlanır
- audio preset tamamlanır: mp3/m4a çıkışı + metadata/kapak gömme
- preset fallback zincirleri güncellenir ("ffmpeg'li dünya" hâline)

**Bitti kriteri:** 4K video tek mkv/mp4 dosyası olarak iner; bir video mp3'e
dönüşür ve id3 etiketleri doludur.

## M7 — Tarayıcı Uzantısı & Dağıtım
- Safari Web Extension: sayfa bağlam menüsü "Kervan'a gönder" + toolbar butonu
- `kervan://add?url=...` custom URL scheme (uzantı → uygulama köprüsü)
- dağıtım: dmg + codesign + notarization; updater (örn. Sparkle) kararı
- ilk kullanıcı dokümanı: kurulum, ilk indirme, çerez notları

**Bitti kriteri:** Safari'de açık sayfadan tek tıkla Kervan kuyruğuna madde düşer;
dağıtılan dmg başka bir Mac'te sorunsuz kurulup çalışır.

---

## Zaman resmi (tek geliştirici için kabaca)
M1 · 1–2 hafta → M2 · 1 hafta → M3 · 1–1,5 hafta → M4 · 3–4 gün →
M5 · 1 hafta → M6 · 2–3 gün → M7 · 1 hafta ≈ **toplam 6–8 hafta**.

Kural: her aşama **çalışan bir araç** bırakır — hiçbir aşamada "yıllardır
mekik dokuyorum ama çalışan bir şey yok" hâli yaşanmaz.
