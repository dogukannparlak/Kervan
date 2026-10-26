# Kervan — Mimari Detayı

> [PLAN.md](PLAN.md)'nin 2–3. bölümlerini derinleştirir: modül sözleşmeleri, state machine,
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
- **Download** argümanları (`YtDlpAdapter.downloadArguments`):
  ```
  yt-dlp --newline --progress --color never --no-playlist
    --retries 10 --fragment-retries 10 -f <preset.format> -P <hedef>
    -o "%(title).200B [%(id)s].%(ext)s"
    --progress-template "download:KERVAN_DL|status|downloaded_bytes|total_bytes|total_bytes_estimate|speed|eta"
    --progress-template "postprocess:KERVAN_PP|status|postprocessor"
    --print "video:KERVAN_INFO|%(format_id)s|%(filesize,filesize_approx)s"
    --print "after_move:KERVAN_FILE|%(filepath)s"
    --ffmpeg-location <yol> --merge-output-format <preset.container> -- <url>
  ```
  - `KERVAN_INFO`: format kimliğindeki `+` sayısından parça sayısı (görüntü + ses = 2)
    ve yaklaşık toplam boyut. İlerleme, biten parçaların baytı + o anki parça.
  - Biçimli `_percent_str` yerine ham sayılar; boş alanlar `NA`.
  - `KERVAN_PP` satırları **stderr'e** düşer (2026-10-23'te gözlendi); iki akış da okunur.
  - `KERVAN_` öneki olmayan satırlar `DownloadEvent.log` olur.

### Aria2Adapter
- M1: her indirme için `aria2c --enable-rpc --rpc-listen-all=false --rpc-listen-port=<rastgele>
  --rpc-secret=<rastgele> --stop-with-process=<kervan pid> --continue=true --file-allocation=none`
  süreci açılır, bitince `aria2.shutdown`. M2: servis açılışında tek kalıcı süreç.
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
add: link sınıflandırılır (HEAD + yt-dlp probe, çerez yedeği) → bozuksa kuyruğa girmez
          ↓
queued ──→ downloading ⇄ postprocessing ──→ done
  ↑            │                │
  │            ├──→ paused ─────┘ (pause; resume → queued)
  │            ├──→ failed ── retry (elle) ──→ queued
  │            └──→ queued  (hata + deneme kaldı: backoff; ya da kapanış/çökme kurtarma)
canceled: queued / downloading / postprocessing / paused / failed durumlarından; retry ile queued.
```

Kurallar:
- Geçişler yalnız `QueueEngine` actor'ünde, `ItemState.canTransition` tablosuyla (testli).
- Bellekte anlık; SQLite'a (GRDB, WAL) en fazla saniyede 1, abonelere en fazla 4/sn yazılır.
- Servis açılışında `downloading/postprocessing` kalanlar `queued`'a döner; `.part` devamı sağlar.
- Eşzamanlılık: global `maxParallel` (3) + site başına `maxPerHost` (2) + aynı siteye başlatmalar
  arası 2 sn.
- Retry: öğe başına 3 deneme, backoff 10 sn · 2^(n-1), üst 10 dk. Kalıcı hatalar (giriş, eksik
  araç, "Video unavailable", 404/410, desteklenmeyen URL) yeniden denenmez.
- Playlist / çok videolu sayfa: `group` satırı + seçilen her giriş için çocuk öğe; grubun durumu
  ve baytları çocuklardan hesaplanır; grup üzerindeki eylem çocuklara uygulanır.
- Yetim süreçler: `ChildRegistry` her child'ın pid + başlama zamanını `children.txt`'e yazar;
  servis açılışında ebeveyni launchd olan ve başlama zamanı tutan süreçler SIGTERM → SIGKILL.

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
  `RunAtLoad`, `KeepAlive`); `kervan service install` ikiliyi ve kaynak paketlerini
  `~/Library/Application Support/Kervan/bin`'e kopyalar. Log: `…/Kervan/kervand.log`.
- Dosyalar (`KervanPaths`, `KERVAN_HOME` ile değişir): `kervan.sqlite`, `kervand.sock`,
  `logs/<id>.log` (araç çıktısı, ilerleme satırları hariç), `children.txt`.
- Protokol: Unix domain socket (0600), satır başına bir JSON. `Request{cmd, url, preset, dir,
  cookies, items, ids, lines}` → `Response{ok, error, items, entries, notes, log, version}`.
  Komutlar: `ping`, `add`, `list`, `log`, `pause`, `resume`, `cancel`, `retry`, `remove`,
  `subscribe` (ardından her değişiklik `event: true` ile gelir; silinenler `removed`).
- Çok videolu sayfa `add`'de seçim yoksa yanıt `entries` döner, kuyruğa bir şey eklenmez.
- Sunucu bağlantı başına bir iş parçacığı kullanır, istekleri actor'e köprüler.
- `kervan get` servissiz, ön planda tek indirme olarak kalır.

## 4b. Tarayıcı eklentisi (M3)

```
Brave sekmesi ──webRequest (yalnız gözlem)──→ background.js ──storage.session (sekme başına)
      │                                            │
   popup / sağ tık ──sendNativeMessage──→ kervan-native-host ──soket──→ kervand
