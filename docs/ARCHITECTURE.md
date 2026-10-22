# Kervan — Mimari Detayı

> README'nin 2–3. bölümlerini derinleştirir: modül sözleşmeleri, state machine,
> veri modeli. Kod değil, "kim ne yapar, ne döner".

## 1. EngineCore — dış araçlarla tek temas noktası

### ProcessRunner
Bütün child process yönetimi yalnız buradan geçer. Zaman aşımı, sonlandırma
politikası ve çıktı ayrıştırma tek yerde denetlenir.

- Süreci başlatır; çalışma dizini ve ortam değişkenlerini ayarlar
  (`PYTHONIOENCODING=utf-8`, `PATH`'e araç dizini).
- stdout ve stderr'i ayrı **satır akışları** (`AsyncStream<String>`) olarak yayar.
- Sonlandırma: SIGINT → 5 sn bekle → SIGKILL.
- Sessizlik zaman aşımı: belirli süre hiç çıktı yoksa süreç ölü sayılır.
- Öğe başına son 500 satırlık log halkası (ring buffer); hata raporunda kullanılır.
- Test için `ProcessRunning` protokolü; `MockProcess` hazır satır dizisi döner.

### URLClassifier
1. `HEAD` isteği (yönlendirmeleri izler). `Content-Disposition: attachment` ya da
   `text/html` dışı bir Content-Type (ör. `application/zip`, `application/octet-stream`)
   → **http**.
2. Değilse `yt-dlp -J --flat-playlist <url>`:
   - `direct == true` → **http**
   - `_type == "playlist"` → **playlist** (girişler çocuk öğe olur)
   - aksi → **video**
3. yt-dlp hata verirse (desteklenmeyen site) ve HEAD başarılıysa → **http**; ikisi de
   başarısızsa öğe `failed` olur, sebep log'a yazılır.

### YtDlpAdapter
- **Probe**: `-J --flat-playlist`. Başlık, süre, site, küçük resim, format listesi.
- **Download** argümanları (taslak):
  ```
  yt-dlp --newline --no-colors --ffmpeg-location <yol>
    -f <preset.format> --merge-output-format <preset.container>
    --retries 10 --fragment-retries 10
    -o "<hedef>/%(title).200B [%(id)s].%(ext)s"
    --progress-template "download:KERVAN|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s"
    --print "after_move:KERVAN_FILE|%(filepath)s"
  ```
  Biçimli `_percent_str` alanları yerine ham sayılar okunur; boş alanlar `NA` gelir.
  `KERVAN|` öneki olmayan satırlar log'a gider.
- Birleştirme aşaması (`[Merger]` satırı) `postprocessing` olarak raporlanır.

### Aria2Adapter
- Servis açılışında tek `aria2c --enable-rpc --rpc-listen-all=false
  --rpc-secret=<rastgele> --continue=true --file-allocation=none` süreci başlatılır.
- Öğe ekleme `aria2.addUri` (`max-connection-per-server=8`, `split=8`);
  ilerleme `aria2.tellStatus` ile saniyede 2 kez çekilir.
- Pause/resume/cancel: `aria2.pause` / `aria2.unpause` / `aria2.remove`.
- Kuyruk kararlarını aria2 değil QueueKit verir; aria2 yalnız yürütücüdür.

### FFmpegLocator
- `--ffmpeg-location` için yol: ayar → `~/Library/Application Support/Kervan/bin` →
  `/opt/homebrew/bin` → `PATH`.
- Bulunamazsa video öğeleri `failed(reason: ffmpegMissing)`; yalnız görüntü ya da
  yalnız ses indirip "bitti" demek yasak.

## 2. QueueKit — projenin kalbi

### State machine

```
queued ──→ probing ──→ downloading ──→ postprocessing ──→ done
  ↑           │             │                │
  │           └──────┬──────┴────────┬───────┘
  │                  ↓               ↓
  │               paused          failed ──(retry < max, backoff)──┐
  │                  │               │                             │
  └──── resume ──────┘               └──(elle yeniden dene)────────┤
  └────────────────────────────────────────────────────────────────┘

canceled: queued / probing / downloading / paused / failed durumlarından; terminal.
```

Kurallar:
- Durum geçişleri yalnız `QueueKit` actor'ünde, izinli geçiş tablosuyla yapılır;
  izinsiz geçiş hata fırlatır (testlenir).
- State ve son ilerleme **SQLite'a yazılır** (GRDB, WAL modu). İlerleme yazımı
  en fazla saniyede 1 kez (disk yükü).
- Servis açılışında `probing/downloading/postprocessing` kalan öğeler
  `queued`'a döner (çökme sonrası kurtarma); `.part` dosyası devamı sağlar.
- Eşzamanlılık: global `maxParallel` (3) + site başına `maxPerHost` (2) +
  aynı siteye başlatmalar arası gecikme.
- Her öğe: `attempt`, `maxAttempts` (3), `nextAttemptAt` (backoff: 10 sn · 2^n, üst 10 dk).

### ProgressEvent (ortak dil)

| Alan | Anlamı |
|---|---|
| itemId | kuyruk öğesi |
| phase | probe / download / postprocess |
| bytesDone / bytesTotal? | toplam bilinmiyorsa `nil` (tahmin ayrı alan) |
| bytesTotalEstimate? | yt-dlp `total_bytes_estimate` |
| speed? | bayt/sn |
| eta? | saniye |
| message? | serbest durum notu |

`fraction` saklanmaz, bu alanlardan hesaplanır. Tüm adapter'lar bu olayı üretir;
CLI, app, bildirim ve dock aynı akıştan beslenir.

## 3. Veri modeli (sözleşme)

**DownloadItem**
- `id`, `url`, `kind` (video | http | playlist), `presetId`, `state`
- `title?`, `host`, `parentId?` (playlist çocuğu ise)
- `destinationDir`, `outputPath?` (bitince yt-dlp `KERVAN_FILE` satırından)
- `attempt`, `maxAttempts`, `nextAttemptAt?`, `lastError?`
- `createdAt`, `updatedAt`, `finishedAt?`
- son ilerleme: `bytesDone`, `bytesTotal?`, `speed?`, `eta?`

**Preset**
- `id`, `label`, `format` (yt-dlp `-f` ifadesi), `container` (mp4 | mkv | m4a),
  `extraArgs` (ör. altyazı), `requiresFFmpeg` (bool)

## 4. Servis ve istemciler

- `kervand` bir **LaunchAgent**'tır (`~/Library/LaunchAgents/com.dogukan.kervand.plist`,
  `RunAtLoad`, `KeepAlive`). Kuyruğu ve aria2 RPC sürecini yalnız o yönetir.
