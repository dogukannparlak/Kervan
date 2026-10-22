# Kervan — Yol Haritası

> Her aşama çalışan bir araç bırakır. "Bitti kriteri" elle test edilebilir olmalı.
> Süreler, işi yapacak modelin (Claude) kod yazma süresidir; Doğukan'ın test süresi ayrı.
>
> **Öncelik (Doğukan, 2026-10-23): IDM gibi "her videoyu yakalamak".** Bu yüzden çerez ve
> tarayıcı eklentisi, SwiftUI uygulamasından önce gelir.

## M0 — Plan & Mimari ✅
- README, ARCHITECTURE, ROADMAP; 2026-10-23'te gözden geçirildi (ffmpeg M1'e,
  `kervand` servisi, URL sınıflandırma, çerez notları, Brave uzantısı).

## M1 — Paket + CLI tek indirme ✅ (2026-10-23)
- kök `Package.swift`: `EngineCore`, `kervan` + testler; `scripts/install-deps.sh`
- `ProcessRunner`, `URLClassifier`, `YtDlpAdapter`, `Aria2Adapter` (indirme başına RPC), `ToolLocator`
- `Sources/EngineCore/Resources/presets/`: best, 1080p, 720p, audio
- komutlar: `kervan get`, `kervan probe`, `kervan doctor`, `kervan presets`

**Sonuç:** Big Buck Bunny (aqz-KE-bpKQ) `-p 1080p` ile 268 MB tek mp4 indi
(ffprobe: h264 1920×1080 + aac); `hello-2.12.tar.gz` aria2 ile indi, `tar tzf` sağlam;
`KERVAN_FFMPEG=/yok` ile video açık hatayla reddedildi.

## M1.5 — Çerez + çok videolu sayfa ✅ (2026-10-23)
Neden: 2026-10-23 testinde Vimeo, Reddit ve Instagram çerezsiz "giriş gerekli" hatası verdi.
- `--cookies auto|none|<tarayıcı>`; `auto`: önce çerezsiz, giriş hatasında Brave çereziyle
  bir kez daha (`KERVAN_COOKIES_BROWSER` ile değişir); yetmezse "tarayıcıda giriş yap" hatası
- çok videolu sayfa/playlist: liste gösterilir; `--all` ya da `--items 1,3`
- her biten dosya için ayrı `.completed` olayı

