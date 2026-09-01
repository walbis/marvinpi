# DURUM — LLM Test Makinesi Projesi

**Son güncelleme: 1 Eylül 2026.** Bu dosya projenin devir notudur. Yeni bir oturuma başlarken önce bunu oku.

## Amaç
Ofiste, başkaları tarafından her an formatlanabilen bir test makinesinde LLM servisi çalıştırmak.
Şartlar: makine bozulsa/formatlansa bile **uzaktan** toparlanabilmeli; API ile model ve parametre
yönetimi kolay olmalı; erişim tek bir güvenli kapıdan geçmeli.

## Donanım / Ağ

| | |
|---|---|
| Makine (hostname: `marvin`) | ASUS Pro WS W680-ACE · i9-14900KF · 128 GB RAM · **RTX 6000 Ada 48 GB** · Debian 13 (trixie) |
| Sistem diski | `sda` 1.8 TB → `/` (format edilecek disk BUDUR) |
| Model diski | `nvme0n1p1` 931 GB, ext4, etiket **`SILME-MODELLER`** → `/mnt/models` (fstab'da `nofail`) |
| LAN | `192.168.1.114` · arayüz `enp6s0` · MAC `60:cf:84:76:49:42` |
| NVIDIA sürücü | 550.163.01 |
| Raspberry Pi (`llm-pi`) | Tailscale `100.101.117.47` · LAN `192.168.1.166` · kullanıcı `noone` · 32 GB SD |

**Mimari kararı:** marvin tailnet'e **girmeyecek**. Pi tek giriş kapısı. Dışarıdan erişim: Pi (Tailscale
subnet router, `192.168.1.0/24` ilan edilmiş ve admin konsolunda onaylı) → LAN.

## Erişim

Mac'te `~/.ssh/config` (1 Eylül'de gerçekten kuruldu — öncesinde bu tanım yoktu, doküman yanılıyordu):
```
Host pi
    HostName 100.101.117.47
    User noone

Host marvin
    HostName 192.168.1.114
    User marvin
    ProxyJump pi
```
Pi'ye giriş **Tailscale SSH** ile olur (SSH anahtarı gerekmez, tailnet kimlik katmanıdır).
marvin'e giriş **SSH anahtarıyla** olur. `sudo` her iki makinede de şifre ister.

## Çalışan katmanlar (test edildi ✅)

1. **AMT (Intel Standard Manageability, CSME 16.1)** — makine kapalıyken uzaktan aç/kapat/reset.
   - Adres: **`https://192.168.1.114:16993`** · kullanıcı `admin`
   - **16992 ASLA açılmaz** — CSME 16.1 TLS'siz portları (16992/16994/623) kaldırdı. Hep 16993.
   - Kip: **CCM**, `rpc activate -local -ccm` ile aktive edildi (MEBx aktivasyonu tutmamıştı).
   - Teşhis: `sudo rpc amtinfo` (araç `/usr/local/bin/rpc`, rpc-go). `rpc activate/configure`
     komutları LMS olmadığı için 20 sn timeout + tekrar döngüsüne girer, **yavaş ama tamamlar**.
   - Bu BIOS'ta Serial Console Redirection **yok** + KF'de iGPU yok → BIOS ekranı uzaktan görülemez.
   - Şifre unutulursa: BIOS → Advanced → AMT Configuration → Unconfigure ME → Enabled → F10,
     sonra `sudo rpc activate -local -ccm -password 'YENİ'`.
2. **Pi gateway** — LiteLLM + Postgres (Docker, `/opt/llm-gw`), master key `.env` içinde (chmod 600).
   Endpoint: `http://100.101.117.47:4000/v1` · `Authorization: Bearer <key>`
   Sağlık: `curl http://100.101.117.47:4000/health/liveliness` → `"I'm alive!"`
3. **Pi dosya sunucusu** — `llm-repo.service` (`python3 -m http.server 8080 --directory /opt/llm-repo`).
   1 Eylül'de içine `bootstrap.sh` + `KURTARMA-README.md` + `DURUM.md` kondu; **öncesinde dizin
   boştu**, yani internetsiz kurtarma yolu kâğıt üzerindeydi.
   **`llm-repo-sync.timer`** (günlük, `Persistent=true`) dosyaları GitHub'dan tazeler:
   indirme başarısızsa eldeki kopya korunur, `.sh` dosyaları `bash -n` ile doğrulanır,
   bozuk inen script yerine konmaz. `authorized_keys` bilerek senkron listesinde değildir.
   Elle tetikleme: `sudo /usr/local/bin/llm-repo-sync`