- İstemci arayüzü: Unix domain socket (`~/Library/Application Support/Kervan/kervand.sock`)
  üzerinde satır başına bir JSON mesaj. Komutlar: `add`, `list`, `pause`, `resume`,
  `cancel`, `retry`, `remove`, `subscribe` (olay akışı). App M3'te aynı protokolü kullanır;
  gerekirse sonra XPC'ye geçilir.
- CLI, servis çalışmıyorsa açık hata verir ve `kervan service install` önerir.
- M1'de servis yok: `kervan get <url>` tek indirmeyi doğrudan, ön planda çalıştırır.

## 5. Eşzamanlılık modeli

- Swift 6 strict concurrency. `QueueKit` bir actor; her aktif indirme kendi `Task`'ı.
- UI'ye giden ilerleme saniyede en fazla ~4 olaya kısılır (throttle).

## 6. Dağıtım / izinler / güvenlik

- dmg + codesign + notarization; App Store sandbox'ı hedeflenmez.
- Dış araçlar Homebrew'a bağlı kalmaz (M7): `Application Support/Kervan/bin`'e
  kurulum ya da pakete gömme. Gömülü araçlar imzalanır; yt-dlp kendi kendini
  güncelleyeceği için uygulama paketinin içinde değil Application Support'ta tutulur.
- Çerez okuma yalnız kullanıcı istediğinde, seçtiği tarayıcıdan; çerezler diske
  kopyalanmaz, yt-dlp'ye argüman olarak geçer.
- aria2 RPC yalnız localhost'ta ve rastgele secret ile.
- Kullanıcıdan gelen URL hiçbir zaman shell'e verilmez; `Process` argüman dizisiyle geçer.

## 7. Test stratejisi

- **Unit (ağsız)**: `MockProcess` ile adapter ayrıştırma, state geçiş tablosu, backoff.
- **Fixture**: gerçek yt-dlp/aria2 çıktılarından kaydedilmiş satırlar `Tests/Fixtures/`.
- **Integration (ağlı, ayrı)**: küçük kamu örnekleri — kısa bir YouTube videosu,
  bir HTTP arşivi (`ftp.gnu.org/gnu/hello/hello-2.12.tar.gz`), bir playlist.
- **Elle kontrol listesi**: ETA mantıklı mı, pause/resume `.part`'tan devam ediyor mu.
