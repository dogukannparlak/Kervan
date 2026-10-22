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

## M2 — `kervand` + kalıcı kuyruk
- QueueKit: GRDB/SQLite, state machine, retry/backoff, çökme kurtarma
- `kervand` LaunchAgent + Unix socket protokolü; `kervan service install|uninstall|status`
- CLI istemci: `add`, `list`, `pause`, `resume`, `cancel`, `retry`, `watch`, `log <id>`
- eşzamanlılık: global 3 + site başına 2; playlist girişleri çocuk öğe
- öğe başına çerez tarayıcısı ve referer/başlıklar saklanır (M3'ün ihtiyacı)

**Bitti kriteri:** 5 öğelik kuyruk sürerken `kervand` öldürülür; launchd yeniden
başlatınca 3. öğe `.part`'tan devam eder; bozuk bir URL 3 denemeden sonra `failed`
olur ve `kervan retry` ile yeniden kuyruğa girer.
**Süre:** ~2–3 saat model işi.

## M3 — Brave eklentisi: video yakalama (IDM'in asıl gücü)
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

## M4 — SwiftUI app MVP
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

## M6 — Ekler: altyazı, ses, başlıklar
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