4. **LM Studio marvin'de** — `~/.lmstudio/bin/lms`, port **1234**, `--bind 0.0.0.0`.
   - Model dizini: `~/.lmstudio/models` → **symlink** → `/mnt/models/lmstudio` (17 GB, 2 adet .gguf)
   - Yüklü model: `qwen/qwen3.8-27b` (Q4_K_M) + `text-embedding-nomic-embed-text-v1.5`
   - systemd: `lmstudio.service` — `Type=oneshot` + `RemainAfterExit=yes`,
     `ExecStartPre=lms daemon up`, `ExecStop=lms daemon down`, `Environment=LMS_SERVER_HOST=0.0.0.0`.
     **`daemon up` şart**; sunucu onsuz ayağa kalkmaz.
5. **Güvenlik duvarı** — ufw etkin, `192.168.1.0/24` için 22 ve 1234 açık.
6. **Uyku kapatıldı** — `sleep/suspend/hibernate/hybrid-sleep` mask, varsayılan hedef `multi-user.target`.
7. **Wake-on-LAN** — `wol.service` (ethtool ile `wol g`), 1 Eylül'de bootstrap tarafından kuruldu.
8. **Uçtan uca zincir ✅** — Pi'den atılan curl 27B modelden cevap aldı (~11 sn).
9. **Soğuk açılış testi ✅** — makine kapatılıp açıldı: `lmstudio.service` kendiliğinden ayağa kalktı,
   model diski fstab'dan otomatik bağlandı, Pi'den gelen istek cevap aldı.
10. **Kurtarma yolu ✅** — `bootstrap.sh` iki kaynaktan da indirilip doğrulandı (aynı sha256):
    `https://raw.githubusercontent.com/walbis/marvinpi/main/bootstrap.sh` ve `http://192.168.1.166:8080/bootstrap.sh`

**Neden LM Studio (Ollama/vLLM değil):** REST API'si model **yükleme/boşaltma/indirme** uçları içeriyor,
çalışma anında API'den model değiştirilebiliyor. vLLM'de model konteyner başlarken sabitlenir.
İleride tek model yoğun kullanılırsa vLLM ayrı portta açılıp LiteLLM'e ikinci satır olarak eklenebilir.

## Kalan işler (öncelik sırasıyla)

1. **Router'da IP rezervasyonu** — `60:cf:84:76:49:42` → `192.168.1.114`. LiteLLM bu IP'ye bağlı.
2. **JIT'i kapatma** — `lms server --help` / `lms --help` içinde config alt komutu aranacak (bulunamadı).
3. **Faz 5: Pi netboot** — dnsmasq proxy-DHCP + Debian netinstall + preseed. Menü: `local` (varsayılan,
   diske dokunmaz) / `rescue` (live, diske dokunmaz) / `install` (yıkıcı, bilerek seçilir).
   BIOS'ta ağ boot'u varsayılan YAPILMAYACAK; AMT'den tek seferlik PXE ile tetiklenecek.
4. **BIOS'ta boot sırası `[disk → ağ]`** — fiziksel erişim gerektirir. AMT bu donanımda
   tek seferlik PXE'yi **zorlayamıyor** (bkz. Öğrenilen tuzaklar), bu yüzden netboot'un
   tetiklenmesinin tek yolu firmware'in ağa düşmesi. Sıra `[disk → ağ]` olduğunda normal
   açılışlarda ağa hiç sıra gelmez; sadece disk açılamadığında devreye girer — yani tam
   olarak kurtarmaya ihtiyaç duyulan anda.
5. **Faz 4: format tatbikatı** — sistemin sınavı. Temiz Debian (disk `sda`, NVMe'ye dokunma,
   SSH server seçili) → tek komut bootstrap → Pi'den curl → cevap gelmeli.
   Kurulum sırasında **NVMe'yi fiziksel olarak sökmek** en güvenlisi: kurulumcu görmediği diski silemez.
   Artık `bootstrap.sh` SSH anahtarını da geri kurduğu için bu tatbikat gerçekten
   "uzaktan tek komut" iddiasını sınar.

