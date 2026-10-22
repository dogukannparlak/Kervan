# Kervan — Yol Haritası

> Her aşama çalışan bir araç bırakır. "Bitti kriteri" elle test edilebilir olmalı.
> Süreler, işi yapacak modelin (Claude) kod yazma süresidir; Doğukan'ın test süresi ayrı.

## M0 — Plan & Mimari ✅
- README, ARCHITECTURE, ROADMAP; 2026-10-23'te gözden geçirildi (ffmpeg M1'e,
  `kervand` servisi, URL sınıflandırma, çerez notları, Brave uzantısı).

## M1 — Paket + CLI tek indirme
Amaç: motoru GUI ve servis olmadan, ön planda çalıştırıp doğrulamak.
- `brew install ffmpeg`; `scripts/install-deps.sh` (yt-dlp, ffmpeg, aria2, deno kontrolü)
- kök `Package.swift`: `EngineCore`, `QueueKit` (boş iskelet), `kervan` hedefleri + testler
- `ProcessRunner`, `URLClassifier`, `YtDlpAdapter`, `Aria2Adapter` (tek seferlik RPC), `FFmpegLocator`
- `resources/presets/`: best, 1080p, 720p, audio
- komutlar: `kervan get <url> [--preset 1080p] [--dir ~/Downloads/Kervan]`, `kervan probe <url>`, `kervan doctor`
- MockProcess ile unit testler

**Bitti kriteri:** `kervan get` ile 1080p bir YouTube videosu **sesli tek mp4** olarak
iner, ilerleme satırı (yüzde · hız · ETA) güncellenir; `hello-2.12.tar.gz` aria2 ile iner;
ffmpeg yolu bozukken video açık hatayla reddedilir; `swift test` geçer.
**Süre:** ~1–2 saat model işi.

## M2 — `kervand` + kalıcı kuyruk
- QueueKit: GRDB/SQLite, state machine, retry/backoff, çökme kurtarma
- `kervand` LaunchAgent + Unix socket protokolü; `kervan service install|uninstall|status`
- CLI istemci: `add`, `list`, `pause`, `resume`, `cancel`, `retry`, `watch`, `log <id>`
- eşzamanlılık: global 3 + site başına 2
- playlist: `--flat-playlist` → çocuk öğeler

**Bitti kriteri:** 5 öğelik kuyruk sürerken `kervand` öldürülür; launchd yeniden
başlatınca 3. öğe `.part`'tan devam eder; bozuk bir URL 3 denemeden sonra `failed`
olur ve `kervan retry` ile yeniden kuyruğa girer.
**Süre:** ~2–3 saat model işi.

## M3 — SwiftUI app MVP
- `app/` Xcode projesi, kök paketi yerel bağımlılık olarak kullanır; servise socket ile bağlanır
- ekranlar: Ekle (URL + preset + klasör), Kuyruk listesi (başlık, çubuk, hız, ETA, düğmeler),
  Detay (log), Ayarlar (eşzamanlılık, klasör, araç yolları)
- servis kurulu değilse ilk açılışta kurar

**Bitti kriteri:** terminal açmadan bir video eklenir, duraklatılır, devam ettirilir, biter.
**Süre:** ~2–3 saat model işi.

## M4 — UX cila
- bildirim (bitti/hata), dock yüzdesi
- ClipboardWatcher: "Link algılandı → ekle?" + yok sayma listesi
- sürükle-bırak; klasör seçici (security-scoped bookmark)

**Bitti kriteri:** linki kopyala → 3 sn içinde öneriyle kuyruğa; bitince bildirim; dock'ta yüzde.
**Süre:** ~1–2 saat model işi.

## M5 — "Her şey"
- çerez: Brave/Chrome (Keychain onayı), Firefox, Safari (Full Disk Access), cookies.txt içe aktarma
- altyazı: `--write-subs --sub-langs tr,en`, preset'te seçilebilir
- playlist UX: grup, "x/45 indi", yalnız başarısızları yeniden dene
- HTTP: referer / User-Agent / özel başlıklar

**Bitti kriteri:** üyelik isteyen bir içerik Brave çereziyle iner; altyazı dosyası hedef klasörde.
**Süre:** ~2 saat model işi (+ Doğukan'ın gerçek hesaplarla testi).

## M6 — Ses çıkarma + gömme
- audio preset: mp3/m4a, `--embed-thumbnail --embed-metadata`
- video için `--embed-subs`, `--embed-chapters` seçenekleri

**Bitti kriteri:** bir video mp3'e döner; kapak ve etiketler dolu.
**Süre:** ~1 saat model işi.

## M7 — Brave uzantısı + dağıtım
- Brave/Chromium uzantısı (Manifest V3): sağ tık "Kervan'a gönder" + araç çubuğu düğmesi;
  `kervan://add?url=` URL scheme ile app'e köprü (gerekirse native messaging)
- sonra Safari Web Extension (opsiyonel)
- araç dağıtımı kararı: Application Support'a indirme mi, gömme mi (lisans notlarıyla)
- dmg + codesign + notarization; güncelleme (Sparkle) kararı
- kullanıcı belgesi: kurulum, ilk indirme, çerez izinleri

**Bitti kriteri:** Brave'deki sayfadan tek tıkla kuyruğa öğe düşer; dmg Homebrew'suz
başka bir Mac'te kurulup video indirir.
**Süre:** ~3–4 saat model işi (+ Apple Developer hesabı/notarization için Doğukan'ın adımları).

---

## Toplam
≈ **12–17 saat model işi**, aşama başına Doğukan'ın test turu ayrı. Tahminler kaba;
yt-dlp/YouTube kırılmaları ve Apple imzalama adımları en büyük belirsizlik.
