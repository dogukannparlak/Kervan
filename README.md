# Kervan

> IDM benzeri, **yt-dlp tabanlı**, native macOS indirme yöneticisi.
> **Durum: v0 — sadece plan ve mimari. Hiç kod yazılmadı.**

Kervan, Internet Download Manager'ın macOS'ta yapmadığı şeyi yapar: video sitelerini
(Youtube, Instagram, Twitter/X, VK, Reddit… hepsi — yt-dlp'nin desteklediği her site)
ve doğrudan HTTP linklerini tek bir kuyrukta, eşzamanlı ve devam edilebilir şekilde indirir.

---

## 1. Temel Fikir

Kendimiz download motoru yazmıyoruz. Alanında en iyi iki hazır aracı, arkalarından
**orkestra şefi gibi yöneten bir katman** olarak sarıyoruz:

| Araç | Görev | Durum |
|---|---|---|
| **yt-dlp** | Video siteleri: metadata çıkarma, format seçimi, indirme, fragment-resume | ✅ kurulu (2026.08.19) |
| **aria2c** | Doğrudan HTTP(S) linkleri: 16 bağlantıya paralel, çok hızlı | ✅ kurulu |
| **ffmpeg** | Ses+video birleştirme (1080p+ zorunlu), mp3 çıkarma | ❌ **sonra** (600 MB, istersen ekleyeceğiz) |

Swift/SwiftUI ile native bir macOS uygulaması, bu araçları `Process` (child process)
olarak yönetir. Kuyruk mantığı, state machine ve persistence bizim katmanımızdır.

---

## 2. Mimari (4 Katman)

```
┌─────────────────────────────────────────────────┐
│  Kervan.app (SwiftUI)      ← görsel katman      │
├─────────────────────────────────────────────────┤
│  kervan-cli (Swift)        ← terminal arayüzü   │  ← ikisi de aynı paketi kullanır
├─────────────────────────────────────────────────┤
│  QueueKit (Swift Package)  ← kuyruk, state, disk│
├─────────────────────────────────────────────────┤
│  EngineCore (Swift Package)← ProcessRunner      │
│    ├─ YtDlpAdapter  (video siteleri)            │
│    ├─ Aria2Adapter  (HTTP linkler)              │
│    └─ MergeService  (ffmpeg — sonra)            │
├─────────────────────────────────────────────────┤
│  Eski dünya: yt-dlp · aria2c · ffmpeg           │
└─────────────────────────────────────────────────┘
```

Kural: **QueueKit ve EngineCore GUI'den bağımsızdır.** Önce CLI ile motoru bitiririz
(test etmek kolay), SwiftUI kabuk en son giyilir. Bu sıralama projenin bel kemiğidir.

### Modül dökümü

| Modül | Sorumluluk |
|---|---|
| `ProcessRunner` | Child process başlatma, satır-satır stdout yakalama, temiz sonlandırma (SIGINT → SIGKILL), timeout |
| `YtDlpAdapter` | Metadata sorgusu (`-J`), indirme başlatma (`--newline` + ilerleme şablonu ayrıştırma), ilerleme olayı yayma |
| `Aria2Adapter` | HTTP indirme, `-x16 -s16`, `--continue`, paralel segmentler |
| `MergeService` | (ffmpeg, M6) A/V stream birleştirme, mp3 transcoding |
| `QueueKit` | Kuyruk: **SQLite** (GRDB) tabanlı kalıcı state, state machine, eşzamanlılık politikası, retry/backoff |
| `URLClassifier` | "Bu bir video mu, düz dosya mı?" kararı → hangi adapter |
| `ClipboardWatcher` | `NSPasteboard` değişimini izleme, "Link algılandı → ekle?" çıkarımı |
| `DockBadge` / `Notifier` | Dock'da yüzde, `UNUserNotificationCenter` ile tamamlanma bildirimi |

---

## 3. Veri Akışı (bir indirmenin hayatı)

```
Kullanıcı link yapıştırır (veya panodan algılanır)
        ↓
URLClassifier
        ↓
  yt-dlp keşfi (probe): yt-dlp -J <url>  → JSON metadata
        ↓                                    ↓
   başarılı = VIDEO                    başarısız / video değil = DÜZ HTTP
        ↓                                    ↓
YtDlpAdapter                          Aria2Adapter
  - kalite ön ayarına göre format seçimi - x16 bağlantılı paralel indirme
  - tek process, --newline progress     - --continue ile resume
  - progress-template ayrıştırma        ↓
        ↓                                    ↓
   İlerleme Olayları (hız · ETA · yüzde · fragment)
        ↓
QueueKit (state: queued → probing → downloading → [merging] → done | failed | paused | canceled)
        ↓
~/Downloads/Kervan/ ... + macOS bildirimi + dock güncellemesi
```

### Eşzamanlılık & kuyruk semantiği

- **Varsayılan eşzamanlılık: 3 indirme aynı anda** (ayarlardan 1–10 arasında değiştirilebilir).
- Video siteleri rate-limit yaptığından, aynı siteyi "aynı anda" indirmek yerine
  kuyruğu küçük gecikmelerle doldurmak (“site kuyruğunu yumuşat”) düşünülür.
- **Playlist**: `--flat-playlist -J` ile serialize edilir; her madde tekil kuyruk
  öğesi olur → kolay pause/resume, kolay retry (başarısızlar listesi döner).
- **Resume/pause**: yt-dlp fragment'ları ve `.part` doğal devam eder; aria2 `--continue=true`.
- **Retry**: `--retries 10`, `--fragment-retries 10` + üst seviyede exponential backoff ile
  tüm item'ı yeniden kuyruğa alma.

### Kalite ön ayarları (presets)

| Preset | Açıklama | Hedef çıktı |
|---|---|---|
| `best` | En iyi video+ses kombinasyonu | mkv (upscale dahil, 4K+) |
| `1080p` | En fazla 1080p sesli video | mp4 (birleştirme varsa) |
| `720p-safe` | ffmpeg yokken çalışabilir en yüksek | mp4 / webm |
| `audio` | sadece ses (mp3 → **M6, ffmpeg gerekir**) | m4a/webm şimdi |

preset değerleri **sabit değil veri (config)** olarak `resources/presets/*.json` içinde tutulur;
engine'e parametrik geçer.

---

## 4. "Her şey" sözünü nasıl tutacağız (M5)

Kullanıcı bunu istedi — özellikleri:

1. **Binlerce site**: yt-dlp ekstraktör ekosistemi bizim için bedava işgücüdür.
   Instagram, Twitter/X, Reddit, TikTok, VK… hepsi yt-dlp'nin kod deposundan gelir.
2. **Tarayıcı çerezleri taşıma** (üyelere özel içerik):
   `yt-dlp --cookies-from-browser chrome|firefox|safari`. **Dikkat — riskli kısmı:**
   - Chrome 127+ App-Bound encryption yüzünden chrome çerezlerinin direct okunması engellenir.
   - Safari çözümü: keychain izni (kapı; kullanıcı onayı ister) — pragmatik.
   - Firefox en kolay hedef.
   - Plan A(simple): ilk aşamada cookie dosyası export'u (Netscape formatı yeterli).
3. **Altyazı**: `--write-subs --sub-langs tr,en` varsayılan; seçilebilir.
4. **Doğrudan HTTP**: IDM'in asıl gücü — aria2c bu hızda bizim veteran askerimiz.
5. **(M7) Tarayıcı uzantısı**: Safari Web Extension, `kervan://add?url=...` özel scheme
   ile sayfada "Bunu Kervan'a gönder" — IDM'in tarayıcı entegrasyonunun karşılığı.

---

## 5. Klasörleme Planı

*(kod dosyası yok — yer tutucu `.gitkeep` var, dosya/klasör adları plan amaçlı)*

```
Kervan/
├── README.md                        ← bu dosya
├── docs/
│   ├── ARCHITECTURE.md              ← modül içi detay, arayüz sözleşmeleri
│   └── ROADMAP.md                   ← M0..M7 aşamaları, tanımları, "bitti" kriteri
├── engine/                          ← Swift Package (ortak çekirdek: CLI + app paylaşır)
│   ├── Sources/
│   │   ├── QueueKit/                ← state machine, SQLite persist, concurrency
│   │   └── EngineCore/              ← ProcessRunner + adapter'lar
│   └── Tests/                       ← ünite testler (mock process ile)
├── app/                             ← SwiftUI macOS uygulaması (M3)
│   └── Kervan/
│       └── Sources/
│           ├── Views/               ← AddURLSheet, QueueList, Detail, Settings
│           ├── Models/              ← DownloadItem, Preset, ProgressEvent (view-modelleri)
│           └── Services/            ← ClipboardWatcher, Notifier, DockBadge, URLClassifier
├── cli/                             ← kervan-cli (M1'de motoru burada sınarız)
│   └── Sources/
├── resources/
│   └── presets/                     ← kalite ön ayar JSON'ları (M1'de yazılacak)
├── tests/                           ← entegrasyon testleri (gerçek indirme senaryoları)
└── scripts/                         ← kurulum/geliştir yardımcıları (M1'de yazılacak)
    └── (install-deps.sh, run-cli.sh … planı)
```

---

## 6. Yol Haritası (özet; detayı `docs/ROADMAP.md`)

| Aşama | Ne | "Bitti" kriteri |
|---|---|---|
| **M0** | Plan + mimari + klasörleme *(bu repo)* | bu doküman |
| **M1** | `kervan-cli` MVP: `kervan add <url>` → metadata → güvenilir video indirme | terminalden 1080p YouTube videosu iner, ilerleme görünür |
| **M2** | Kuyruk zafere: pause/resume/cancel/retry, persistence (uygulama kapansa bile kuyruk sürer) | Mac kapatılıp açılınca kuyruk kaldığı yerden sürer |
| **M3** | SwiftUI app MVP: liste, ekleme sheet'i, detay görünümü, ilerleme çubuğu | app ile tam akış CLI'siz çalışır |
| **M4** | UX cila: bildirim, dock badge, clipboard watcher, sürükle-bırak | panoya link kopyalayınca öneri çıkar |
| **M5** | "Her şey": cookies, altyazı, playlist UX, doğrudan HTTP arayüzü | üyelik gerektiren içerik çerez taşıma ile iner |
| **M6** | ffmpeg: birleştirme + mp3 çıkarma (`brew install ffmpeg`) | 4K tek dosya iner; bir video mp3'e döner |
| **M7** | Safari Web Extension + `kervan://add?url=` + dmg/notarization dağıtım | tarayıcıdan tek tıkla gönderilen indirme |

Not: **Varsayılan indirme dizini `~/Downloads/Kervan/`** olarak planlandı.

---

## 7. Bilinen Riskler & Kararlar

| Risk | Plan |
|---|---|
| yt-dlp'de YouTube ayıklama düzenli değişir | `brew upgrade yt-dlp` rutini + "engine, dış kaynağa bağımlı" varsayımı. Sürüm kilitlemiyoruz |
| Chrome 127+ çerez kısıtlaması | M5'te Safari(Firefox) önce, chrome için cookie-dosyası yolu |
| ffmpeg 600 MB + M6'ya ertelendi | 1080p ayarı ffmpeg'siz de çalışacak şekilde preset'lendi (`720p-safe` fallback) |
| Sandbox/App kısıtı | dağıtım dmg + notarization; App Store hedeflenmez (indirme yöneticisi sandbox'ta çocuk process çalıştıramaz) |
| Aynı siteye paralel istek → rate-limit | max eşzamanlılık 3 + site başına yumuşatma |

---

*Bu doküman proje anayasasıdır; taslak v0 olarak yazıldı. Kod aşaması M1'de başlar.*