**Sonuç:** Brave'den 1709 çerez okundu (Keychain sorusu çıkmadı); w3schools HTML5 sayfasındaki
2 video `--all` ile indi; Vimeo'da yedek deneme çalıştı, Brave'de Vimeo oturumu olmadığı için
açık hatayla bitti. `swift test` 26/26.
**Denenmedi:** gerçek bir Instagram/X/Reddit/TikTok gönderisi (Doğukan'dan link bekleniyor),
m3u8 akışının indirilmesi (yalnız probe denendi).

## M2 — `kervand` + kalıcı kuyruk ✅ (2026-10-23)
- QueueKit: GRDB/SQLite, state machine, retry/backoff, çökme kurtarma
- `kervand` LaunchAgent + Unix socket protokolü; `kervan service install|uninstall|status`
- CLI istemci: `add`, `list`, `pause`, `resume`, `cancel`, `retry`, `watch`, `log <id>`
- eşzamanlılık: global 3 + site başına 2; playlist girişleri çocuk öğe
- öğe başına çerez tarayıcısı saklanır (referer/başlıklar M3'te)
- yetim süreç temizliği: servis SIGKILL ile ölürse yt-dlp çocukları kalır; yeniden açılışta
  `ChildRegistry` (pid + başlama zamanı) onları durdurur

**Bitti kriteri:** 5 öğelik kuyruk sürerken `kervand` öldürülür; launchd yeniden
başlatınca 3. öğe `.part`'tan devam eder; bozuk bir URL 3 denemeden sonra `failed`
olur ve `kervan retry` ile yeniden kuyruğa girer.
**Süre:** ~2–3 saat model işi.

**Sonuç:** LaunchAgent kuruldu; 5 öğelik kuyrukta Big Buck Bunny %51'deyken `kill -9 kervand` →
launchd 1 sn'de yeniden başlattı, 2 yetim yt-dlp süreci durduruldu, indirme %52'den sürdü ve
dosya sağlam çıktı (ffprobe: 1080p h264 + aac, 10:34). HLS öğesi pause → süreç durdu, `.part`
180 MB kaldı → resume ile devam etti. w3schools mp4'ü Referer'sız 403 verdi, 3 denemeden sonra
`failed` oldu (Referer M3'te). `swift test` 42/42.
**Değişen karar:** link sınıflandırması (probe) `add` anında yapılır; bozuk link kuyruğa hiç girmez
(`probing` durumu kalktı). aria2 öğe başına ayrı süreç olarak kaldı (tek kalıcı süreç gerekmedi).
**Bilinen eksik:** HLS akışlarında toplam boyut bilinmediği için yüzde gösterilmiyor.

## M3 — Brave eklentisi: video yakalama (IDM'in asıl gücü) ✅ (2026-10-23)
Amaç: yt-dlp'nin tanımadığı sitelerde bile, sayfada oynayan videoyu yakalamak.
- Manifest V3 eklentisi (`extension/`), Brave/Chrome/Edge'de çalışır
- **Ağ dinleme**: `webRequest.onHeadersReceived` (yalnız gözlem) ile Content-Type
  `video/*`, `audio/*`, m3u8, mpd ya da `.mp4/.webm/.m3u8/.mpd` yanıtları sekme başına toplanır;
  `.ts`/`.m4s` parçaları ve küçük range istekleri elenir, ana manifest gösterilir
- araç çubuğu rozeti (bulunan video sayısı) + açılır liste: "İndir" (yakalanan akış) ve
  "Sayfayı indir" (sayfa linki → yt-dlp, site destekliyse en iyi kalite)
- sağ tık menüsü: link / video öğesi → "Kervan ile indir"
- köprü: Native Messaging host (`kervan-native-host`) → `kervand` soketi;
  link + sayfa adresi (Referer) + User-Agent gönderilir, çerez yt-dlp'de `--cookies-from-browser brave`
  ile alınır; aria2 ile inen düz dosyalarda eklenti o adresin çerezini başlık olarak geçer
- kurulum: `kervan extension install` native host manifest'ini yazar; eklenti "paketlenmemiş" yüklenir

**Bitti kriteri:** yt-dlp'nin desteklemediği, HTML5/HLS oynatıcılı bir sayfada rozet videoyu
gösterir; tek tıkla iner ve oynar. YouTube sayfasında "Sayfayı indir" 1080p mp4 indirir.
**Süre:** ~3–4 saat model işi.

**Sonuç:** headless Brave 156 + geçici profil + `--load-extension` ile uçtan uca denendi
(CDP üzerinden): yerel test sayfasında `<video>` mp4'ü ve fetch ile çekilen HLS ana listesi
yakalandı, alt liste gizlendi, rozet "2". Popup → native host → kervand zinciriyle mp4 indi
(Referer + tarayıcı User-Agent'ı, dosya adı sekme başlığından); HLS ikinci öğe "(2)" adını aldı ve
inmeye başladı; YouTube "Sayfayı indir" başlığı yt-dlp'den aldı. Testler: Swift 46, eklenti 7.
**Bulunanlar:** w3schools aria2'nin varsayılan User-Agent'ını 403 ile reddediyor → aria2 ve HEAD
artık tarayıcı kimliğiyle gidiyor. Aynı sayfa başlığıyla iki öğe aynı dosya adını alınca yt-dlp
"zaten var" deyip boş bitiyordu → ad benzersizleştirme.
**Kararlar:** çerezler aria2'ye geçirilmez ve diske yazılmaz (yt-dlp `--cookies-from-browser`
kullanır); eklentiye köprüde yalnız `ping/add/list` açık; eklenti kimliği manifest `key` ile sabit.
**Doğukan'ın Brave'inde denenmedi:** eklentiyi elle yükleyip gerçek bir sitede denemesi gerekiyor
(sağ tık menüsü ve bildirimler headless'ta denenemedi).

### M3.5 — IDM tarzı video üstü düğme + eklentiden kontrol ✅ (2026-10-23)
İstek (Doğukan): "durdurma iptal vs de olsun ve IDM'deki gibi sayfa yenilenince videonun üstünde çıksın".
- `content.js`: videonun sağ üst köşesinde "Bu videoyu indir" + seçenek menüsü
- popup: kuyrukta Durdur/Devam/İptal/Yeniden/Sil/Klasörde göster, ilerleme çubuğu, düğmeyi kapatma
- servis: `reveal` komutu; köprü kontrol komutlarına açıldı

**Sonuç:** headless Brave'de gerçek fare tıklamalarıyla: düğme 720×405 videonun köşesinde çıktı,
menüde "Bu video dosyası" + "Sayfadan indir", seçim kuyruğa gitti ve indi. Popup'ta HLS öğesi
Durdur → paused, Devam → downloading, İptal → canceled, Sil → kuyruktan çıktı. Eklenti testleri 9.
**Denenmedi:** gerçek sitelerde (Twitter, Instagram vb. kendi oynatıcılarıyla) düğmenin konumu;
tam ekran; `reveal` canlı (Finder açacağı için).

### M3.6 — Kalite seçimi, bildirim, HLS yüzdesi ✅ (2026-10-23)
İstek (Doğukan): "1-2-3 yap".
**Sonuç:** video üstü menüde HLS → kalite listesi (1080p60 ~614 MB … 270p) → 720p seçildi → 254,3 MB
(tahminle aynı), ffprobe 720p; ilerlemede yüzde + kalan süre göründü. `kervan formats` YouTube'da
2160p60…144p + ses. Swift 52 + eklenti 10 test.
**Değişen karar:** UserNotifications macOS 27'de pakete izin vermedi (bkz. ARCHITECTURE 4c) →
`osascript` bildirimi; tıklayınca dosya açma yok. Doğukan bildirimin ekranda göründüğünü teyit etti (2026-10-23).

### v0.5 — yt-dlp güncelleme, ayarlar, tür klasörleri, altyazı/MP3, uygulama ✅ (2026-10-23)
İstek (Doğukan): "2-3-4".
- **yt-dlp güncelleme**: Homebrew formülü 2 ay geride çıktı (brew 2026.8.19, GitHub 2026.10.21) →
  resmi `yt-dlp_macos` SHA-256 doğrulamalı olarak Application Support/Kervan/bin'e; `-U` ile günlük güncelleme,
  aktif indirme varken beklenir; yedek `brew upgrade`. Canlı: 2026.08.19 → 2026.10.21.
- **Ayarlar** (`settings.json`, `kervan config`, IPC): klasör, tür klasörleri, varsayılan kalite, altyazı,
  eşzamanlılık (canlı), otomatik güncelleme, pano izleme.
- **Tür klasörleri** (Video/Müzik/Belgeler/Arşivler/Programlar/Diğer), **altyazı gömme**, **MP3** (kapak + etiket).
  Canlı: `add -p mp3` → `~/Downloads/Kervan/Müzik/…mp3`, ffprobe kapak + başlık/sanatçı.
- **Kervan.app** (SwiftPM, `kervan app install`): menü çubuğu, IDM tarzı pencere, ekleme, ayarlar, pano izleme.
  Kendi penceresinin görüntüsü (`KERVAN_SNAPSHOT_DIR`) ile kontrol edildi: canlı ilerleme, hız, kalan.
- Testler: Swift 60, eklenti 10.
**Denenmedi:** menü çubuğu penceresi ve pano önerisi görsel olarak (ekran izni yok); oturum açılınca
başlatma (SMAppService) ad-hoc imzalı uygulamada çalışmayabilir — hata ayarlarda gösterilir.

## M4 — SwiftUI app MVP ✅ (v0.5'te, yukarıda)
- `app/` Xcode projesi, kök paketi yerel bağımlılık olarak kullanır; servise socket ile bağlanır
- ekranlar: Ekle (URL + preset + klasör), Kuyruk listesi (başlık, çubuk, hız, ETA, düğmeler),
  Detay (log), Ayarlar (eşzamanlılık, klasör, çerez tarayıcısı, araç yolları)
- servis/eklenti kurulu değilse ilk açılışta kurar

**Bitti kriteri:** terminal açmadan bir video eklenir, duraklatılır, devam ettirilir, biter.
**Süre:** ~2–3 saat model işi.

## M5 — UX cila
- bildirim (bitti/hata), dock yüzdesi, menü çubuğu simgesi
- ClipboardWatcher: "Link algılandı → ekle?" + yok sayma listesi
- sürükle-bırak; klasör seçici (security-scoped bookmark)

**Bitti kriteri:** linki kopyala → 3 sn içinde öneriyle kuyruğa; bitince bildirim; dock'ta yüzde.
**Süre:** ~1–2 saat model işi.

## M6 — Ekler: altyazı, ses, başlıklar (altyazı + MP3 v0.5'te ✅; elle başlık ve diğer tarayıcı çerezleri kaldı)
- altyazı: `--write-subs --sub-langs tr,en`, `--embed-subs`
- audio preset: mp3/m4a, `--embed-thumbnail --embed-metadata`
- HTTP: referer / User-Agent / özel başlıklar elle girilebilir
- Firefox ve Safari çerezleri (Safari: Full Disk Access gerekir), cookies.txt içe aktarma

**Bitti kriteri:** altyazı dosyası videoya gömülü; bir video mp3'e döner, kapak ve etiketler dolu.
**Süre:** ~1–2 saat model işi.

## M7 — Dağıtım
- araç dağıtımı kararı: Application Support'a indirme mi, gömme mi (lisans notlarıyla)
- dmg + codesign + notarization; güncelleme (Sparkle) kararı
- eklentiyi Chrome Web Store'a koyma kararı (ya da paketlenmemiş kalsın)
- opsiyonel: Safari Web Extension
- kullanıcı belgesi: kurulum, ilk indirme, çerez izinleri

**Bitti kriteri:** dmg Homebrew'suz başka bir Mac'te kurulup video indirir.
**Süre:** ~2–3 saat model işi (+ Apple Developer hesabı/notarization için Doğukan'ın adımları).

---

## Kapsam dışı
DRM'li servisler (Netflix, Disney+, Amazon Prime, Spotify; büyük ihtimalle Exxen/BluTV gibi
yerli platformlar da). Widevine/FairPlay şifrelemesini aşmak hem teknik hem hukuki olarak
dışarıda; IDM de bunları indiremez.

## Toplam
Kalan (M2–M7) ≈ **11–17 saat model işi**, aşama başına Doğukan'ın test turu ayrı.
En büyük belirsizlikler: site değişiklikleri (yt-dlp güncel tutulmalı), Brave'in eklenti
API kısıtları, Apple imzalama adımları.
