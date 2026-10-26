# Kervan — Mac'te doğrulama ve kalan işler

Repo: dogukannparlak/Kervan, branch: `fix/inceleme-duzeltmeleri`. Bu branch'teki değişiklikler bulut
ortamında Mac olmadan yazıldı; CI'de (macOS) `swift build` + `swift test` ve eklenti testleri yeşil.
Ama arayüz, gerçek yt-dlp/aria2 indirmesi ve tarayıcı eklentisi hiç çalıştırılmadı. Görevin bunları
gerçek ortamda doğrulamak, bulduğun hataları düzeltmek ve 0. maddeyi teşhis etmek. Her adımın sonucunu
kısaca raporla; düzeltme gerekirse aynı branch'e küçük commit'lerle push et (önce `swift test`).

## 1. Hazırlık
```bash
git fetch origin && git checkout fix/inceleme-duzeltmeleri && git pull
scripts/install-deps.sh
brew list gnupg >/dev/null 2>&1 || brew install gnupg   # yt-dlp imza kontrolü için
swift build -c release && swift test
.build/release/kervan service install
.build/release/kervan extension install
.build/release/kervan app install
.build/release/kervan doctor
```
Sonra Doğukan'dan `brave://extensions` → Kervan → "Yeniden yükle" yapmasını iste (manifest 0.5.0 olmalı).

## 2. Servis ve CLI (sen çalıştır)
- `kervan add "https://www.youtube.com/watch?v=jNQXAC9IVRw" -w` → bitmeli. `kervan list` sıradayken boyut göstermeli.
- Aynı linki tekrar ekle → "zaten listede: #N (bitti)" + "--force" ipucu; `--force` ile eklenmeli.
- **Yarım dosya temizliği (en önemli kontrol):** uzun bir video ekle (ör. `aqz-KE-bpKQ`, `-p best`), %10–20'deyken
  `kervan cancel <id>`; indirme klasöründe `*.part`, `*.ytdl`, `*.part-Frag*`, `*.f*.mp4` kalmamalı.
  `kervan log <id>` "yarım dosyalar silindi: …" satırını göstermeli.
  Kalıyorsa: yt-dlp `--print "before_dl:KERVAN_PATH|%(filename)s"` satırının basılıp basılmadığına bak
  (log'da `KERVAN_PATH` yok mu?). Gerekirse alanı `%(filepath)s` ya da başka bir aşamaya (`pre_process`) çevir,
  `YtDlpAdapterTests`'e gerçek çıktıyla test ekle.
- Doğrudan dosya: `kervan add https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz` → bitmeli. Büyük bir dosyada iptal →
  dosya ve `.aria2` silinmeli.
- `kervan log 1 -n -5` → servis çökmeden "en az 1" hatası. `kervan clean` → bitenler listeden silinmeli, dosyalar kalmalı.
- `kervan update` → gpg kuruluysa sonuç; `~/Library/Application Support/Kervan/update-state.json`'da hata olmamalı.
  Hata varsa imza adımını incele (`ToolUpdater.verifySignature`).
- İnen bir dosyada: `xattr -p com.apple.quarantine <dosya>` → `0081;…;Kervan;…` görünmeli.
- `ls -ld ~/Library/Application\ Support/Kervan` → `drwx------`; `ls -l …/kervand.sock` → `srw-------`.

## 3. Uygulama (Doğukan'la birlikte, ekran gerektirir)
- Açılışta pencere açılmamalı, menü çubuğunda ↓ simgesi olmalı, Dock'ta simge olmamalı.
- Ayarlar → Görünüm: "Dock'ta göster" açınca Dock'a gelmeli, kapatınca gitmeli. "Menü çubuğunda göster" kapatınca
  simge gitmeli. İkisi de kapalıyken Kervan.app'e tekrar tıklayınca pencere açılmalı, araç çubuğundaki
  ⚙ ile ayarlara girilebilmeli. Uygulamayı kapatıp açınca tercihler korunmalı.
- Pencereye ve menü çubuğu penceresine Brave'den link sürükle-bırak → eklenmeli; playlist linki → ekleme sayfası açılmalı.
- İnen öğede İptal → onay penceresi; menü çubuğunda İptal → ikinci tıklamada (kırmızı ikon) iptal.
- Panoya YouTube linki kopyala → öneri; ⃠ düğmesi → o site bir daha önerilmemeli, Ayarlar'da listede görünmeli ve geri alınabilmeli.
- Aynı linki ⌘N ile tekrar ekle → hata + "Yine de ekle".
- Ayarlarda yazılamayan klasör seç (ör. `/System`) → kaydedilmemeli, hata görünmeli.

## 4. Eklenti (Brave'de, Doğukan'la)
- Popup açıkken kuyruk canlı güncellenmeli (yenilemeden). Etkinlik Monitörü'nde `kervan-native-host` popup başına
  tek süreç olmalı, popup kapanınca kaybolmalı.
- İnen öğede "İptal" → "Emin misin?" → ikinci tıklama iptal eder.
- Giriş isteyen bir sayfa (ör. yaş sınırlı YouTube videosu) → "Site giriş istiyor" + "Tarayıcı çerezleriyle dene" → çalışmalı.
- Yerel adres (ör. modem arayüzü `http://192.168.1.1/...` üzerinde sağ tık → Kervan ile indir) → "Yerel ağ adresi tarayıcıdan indirilemez".
- Video üstü düğme: menü ok tuşlarıyla gezilebilmeli; videosuz sayfalarda DOM'a `kervan-overlay` eklenmemeli.
- Sağ tık ile çok videolu sayfa → bildirimde "Hepsini ekle"; 1 dakika bekleyip (service worker uyusun) bas → yine çalışmalı.

## 5. YAPILACAKLAR 0. madde: menü çubuğu simgesi görünmüyor (teşhis)
Bu artık daha kritik: uygulama varsayılan olarak yalnız menü çubuğunda başlıyor.
```bash
osascript -e 'tell application "System Events" to tell process "KervanApp" to get description of every menu bar item of menu bar 2'
osascript -e 'tell application "System Events" to tell process "KervanApp" to get position of every menu bar item of menu bar 2'
```
- Öğe varsa ve konumu çentiğin arkasındaysa ya da Thaw/Bartender/Ice gibi bir araç gizliyorsa bunu Doğukan'a söyle
  (çözüm onların ayarında). Öğe yoksa `MenuBarExtra(isInserted:)` ile `showInMenuBar` tercihinin
  (`defaults read com.dogukan.kervan`) değerine bak.
- Sonucu `docs/YAPILACAKLAR.md` 0. maddeye yaz.

## 6. Kapanış
- Bulduğun her sorunu düzelt + test ekle + `swift test` + push. Düzeltemediğin şeyleri `docs/YAPILACAKLAR.md`'ye ekle.
- Hepsi tamamsa Doğukan'a `fix/inceleme-duzeltmeleri` → `main` için PR açmayı öner (kendin açma, sor).
- Açık kalanlar (bu turda yapılmayacak): hız sınırı/zamanlayıcı, tarayıcı indirmelerini yakalama, paralel parça (`-N 4`),
  Firefox/Safari çerezi ve cookies.txt, M7 dağıtım. Yerel ağ engeli DNS'i çözmez (bilinen sınır).
