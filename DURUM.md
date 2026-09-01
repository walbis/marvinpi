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
   1 Eylül'de içine `bootstrap.sh` + `KURTARMA-README.md` kondu; **öncesinde dizin boştu**, yani
   internetsiz kurtarma yolu kâğıt üzerindeydi.
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

1. **`bootstrap.sh`'a SSH anahtarı adımı** — format sonrası `authorized_keys` boş kalıyor; servis geri
   geliyor ama makineye girilemiyor. Planlanan: Pi'nin `:8080` adresinden public key listesini çekip
   kurmak. **Henüz eklenmedi.** Bu kapanmadan 5. madde (format tatbikatı) asıl iddiayı sınamış olmaz.
2. **Router'da IP rezervasyonu** — `60:cf:84:76:49:42` → `192.168.1.114`. LiteLLM bu IP'ye bağlı.
3. **JIT'i kapatma** — `lms server --help` / `lms --help` içinde config alt komutu aranacak (bulunamadı).
4. **Faz 5: Pi netboot** — dnsmasq proxy-DHCP + Debian netinstall + preseed. Menü: `local` (varsayılan,
   diske dokunmaz) / `rescue` (live, diske dokunmaz) / `install` (yıkıcı, bilerek seçilir).
   BIOS'ta ağ boot'u varsayılan YAPILMAYACAK; AMT'den tek seferlik PXE ile tetiklenecek.
5. **Faz 4: format tatbikatı** — sistemin sınavı. Temiz Debian (disk `sda`, NVMe'ye dokunma,
   SSH server seçili) → tek komut bootstrap → Pi'den curl → cevap gelmeli.
   Kurulum sırasında **NVMe'yi fiziksel olarak sökmek** en güvenlisi: kurulumcu görmediği diski silemez.

### Bitenler (31 Ağu – 1 Eyl 2026)
- ✅ `bootstrap.sh` LM Studio mimarisine göre sıfırdan yazıldı, çalışan makinede test edildi (idempotent).
- ✅ Reboot testi — soğuk açılışta doğrulandı.
- ✅ `KURTARMA-README.md` yeniden yazıldı; Ollama/Tailscale/docker referansları temizlendi.
- ✅ Repo yayınlandı: https://github.com/walbis/marvinpi
- ✅ Pi dosya sunucusu dolduruldu (internetsiz kurtarma yolu artık gerçek).

## Öğrenilen tuzaklar (tekrar düşme)

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
- `bootstrap.sh` erişimi geri getirmiyor (bkz. Kalan işler 1) — format sonrası ilk komut
  makinenin başında ya da şifreli SSH ile çalıştırılmak zorunda.
