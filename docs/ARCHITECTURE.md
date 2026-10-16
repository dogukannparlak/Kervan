# Kervan — Mimari Detayı

> Bu doküman README'nin 2. bölümünü derinleştirir: modül içi sözleşmeler, state
> makinesi ve veri modelleri. Kod yok — sadece "ne yapmalı, nesne kim, ne dönmeli".

## 1. EngineCore — dışarıdaki araçlarla tek konuşma noktası

### ProcessRunner
Tüm child process yönetimi *yalnızca* buradan geçer. Tek yerde toplanmasının
sebebi: timeout, kill politikası, stream ayrıştırma ve sandbox izinleri
tek noktadan denetlenir.

Sorumluluklar:
- process başlat, çalışma dizini/ORTAM değişkenleri yönet (ör. `PYTHONIOENCODING=utf-8`)
- stdout'u **satır akısı** olarak yayınla (AsyncStream) — UI/queue buradan tüketir
- stdin kapatma + temiz sonlandırma sırası: önce SIGINT (yt-dlp temiz duruyor),
  bekle, gelmezse SIGKILL
- uzun süre sessiz process'e "heartbeat timeout" — ölü process tespiti
- log ring buffer: her item'in son N satırı, hata raporlarında sanal "kayıt"

### YtDlpAdapter — iki yüzü
1. **Probe yüzü** (metadata):
   - `yt-dlp -J <url>` → stdout tamamen *bir* JSON. Ekran olmaz, sadece veri.
   - Bu JSON'dan: başlık, süre, site, varsa formatlar listesi, playlist olabilir mi
   - Playlist: `--flat-playlist -J` ikinci istek → her giriş kuyruğa ayrı öğe olur
2. **Download yüzü**:
   - `--newline` + makine-okunur ilerleme şablonu (`--progress-template`,
     `%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s`):
     her satır ayrıştırılıp bir `ProgressEvent`'e dönüşür
   - kalite preset → argüman soyutlaması (presets JSON'dan derlenir)
   - fragment indirme: sitelere özel (m3u8, dash-segment, HLS), extended retry
   - dosya adı şablonu sabitlendi: site/başlık/yıl içeren güvenli bir şema

### Aria2Adapter
- Doğrudan HTTP(S) indirme: `-x 16 -s 16 --continue --file-allocation=none`
- Ayrı bir process; ilerlemesini aynı ProgressEvent sözleşmesine çeviren ince adaptör
- Kullanıcının klasik IDM'i aradığı senaryo: doğrudan dosya linkleri, CDN'ler, arşivler

### MergeService (M6 — ffmpeg)
- `video+audio → mkv/mp4` remux (kod dönüştürme **yok** → hızlı, kalite kayıpsız)
- `audio → mp3/m4a` transcode (M6'da "audio" preset'i tamamlanır)
- Feature flag: ffmpeg yolu `which` ile bulunamazsa preset'ler otomatik "safe" moduna düşer

## 2. QueueKit — projenin kalbi

### State machine

```
              ┌──────── resumed ───────────────┐
              ↓                                │
 queued → probing → downloading ──→∟merging*┐  │
              │              │              │  │
              ↓              ↓              │  │
           paused(recall)   canceled       │  │
                             │             │  │
                             ↓             ↓  │
              retry/backoff → queued       done  ← merging* (ffmpeg, M6)
                                             │
                                             └→ failed (max retry veya terminal hata)
```

Kurallar:
- geçişler yalnız bu makineden; UI/cli motorun *istediği* işlemleri kuyruğa yazar
- SQLite para/messages junto: state + ilerleme snapper'ı **diskten okunur**,
  uygulama kapanıp açılsa kuyruk eskisi gibi belirir (M2 bitiş kriteri)
- eşzamanlılık: global `maxParallel` + site başına "softer" kural (M2)
- her item: `retryCount`, `maxRetries` (varsayılan 3), `nextAttemptAt` (backoff)

### ProgressEvent sözleşmesi (ortak dil)

Tüm adapter'lar aynı olayın üreticisi olmalıdır:

| Alan | anlamsı |
|---|---|
| itemId | kuyruk öğesi |
| phase | probe / download / merge / postprocess |
| fraction | 0..1 |
| bytesDone / bytesTotal | |
| speed | saniyedeki bayt |
| eta | saniye |
| message | satır bazlı durum notu (opsiyonel) |

Bu sözleşme sayesinde CLI/tablo/panel/bildirim aynı veriden beslenir; yeni bir
arayüz katmanını "event'i arayüze yansıt" işi kadar küçülür.

## 3. Veri modeli (ergonomik, kod değil — sözleşme)

**DownloadItem** küçük kapsamlı:
- id, url, tür (video | http), preset, oyun ilerleme alanları, state, timestamps
- çıkış dosyası (tahmin + bets: klasör, isim, uzantı), log-mesihi (ring buffer)
- `parentId` — playlist çocuğu ise atası; playlist başlığı grubu taşır

**Preset**: id, etiket, dont ROTATE; üretim: yt-dlp argümanları dizisi + fallback zinciri
`1080p` preset fallback'i üretim formatı: en iyi ≤1080p (mp4/m4a) → yoksa best-merged → yoksa safe.

## 4. Paralel işletme modeli

- QueueKit kendi **actor**rparrındaydır; adapter'lar her biri ayrı actor +
  alt-side kendi process'i. Data-race güvenliği Swift 6 strict concurrency ile
  tasarım tarafından garanti edilir.
- UI update throttle: ProgressEvent → yayınlama saniyede ~4 azalta ("dizi" persınk
  etkisi), ağır tablo render'in önlenmesi.

## 5. Sandbox / izinler / güvenlik

- Uygulama bir **dmg dağıtımı** hedefler; App Store sandbox'ı planlanmaz
  (çocuk process + keychain + geniş dosya yazma App Store'da uygulanamaz).
- Sandbox HS World's: user-selected folder erişimi veya ~/Downloads default
- çerez/anahtar: bakım — keychain'den yalnız Safari çerez okuma onayında kullanılır

## 6. Test stratejisi

- **MockProcess**: inner süreci taklit eden sahte runner; QueueKit ve state makini
  unit testleri process'siz hızlı döner
- **Golden URL set'i** (tests/): her aşama öncesi küçük kamu örnekler (YouTube ses
  videosu, bir HTTP zip, bir ... site örneği) → gerçek indirme entegrasyon testi
- CLI insan testi: "kervan add <url> → ETA doğru mu, resume çalışıyor mu" checklist
