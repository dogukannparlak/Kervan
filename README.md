# Kervan

> IDM benzeri, **yt-dlp tabanlı**, native macOS indirme yöneticisi.
> **Durum: M3 bitti (2026-10-23)** — Brave eklentisi sayfada oynayan videoyu (mp4, HLS, DASH) ağ trafiğinden
> yakalar ve tek tıkla arka plandaki `kervand` kuyruğuna gönderir. Video siteleri (yt-dlp), giriş isteyen
> sitelerde Brave çerezi, çok videolu sayfalar, düz dosyalar (aria2). SwiftUI uygulaması M4'te.

## Hızlı başlangıç

```bash
scripts/install-deps.sh                # yt-dlp, ffmpeg, aria2, deno
swift build -c release
.build/release/kervan service install  # kervand'ı LaunchAgent olarak kurar ve başlatır
.build/release/kervan extension install # Brave/Chrome/Edge köprüsü (Native Messaging)
alias kervan=$PWD/.build/release/kervan

kervan add <url> [<url>…] -w           # kuyruğa ekle, -w: bitene kadar izle
kervan add <sayfa> --all               # sayfadaki bütün videolar (--items 1,3)
kervan list                            # ls; --all bitmişleri de gösterir
kervan watch                           # canlı tablo
kervan pause 3 · resume 3 · cancel 3 · retry 3 · rm 3
kervan log 3 -n 50
kervan get <url>                       # servissiz, ön planda tek indirme
kervan doctor                          # araçlar + servis durumu
kervan service status | uninstall
```

Seçenekler (`add`/`get`): `-p best|1080p|720p|audio`, `-d <klasör>` (varsayılan `~/Downloads/Kervan`),
`--cookies auto|none|brave|firefox…` (auto: site giriş isterse Brave çerezi), `--referer <sayfa>`,
`--name <dosya adı>`.

### Brave eklentisi (bir kez)

1. `kervan extension install`
2. `brave://extensions` → sağ üstte **Geliştirici modu** → **Paketlenmemiş öğe yükle** → bu repodaki `extension/`
3. Kimlik `ifkabkcjdlkjbgijfnphgecoggfjdgek` görünmeli.

Kullanım:
- **Videonun sağ üst köşesinde "Bu videoyu indir"** düğmesi çıkar (IDM gibi). Tıklayınca menü: videonun
  dosyası, yakalanan akışlar (HLS/DASH) ve "Sayfadan indir" (yt-dlp). Tek seçenek varsa doğrudan ekler.
  "×" o video için gizler; popup'taki kutucuk hepsini kapatır.
- Araç çubuğundaki **K** simgesi: rozet yakalanan medya sayısı; pencerede **Sayfayı indir**, yakalanan
  medya için **İndir**, kuyrukta **Durdur / Devam / İptal / Yeniden / Sil / Klasörde göster**.
- Sağ tık → "Kervan ile indir": bağlantı, video ve sayfa için.
Eklenti testleri: `node --test extension/test/`.

---

## 1. Temel Fikir

Kendi indirme motorumuzu yazmıyoruz. Alanında en iyi hazır araçları, arkalarından
**yöneten bir katman** olarak sarıyoruz:

| Araç | Görev | Durum (2026-10-23) |
|---|---|---|
| **yt-dlp** | Video siteleri: metadata, format seçimi, indirme, fragment-resume | ✅ 2026.08.19 (brew) |
| **ffmpeg** | Ayrı gelen görüntü + ses akışlarını birleştirme (remux), mp3 çıkarma | ✅ 9.0.2 (brew) |
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

### Kalite ön ayarları (`Sources/EngineCore/Resources/presets/*.json`)

| Preset | yt-dlp format seçimi (taslak) | Çıktı |
|---|---|---|
| `best` | `bv*+ba/b` | mkv (4K/AV1/VP9 dahil) |
| `1080p` | `bv*[height<=1080][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=1080]+ba/b[height<=1080]` | mp4 (QuickTime uyumlu öncelikli) |
| `720p` | aynı mantık, `height<=720` | mp4 |
| `audio` | `ba[ext=m4a]/ba` | m4a; mp3 için `-x --audio-format mp3` (M6) |