### Bitenler (31 Ağu – 1 Eyl 2026)
- ✅ `bootstrap.sh` LM Studio mimarisine göre sıfırdan yazıldı, çalışan makinede test edildi (idempotent).
- ✅ Reboot testi — soğuk açılışta doğrulandı.
- ✅ `KURTARMA-README.md` yeniden yazıldı; Ollama/Tailscale/docker referansları temizlendi.
- ✅ Repo yayınlandı: https://github.com/walbis/marvinpi
- ✅ Pi dosya sunucusu dolduruldu (internetsiz kurtarma yolu artık gerçek).
- ✅ `bootstrap.sh`'a SSH anahtarı adımı eklendi: Pi'nin `:8080/authorized_keys` adresinden
  public key listesini çekip kurar. Var olan anahtarlar korunur, mükerrer satır eklenmez,
  indirilen içerik public key değilse dosyaya hiç dokunulmaz. Makinede test edildi
  (`0 yeni / 1 toplam`, izinler `600 marvin:marvin`, `.ssh` `700`).
- ✅ `llm-repo-sync.timer` kuruldu: dosya sunucusu artık GitHub'dan kendini tazeliyor.
  Elle senkron unutulduğu için Pi bir gün boyunca SSH anahtarı adımı olmayan eski
  `bootstrap.sh`'ı servis etmişti — hata vermeden. Bu sınıf arıza kapatıldı.
- ✅ `pi-setup.sh` gerçekle hizalandı: LiteLLM yapılandırmasını hâlâ eski Ollama
  adresiyle (`ollama_chat/qwen3:14b`, `http://llm-test:11434`) üretiyordu; Pi yeniden
  kurulsa gateway var olmayan endpoint'e bakardı. Artık `MODEL_BASE`/`MODEL_NAME`.
- ✅ WoL doğrulandı: `Wake-on=g`, kart desteği `pumbg`. Önceki "g değil" uyarısı
  `ethtool` çıktısını yanlış ayrıştıran bir bug'dı, düzeltildi.

## Öğrenilen tuzaklar (tekrar düşme)

