# Kervan

> IDM benzeri, **yt-dlp tabanlı**, native macOS indirme yöneticisi.
> **Durum: v0.1 — plan ve mimari (gözden geçirildi, 2026-10-23). Henüz kod yok.**

Kervan, Internet Download Manager'ın macOS'ta yapmadığı şeyi yapar: video sitelerini
(YouTube, Instagram, Twitter/X, VK, Reddit… yt-dlp'nin desteklediği her site)
ve doğrudan HTTP linklerini tek bir kuyrukta, eşzamanlı ve devam edilebilir şekilde indirir.

---

## 1. Temel Fikir

Kendi indirme motorumuzu yazmıyoruz. Alanında en iyi hazır araçları, arkalarından
**yöneten bir katman** olarak sarıyoruz:

| Araç | Görev | Durum (2026-10-23) |
|---|---|---|
| **yt-dlp** | Video siteleri: metadata, format seçimi, indirme, fragment-resume | ✅ 2026.08.19 (brew) |
| **ffmpeg** | Ayrı gelen görüntü + ses akışlarını birleştirme (remux), mp3 çıkarma | ⏳ M1'de `brew install ffmpeg` (9.0.2) |
| **aria2c** | Doğrudan HTTP(S) linkleri: çok bağlantılı paralel indirme, JSON-RPC ile yönetim | ✅ 1.37.0 (brew) |
| **deno** | yt-dlp'nin YouTube imza/JS çözümü için kullandığı JS çalışma ortamı | ✅ kurulu (brew) |

**ffmpeg neden M1'de:** YouTube artık sesli+görüntülü tek dosya (eski 18/22 formatları)
sunmuyor; 360p dahil her format ya yalnız görüntü ya yalnız ses. ffmpeg olmadan
YouTube'dan sesli video inmez. (Doğrulama: `yt-dlp -F aqz-KE-bpKQ`, 2026-10-23.)

Swift 6 / SwiftUI ile yazılan native uygulama bu araçları child process olarak yönetir.
Kuyruk, state machine ve kalıcılık bizim katmanımızdır.

---

## 2. Mimari

```
┌──────────────────────┐   ┌──────────────────────┐
│ Kervan.app (SwiftUI) │   │ kervan (CLI)         │   ← istemciler
└──────────┬───────────┘   └──────────┬───────────┘
           └────────── XPC / yerel soket ┘
                       ↓
┌─────────────────────────────────────────────────┐
│ kervand (LaunchAgent)   ← kuyruğun TEK sahibi    │
│   QueueKit   : kuyruk, state machine, SQLite     │
│   EngineCore : ProcessRunner + adapter'lar       │
│     ├─ URLClassifier  (video mu, düz dosya mı)   │
│     ├─ YtDlpAdapter   (video siteleri)           │
│     ├─ Aria2Adapter   (HTTP, aria2 JSON-RPC)     │
│     └─ FFmpegLocator  (ffmpeg yolu / sürümü)     │
└─────────────────────────────────────────────────┘
                       ↓
        yt-dlp · ffmpeg · aria2c · deno
```

Kurallar:
- **Kuyruğu yalnız `kervand` çalıştırır.** CLI ve app ona komut gönderir, olay dinler.
  App ya da terminal kapansa da indirme sürer; Mac yeniden açılınca LaunchAgent
  servisi kaldırır ve kuyruk kaldığı yerden devam eder.
- **QueueKit ve EngineCore GUI'den bağımsızdır.** Önce CLI + servis bitirilir,
  SwiftUI kabuk sonra gelir.

### Modül dökümü

| Modül | Nerede | Sorumluluk |
|---|---|---|
| `ProcessRunner` | EngineCore | Child process başlatma, satır satır stdout/stderr, temiz sonlandırma (SIGINT → bekle → SIGKILL), sessizlik zaman aşımı |
| `URLClassifier` | EngineCore | HEAD isteği + Content-Type + yt-dlp `direct` alanı → hangi adapter |
| `YtDlpAdapter` | EngineCore | Probe (`-J --flat-playlist`), indirme (`--newline --progress-template`), ham ilerleme alanlarını ayrıştırma |
| `Aria2Adapter` | EngineCore | Tek `aria2c --enable-rpc` süreci; ekleme/duraklatma/devam/ilerleme JSON-RPC ile |
| `FFmpegLocator` | EngineCore | ffmpeg yolunu bulma; yoksa video öğesini açık hata ile reddetme |
| `QueueKit` | QueueKit | SQLite (GRDB, WAL) kalıcı state, state machine, eşzamanlılık, retry/backoff |
| `kervand` | servis | LaunchAgent; kuyruğu işletir, istemcilere komut + olay arayüzü sunar |
| `ClipboardWatcher`, `Notifier`, `DockBadge` | app | Pano izleme, bildirim, dock yüzdesi |

---

## 3. Bir indirmenin hayatı

```
Link eklenir (CLI, app, pano, tarayıcı uzantısı)
        ↓
URLClassifier
  1) HEAD: Content-Type video/html değil ve dosya adı varsa → DÜZ HTTP
  2) değilse yt-dlp probe: -J --flat-playlist
       direct: true            → DÜZ HTTP
       _type: playlist         → her giriş ayrı çocuk öğe
       aksi                    → VIDEO
        ↓                                   ↓
YtDlpAdapter                          Aria2Adapter (RPC)
  preset → format seçimi               -x8 -s8 --continue
  ffmpeg ile birleştirme               ↓
        ↓                                   ↓
     ProgressEvent (bayt · hız · ETA · aşama)
        ↓
QueueKit state: queued → probing → downloading → postprocessing → done
                                  (paused · failed · canceled her aktif durumdan)
        ↓
~/Downloads/Kervan/ + macOS bildirimi + dock
```

> Not: düz bir `.tar.gz` linkinde `yt-dlp -J` **başarılı** döner
> (`extractor: generic, direct: true`). Bu yüzden "probe başarısızsa HTTP"
> kuralı işe yaramaz; sınıflandırma yukarıdaki sırayla yapılır.

### Eşzamanlılık & kuyruk

- Varsayılan **3 indirme aynı anda** (ayarlardan 1–10).
- Site başına sınır (varsayılan 2) + aynı siteye ardışık başlatmalar arasında kısa gecikme (rate-limit).
- **Playlist**: `--flat-playlist` ile listelenir; her giriş ayrı öğe (`parentId`).
- **Pause/resume**: yt-dlp'de SIGINT + `.part` dosyasından devam; aria2'de RPC `pause`/`unpause`.
- **Retry**: yt-dlp `--retries 10 --fragment-retries 10`; üstte öğe başına 3 deneme, exponential backoff.

### Kalite ön ayarları (`resources/presets/*.json`)

| Preset | yt-dlp format seçimi (taslak) | Çıktı |
|---|---|---|
| `best` | `bv*+ba/b` | mkv (4K/AV1/VP9 dahil) |
| `1080p` | `bv*[height<=1080][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=1080]+ba/b[height<=1080]` | mp4 (QuickTime uyumlu öncelikli) |
| `720p` | aynı mantık, `height<=720` | mp4 |
| `audio` | `ba[ext=m4a]/ba` | m4a; mp3 için `-x --audio-format mp3` (M6) |

Preset'ler veri olarak tutulur, kodda sabit değildir.

---

## 4. "Her şey" kapsamı (M5)

1. **Binlerce site**: yt-dlp ekstraktörleri.
2. **Tarayıcı çerezleri** (üyelere özel içerik): `--cookies-from-browser`.
   - **Brave/Chrome (macOS)**: çerezler Keychain'deki anahtarla şifreli; yt-dlp
     ilk seferde Keychain izni ister. Chrome 127'nin App-Bound şifrelemesi
     **Windows'a özgü**, macOS'u etkilemiyor (M5'te tekrar doğrulanacak).
   - **Firefox**: en kolay; şifresiz SQLite.
   - **Safari**: `Cookies.binarycookies` için **Full Disk Access** gerekir.
   - Yedek yol: Netscape formatında `cookies.txt` içe aktarma.
3. **Altyazı**: `--write-subs --sub-langs tr,en`; preset'te seçilebilir.
4. **Doğrudan HTTP**: aria2 çok bağlantılı indirme; referer/User-Agent/yönlendirme desteği.
5. **(M7) Tarayıcı uzantısı**: önce **Brave/Chromium** (Manifest V3), sonra Safari.

---

## 5. Klasör planı

```
Kervan/
├── README.md
├── Package.swift                ← tek kök paket (M1'de yazılacak)
├── Sources/
│   ├── EngineCore/              ← ProcessRunner, URLClassifier, adapter'lar
│   ├── QueueKit/                ← state machine, SQLite, eşzamanlılık
│   ├── kervand/                 ← servis (LaunchAgent)
│   └── kervan/                  ← CLI
├── Tests/
│   ├── EngineCoreTests/         ← MockProcess ile, ağsız
│   ├── QueueKitTests/
│   └── Integration/             ← gerçek indirme (ağ ister, ayrı çalıştırılır)
├── app/                         ← Kervan.app Xcode projesi (M3); kök paketi yerel bağımlılık olarak kullanır
├── extension/                   ← Brave/Chromium uzantısı (M7)
├── resources/
│   ├── presets/                 ← preset JSON'ları
│   └── launchd/                 ← com.dogukan.kervand.plist
├── docs/
│   ├── ARCHITECTURE.md
│   └── ROADMAP.md
└── scripts/                     ← install-deps.sh, dev yardımcıları
```

---

## 6. Yol haritası (özet; detay `docs/ROADMAP.md`)

| Aşama | Ne | Bitti kriteri |
|---|---|---|
| **M0** | Plan + mimari | bu belge ✅ |
| **M1** | Paket + CLI tek indirme (ffmpeg dahil) | `kervan get <url>` 1080p sesli YouTube videosunu tek mp4 olarak indirir; HTTP zip aria2 ile iner |
| **M2** | `kervand` + kalıcı kuyruk | 5 öğelik kuyruk sürerken servis öldürülür; yeniden başlayınca kaldığı yerden devam eder |
| **M3** | SwiftUI app MVP | terminal açmadan ekle/duraklat/devam/iptal |
| **M4** | UX cila | panodaki link 3 sn'de kuyruğa; bildirim + dock yüzdesi |
| **M5** | Çerez, altyazı, playlist UX | üyelik isteyen içerik Brave çereziyle iner |
| **M6** | Ses çıkarma + gömme | mp3 + kapak + etiketler dolu |
| **M7** | Brave uzantısı + dağıtım | Brave'den tek tıkla kuyruğa; dmg başka Mac'te çalışır |

Varsayılan indirme dizini: `~/Downloads/Kervan/`.

---

## 7. Riskler & kararlar

| Risk | Plan |
|---|---|
| YouTube ayıklaması sık bozulur | yt-dlp sürümü kilitlenmez; `kervan doctor` sürüm ve deno kontrolü yapar, güncellemeyi önerir |
| ffmpeg yoksa video birleşmez | `FFmpegLocator` başlangıçta kontrol eder; yoksa video öğesi açık hata verir (sessizce yalnız görüntü indirmez) |
| Çerez okuma izinleri | Brave/Chrome: Keychain onayı; Safari: Full Disk Access; yedek: cookies.txt |
| Dağıtım (başka Mac) | Homebrew'a güvenilmez: yt-dlp (standalone), ffmpeg, aria2c, deno ya `~/Library/Application Support/Kervan/bin`'e ilk açılışta indirilir ya pakete gömülür (M7 kararı). Gömülürse GPL/LGPL lisans metinleri eklenir |
| App Store sandbox | Hedeflenmez; dmg + codesign + notarization |
| Aynı siteye paralel istek → rate-limit | global 3 + site başına 2 + başlatma gecikmesi |
| Kişisel kullanım | Kervan araçtır; indirilen içeriğin hakları kullanıcıdadır |

---

*Proje anayasası, v0.1. Kod M1'de başlar.*