Preset'ler veri olarak tutulur, kodda sabit değildir.

---

## 4. "Her şey" kapsamı

1. **Binlerce site**: yt-dlp ekstraktörleri.
2. **Tarayıcı çerezleri** (üyelere özel içerik): `--cookies-from-browser`.
   - **Brave/Chrome (macOS)**: çalışıyor (M1.5, 2026-10-23: Brave'den 1709 çerez okundu).
     Chrome 127'nin App-Bound şifrelemesi Windows'a özgü.
   - **Firefox**: en kolay; şifresiz SQLite.
   - **Safari**: `Cookies.binarycookies` için **Full Disk Access** gerekir.
   - Yedek yol: Netscape formatında `cookies.txt` içe aktarma.
3. **Altyazı**: `--write-subs --sub-langs tr,en`; preset'te seçilebilir.
4. **Doğrudan HTTP**: aria2 çok bağlantılı indirme; referer/User-Agent/yönlendirme desteği.
5. **(M3) Tarayıcı eklentisi**: Brave/Chromium (Manifest V3). Sayfanın ağ trafiğinden video/m3u8/mpd
   akışlarını yakalar, IDM'in "Bu videoyu indir" düğmesinin karşılığı; Safari M7'de opsiyonel.

---

## 5. Klasör planı

```
Kervan/
├── README.md
├── Package.swift                ← tek kök paket
├── Sources/
│   ├── EngineCore/              ← ProcessRunner, URLClassifier, adapter'lar
│   │   └── Resources/presets/   ← preset JSON'ları (paket kaynağı)
│   ├── QueueKit/                ← state machine, SQLite, eşzamanlılık
│   ├── KervanIPC/               ← soket protokolü, sunucu/istemci, dosya yolları
│   ├── kervand/                 ← servis (LaunchAgent)
│   ├── kervan-native-host/      ← tarayıcı eklentisi köprüsü (Native Messaging)
│   └── kervan/                  ← CLI
├── Tests/
│   ├── EngineCoreTests/         ← MockProcess ile, ağsız
│   ├── QueueKitTests/
│   └── Integration/             ← gerçek indirme (ağ ister, ayrı çalıştırılır)
├── app/                         ← Kervan.app Xcode projesi (M3); kök paketi yerel bağımlılık olarak kullanır
├── extension/                   ← Brave/Chromium eklentisi (MV3): detect.js, background.js, popup, test/
├── docs/
│   ├── ARCHITECTURE.md
│   └── ROADMAP.md
└── scripts/                     ← install-deps.sh, dev yardımcıları
```

---

## 6. Yol haritası (özet; detay `docs/ROADMAP.md`)

Öncelik: IDM gibi her videoyu yakalamak → çerez ve tarayıcı eklentisi uygulamadan önce.

| Aşama | Ne | Bitti kriteri |
|---|---|---|
| **M0** ✅ | Plan + mimari | bu belge |
| **M1** ✅ | Paket + CLI tek indirme (ffmpeg dahil) | 1080p YouTube tek mp4; HTTP zip aria2 ile |
| **M1.5** ✅ | Brave çerezi + çok videolu sayfa | giriş isteyen sitede otomatik çerez; sayfadaki videolar `--all` ile |
| **M2** ✅ | `kervand` + kalıcı kuyruk | servis öldürülüp açılınca kuyruk kaldığı yerden sürer |
| **M3** ✅ | Brave eklentisi: ağdan video yakalama | yt-dlp'nin tanımadığı sayfadaki video tek tıkla iner |
| **M4** | SwiftUI app MVP | terminal açmadan ekle/duraklat/devam/iptal |
| **M5** | UX cila | panodaki link 3 sn'de kuyruğa; bildirim + dock yüzdesi |
| **M6** | Altyazı, mp3, başlıklar, diğer tarayıcı çerezleri | gömülü altyazı; mp3 + kapak |
| **M7** | Dağıtım | dmg Homebrew'suz başka Mac'te çalışır |

Kapsam dışı: DRM'li servisler (Netflix, Disney+, Spotify…).

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

*Proje anayasası, v0.1.*