- **Subnet çakışması Pi'nin subnet router'ını sessizce işlevsiz bırakıyor.** Ofis LAN'ı
  `192.168.1.0/24`; bulunduğun ağ da aynı aralığı kullanıyorsa (ev router'larının en yaygın
  varsayılanı) yerel rota Tailscale rotasını yener ve `192.168.1.114` ofise değil kendi ağına
  gider. Hata mesajı yoktur, sadece "ulaşamıyorum" olur. 1 Eylül'de evden AMT'ye
  erişilememesinin sebebi buydu.
  **Çözüm — SSH tüneli** (çakışmayı tamamen atlar):
  ```
  ssh -f -N -L 16993:192.168.1.114:16993 pi
  ```
  sonra tarayıcıda `https://localhost:16993/`. Aynı yöntem herhangi bir LAN servisi için
  kullanılabilir (ör. marvin'in 1234 portu: `-L 1234:192.168.1.114:1234`).
  Kalıcı çözüm ofis LAN'ını daha ender bir aralığa taşımak olurdu (ör. `10.42.0.0/24`).
- **AMT bu donanımda tek seferlik PXE boot'u ZORLAYAMIYOR.** Remote Control sayfasındaki
  "Select a boot option" listesinde yalnızca *Normal boot* çıkıyor; PXE/Network seçeneği
  yok (ISM, tam AMT değil). Planın "AMT'den tek seferlik PXE ile tetiklenecek" varsayımı
  yanlıştı ve bu ancak gerçek bir arızada, 1 Eylül'de anlaşıldı. Netboot'un tetiklenmesi
  BIOS boot sırasının `[disk → ağ]` olmasına bağlı — bu da bir kez fiziksel erişim ister.
- **Uzaktan görüş sıfır.** KVM yok, SOL yok, AMT yalnızca güç veriyor. Makine açık ama
  işletim sistemi ayağa kalkmıyorsa uzaktan yapılabilecek TEK şey reset atmaktır; o da
  tutmazsa makinenin başına gitmek zorunludur. 1 Eylül'de tam olarak bu yaşandı.
- **Kapalı makine de ping'e cevap verir.** ME cevaplar, `ttl=255`. Çalışan Linux `ttl=64`. TTL'e
  bakmadan "ping var ama SSH yok" görüp güvenlik duvarı sanma — bu hata bir kez yapıldı ve
  gereksiz yere "fiziksel erişim gerekiyor" sonucuna varıldı. AMT portunun açık olması da
  makinenin açık olduğu anlamına gelmez; AMT zaten kapalı makinede çalışır.
- **ufw'de sıra hayati.** İzin kuralları `enable`/`default deny`'dan **önce** yazılmalı ve
  doğrulanmalı. Ters sıra makineyi ağdan kilitler: ping açık, tüm TCP kapalı — ve bu donanımda
  KVM/SOL olmadığı için kurtarma fiziksel erişim gerektirir.
- **LM Studio root'a kurulmamalı.** `sudo` ile installer çağrılırsa `/root/.lmstudio`'ya gider ve
  servis çalışmaz. Hedef kullanıcıya `sudo -u ... -H` ile kurulmalı.
- **Model diski bağlı değilken symlink kurulmamalı.** Kurulursa LM Studio modelleri sistem diskine
  indirir; hem `sda` şişer hem format sırasında uçar — ayrı diskin bütün amacı buydu.
- **`ethtool` çıktısında `Wake-on:` iki kez geçer** (`Supports Wake-on: pumbg` ve `Wake-on: g`).
  Desen satır başına sabitlenmezse yanlış alan okunur.
- **qwen3 bir reasoning modeli.** Küçük `max_tokens` tamamen düşünme aşamasında tükenir, cevap boş
  görünür (`finish_reason: "length"`, `reasoning_tokens` dolu). 512 ve üzeri güvenli.
- **PATH `.bashrc`'ye eklenmemeli.** Installer tekrar tekrar çalıştırılınca satır yığıyor
  (makinede üç mükerrer satır oluşmuştu). `/etc/profile.d/` altında tek dosya doğrusu.

## Elenen fikirler (tekrar önerme)
- Aynı diskte gizli bölüm: kurulum sihirbazı görür, `wipefs` ile uçar. Ayrı disk + açık `SILME-` adı daha korur.
- ESP'ye rescue imajı: kurulum ESP'yi yeniden biçimlendirince kaybolur. Yerine USB bellek yedeği.
- AMT ile ISO yönlendirme/KVM: ISM + KF'de yok. Uzaktan kurulum netboot ile çözülecek.
- Mac'te iki tailnet aynı anda: Tailscale tek düğüm = tek tailnet. Hesap değiştirme gerekiyor.

## Riskler
- BIOS'ta "Load Optimized Defaults" → APM/Boot ayarları gider (AMT kaydı firmware'de, genelde kalır).
- Pi tek arıza noktası (gateway + dosya sunucusu + netboot). SD kart imajını yedekle.
- Repo public: script'lerde secret yok ama iç ağ topolojisi (MAC/IP) README'de görünüyor.
- SSH anahtarı zinciri Pi'ye bağlı: `bootstrap.sh` anahtarları `:8080/authorized_keys`
  adresinden çeker. Pi çökerse veya `/opt/llm-repo` boşalırsa format sonrası makineye
  girilemez (kurulum yine tamamlanır, sadece uyarı basar). `authorized_keys` senkronla
  tazelenmez — repoda yoktur; SD kart yedeğine dahil et.
- **Çalışan sistem ile onu yeniden üreten script birbirinden ayrışabiliyor.** İki kez
  yaşandı: elle düzeltilen LiteLLM yapılandırması `pi-setup.sh`'a yansımamıştı, ve Pi'nin
  servis ettiği `bootstrap.sh` elle senkron unutulduğu için eskimişti. İkisi de hata
  vermeden, yalnızca gerçek bir kurtarma anında ortaya çıkacak cinstendi. Bir şeyi
  makinede elle düzeltirsen script'e de işle.
