[English](README.md) · **Türkçe**

# Kervan

> IDM benzeri, **yt-dlp tabanlı**, native macOS indirme yöneticisi.
> **Durum: v0.5 (2026-10-23)** — menü çubuğu uygulaması + arka plan servisi + Brave eklentisi.
> Videonun üstünde "İndir" düğmesi ve kalite seçimi, kuyruk (durdur/devam/iptal), bildirim, pano izleme,
> tür klasörleri, altyazı, MP3, yt-dlp'nin kendiliğinden güncellenmesi.
> Sıradaki işler: [`docs/YAPILACAKLAR.md`](docs/YAPILACAKLAR.md).

## Hızlı başlangıç

```bash
scripts/install-deps.sh                # yt-dlp, ffmpeg, aria2, deno
swift build -c release
.build/release/kervan service install  # kervand'ı LaunchAgent olarak kurar ve başlatır
.build/release/kervan extension install # Brave/Chrome/Edge köprüsü (Native Messaging)
.build/release/kervan app install       # ~/Applications/Kervan.app (menü çubuğu + pencere)
alias kervan=$PWD/.build/release/kervan

kervan add <url> [<url>…] -w           # kuyruğa ekle, -w: bitene kadar izle
kervan add <sayfa> --all               # sayfadaki bütün videolar (--items 1,3)
kervan list                            # ls; --all bitmişleri de gösterir
kervan watch                           # canlı tablo
kervan pause 3 · resume 3 · cancel 3 · retry 3 · rm 3
kervan log 3 -n 50
kervan formats <url>                   # kalite seçenekleri ve yaklaşık boyutlar (-p 720p gibi kullan)
kervan reveal 3                        # bitmiş dosyayı Finder'da göster
kervan get <url>                       # servissiz, ön planda tek indirme
kervan doctor                          # araçlar + servis + güncelleme durumu
kervan update                          # yt-dlp'yi şimdi güncelle (servis günde bir kez kendisi yapar;
                                       #   gpg kuruluysa yt-dlp imzası da doğrulanır: brew install gnupg)
kervan config [ad] [değer]             # ayarlar: maxParallel, categorize, subtitles, defaultPreset…
kervan service status | uninstall
```

Seçenekler (`add`/`get`): `-p best|1080p|720p|audio` ya da herhangi bir yükseklik (`480p`, `1440p`, `2160p`), `-d <klasör>` (varsayılan `~/Downloads/Kervan`),
`--cookies auto|none|brave|firefox…` (auto: site giriş isterse Brave çerezi), `--referer <sayfa>`,
`--name <dosya adı>`.

### Uygulama (Kervan.app)

- **Menü çubuğu** (↓ simgesi, inen sayısı): etkin indirmeler, durdur/devam, link yapıştırıp ekleme.
- **Pencere**: IDM tarzı tablo (ad, durum, ilerleme, boyut, hız, kalan), filtreler, araç çubuğu, sağ tık;
  çift tık dosyayı açar; ⌘N ekleme penceresi (kalite listesi, klasör, altyazı).
- **Ayarlar** (⌘,): indirme klasörü, tür klasörleri, varsayılan kalite, altyazı, eşzamanlılık,
  yt-dlp otomatik güncelleme, pano izleme, oturum açılınca başlatma.
- **Pano izleme**: video sitesi ya da dosya linki kopyalanınca sağ üstte "Kervan'a ekle" önerisi.
  "⃠" o siteyi bir daha önermez (Ayarlar'dan geri alınır).
- **Sürükle-bırak**: linki pencereye ya da menü çubuğu penceresine bırakınca kuyruğa eklenir.
- **Görünüm**: menü çubuğu uygulaması olarak başlar; Ayarlar'da "Menü çubuğunda göster" ve "Dock'ta göster".
  İkisi de kapalıysa arka planda çalışır; pencere için Kervan.app'i yeniden aç.

### Brave eklentisi (bir kez)

1. `kervan extension install`
2. `brave://extensions` → sağ üstte **Geliştirici modu** → **Paketlenmemiş öğe yükle** → bu repodaki `extension/`
3. Kimlik `ifkabkcjdlkjbgijfnphgecoggfjdgek` görünmeli.

Kullanım:
- **Videonun sağ üst köşesinde "Bu videoyu indir"** düğmesi çıkar (IDM gibi). Tıklayınca menü: videonun
  dosyası, yakalanan akışlar (HLS/DASH) ve "Sayfadan indir" (yt-dlp). Akış ya da sayfa seçilince **kalite
  listesi** gelir ("1080p60 · ~268 MB", "Yalnız ses"); YouTube gibi tek seçenekli sayfada doğrudan kalite listesi.
  "×" o video için gizler; popup'taki kutucuk hepsini kapatır.
- Araç çubuğundaki **K** simgesi: rozet yakalanan medya sayısı; pencerede **Sayfayı indir**, yakalanan
  medya için **İndir**, kuyrukta **Durdur / Devam / İptal / Yeniden / Sil / Klasörde göster**.
- Sağ tık → "Kervan ile indir": bağlantı, video ve sayfa için.
- İndirme bitince ya da hata verince **macOS bildirimi** gelir (playlist'te liste bitince bir kez).
- Eklentiden gelen isteklerde tarayıcı çerezi **kendiliğinden kullanılmaz**: site giriş isterse
  "Tarayıcı çerezleriyle dene" düğmesi çıkar. Yerel ağ adresleri (localhost, 192.168.x, `.local`…)
  eklentiden indirilemez; bunları uygulamadan ya da `kervan add` ile ekle.
- İnen öğeyi iptal etmek/silmek onay ister (popup'ta ikinci tıklama, uygulamada onay penceresi).

İnen dosyalara tarayıcıların yaptığı gibi macOS karantina etiketi konur (indirilen .app/.pkg Gatekeeper'dan geçer).

Eklenti testleri: `node --test extension/test/*.test.mjs`.

Plan, mimari ve yol haritası: [`docs/`](docs/).

Lisans: [MIT](LICENSE).