```

- `extension/detect.js` saf mantık (Node testli): yanıt başlıklarından medya türü (HLS, DASH, düz
  dosya), Content-Range'den boyut, `.ts/.m4s` parçalarını, 300 KB altını, googlevideo ve reklam
  alanlarını eler. HLS ana listesi okunup alt listeleri gizlenir.
- Gönderilen istek: `url`, `referer` (sayfa), `userAgent` (tarayıcı), `title` (sekme başlığı →
  dosya adı ipucu; yalnız genel çıkarıcıda ve düz dosyada kullanılır, YouTube gibi sitelerde site başlığı).
- Aynı klasörde aynı ad varsa (diskte ya da kuyrukta) " (2)", " (3)" eklenir.
- `content.js` (bütün sayfa ve çerçevelerde): görünür her `<video>` (en az 240×135) için sağ üst
  köşede kapalı Shadow DOM içinde "İndir" düğmesi; tam ekranda düğme tam ekran öğesine taşınır.
  Menü seçenekleri `buildCandidates` (detect.js) ile arka planda kurulur: videonun http dosyası,
  yakalanan akışlar, sayfa/çerçeve adresi. `blob:` oynatıcılarda (YouTube) tek seçenek sayfadır.
- Popup kuyruk satırında duruma göre eylemler: pause/resume/cancel/retry/remove ve `reveal`
  (servis `open -R` ile Finder'da gösterir; yol istekten değil kuyruktan alınır).
- `kervan-native-host`: 4 bayt uzunluk + JSON; `subscribe` dışındaki bütün komutlar (köprüyü yalnız
  `allowed_origins`'teki eklenti çağırabilir). Manifest
  `~/Library/Application Support/<tarayıcı>/NativeMessagingHosts/com.dogukan.kervan.json`,
  `allowed_origins` tek kimlik. `kervan extension install|uninstall`.
- Çerezler eklentiden alınmaz; yt-dlp gerekirse `--cookies-from-browser brave` ile okur.

## 4c. Kalite listesi ve bildirimler

- `kervan formats` / köprü `formats`: `yt-dlp -J --no-playlist` formatlarından yükseklik başına seçenek;
  boyut, yt-dlp'nin seçeceğine yakın biçimden (doğrudan https > m3u8; ≤1080'de H.264) + en iyi m4a ses.
  Bitti kriteri: Big Buck Bunny 1080p tahmini 267,9 MB, gerçek 268,3 MB (testli fixture).
- `PresetStore.named("480p")` gibi yükseklik adları hazır preset yoksa üretilir (≤1080 mp4, üstü mkv).
- Bildirim: servis `Kervan Agent.app` paketinden çalışır (LSUIElement, ad-hoc imzalı); bildirim
  `osascript display notification` ile. UserNotifications denendi: ad-hoc ya da Apple Development imzalı,
  launchd ya da `open` ile başlatılmış, NSApplication kayıtlı her durumda macOS 27 "Notifications are not
  allowed for this application" döndü (2026-10-23). Bedeli: bildirime tıklayınca dosya açılmaz.
- HLS ilerlemesi: yt-dlp tahmin ve kalan süreyi ondalıklı yazar ("71900.0"); tahmin yoksa parça oranı.

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
