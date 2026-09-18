# DURUM — LLM Test Makinesi Projesi

**Son güncelleme: 18 Eylül 2026.** Bu dosya projenin devir notudur. Yeni bir oturuma başlarken önce bunu oku.

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
   - Kip: **ACM** (15 Eyl 2026'da MEBx'ten; önceden CCM'deydi, aşağıya bak).
   - Teşhis: `sudo rpc amtinfo` (araç `/usr/local/bin/rpc`, rpc-go). `rpc activate/configure`
     komutları LMS olmadığı için 20 sn timeout + tekrar döngüsüne girer, **yavaş ama tamamlar**.
   - KVM yok (iGPU yok). SOL/IDER firmware'de VAR ama TLS-16993 istemcisi gerektirir (aşağıya bak).
   - **AMT artık ACM'de (15 Eyl 2026'da düzeltildi).** Önceden CCM'deydi ve tüm
     yönlendirme çağrıları (PXE/IDER/SOL) `AccessDenied` dönüyordu. Çözüm: MEBx'ten
     `Standard Manageability → Activate Network Access` + `User Consent → None`.
     Ölçüm: `OptInRequired=0`, `CanModifyOptInPolicy=1`, `ChangeBootOrder OK`.
     **Kritik incelik:** MEBx değişiklikleri sıcak reboot'la OTURMAZ — ME yarım
     kalır (UUID sıfırlanır, Remote Control kaybolur, boot sınıfları boşalır).
     Tam **G3 (fişten çek, 60 sn)** gerekir; ondan sonra UUID döner, her şey oturur.
     `tools/amt-check.py` ve `tools/amt-boot.py` (enum/status/pxe/hdd/bios,
     AMT_NORESET, Keychain parola) bu işi uzaktan yapar.
   - **Firmware yetenekleri (1 Eyl 2026'da ölçüldü, `tools/amt-check.py`):**
     ForcePXEBoot ✅ · ForceHardDriveBoot ✅ · ForceCDorDVDBoot ✅ · IDER ✅ · SOL ✅ ·
     BIOSSetup ✅ · BIOSPause ❌ · KVM ❌ (iGPU yok).
     WebUI bunların hiçbirini sunmaz; `tools/amt-boot.py` WS-MAN üzerinden kullanır.
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
   - Diskteki modeller: `qwen/qwen3.8-27b` (Q4_K_M) + `text-embedding-nomic-embed-text-v1.5`
   - systemd: `lmstudio.service` — `Type=oneshot` + `RemainAfterExit=yes`,
     `ExecStartPre=lms daemon up`, `ExecStop=lms daemon down`, `Environment=LMS_SERVER_HOST=0.0.0.0`.
     **`daemon up` şart**; sunucu onsuz ayağa kalkmaz.
   - **17 Eyl 2026 kararı: model açılışta YÜKLENMEZ** (`LMS_MODEL` varsayılanı boş, JIT kapalı).
     Sebep: makine GPU eğitim işleri için de kullanılacak; 17 GB model VRAM'de oturamaz.
     Yükleme istek üzerine: `lms-model load <anahtar>` / `unload` / `status`; açılışa
     sabitlemek isteyen `sudo lms-model pin <anahtar>` (systemd drop-in, bootstrap ezmez).
     Model yüklü değilken LiteLLM üzerinden gelen istek hata döner — bilinçli.
     15 Eyl'deki "JIT kapalı + model sabitleme" kararının sabitleme yarısı geri alındı.
6. **Eğitim ortamı (bootstrap adım 10) — format tatbikatı dahil test edildi ✅ (18 Eyl 2026)** —
   `/opt/egitim-venv` (**uv + Python 3.12**; torch 2.6.0+cu124, unsloth 2026.9.6, transformers 5.5,
   trl 0.24, peft 0.21, bitsandbytes 0.50, torchao 0.16), `/opt/llama.cpp` (`v0.4.1`, CPU, GGUF
   çevirme/niceleme), `HF_HOME=/mnt/models/hf`, NVMe önbelleği `/mnt/models/cache` (3.1 GB wheel).
   Ölçüm: önbellekten tam kurulum **190 s**, ikinci koşum **23 s**, sıfır indirme. Pinler
   `egitim/requirements.txt`. **Format tatbikatı (Koşu C) 18 Eyl'de yapıldı:** taze sistemde
   sürücü 196 s + reboot + kalan her şey 158 s (eğitim 66 s, internet kullanılmadı), ikinci koşum 30 s.
   Sistem Python 3.13 bu kümeyle KURULAMIYOR (xformers cp313 tekerleği yok) — uv-3.12 kalıcı karar.
7. **MeshCentral SIDER — 18 Eyl 2026'da KANITLANDI.** `https://100.101.117.47:4430` → cihaz →
   Intel AMT → **SIDER** → `Public/marvin-v3.iso` → Reset to IDE-R CDROM. ISO Pi'de, akış Pi'den;
   laptop bağımlılığı bitti. MeshCommander (ISO laptop'ta) yedek yol; yavaş bağlantıda IDER USB
   aygıtı flap edip kurulumcuyu takıyor (tur 1). **`asama=3` görünür görünmez SIDER'ı kes** — yoksa
   reboot yine sanal CD'den açar ve 10 sn'lik menü kurulumu baştan başlatır (tur 4'te yaşandı).
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

1. **`marvin-yeniden-kur`** — OS ayaktayken ISO'suz/IDER'siz sıfırdan kurulum: kurulumcu
   çekirdeği + initrd diske, tek seferlik GRUB girişi, aynı preseed; Pi'den tek komut. Ayrı PR.
   Kural: SSH varsa script, yoksa SIDER (REHBER §6).
2. **Preseed `late_command` sudo/hostname satırları bir sonraki kurulumda doğrulanacak** —
   18 Eyl'de eklendi (Pi'deki preseed şablondan yeniden üretildi) ama o turda elle yapıldı.
3. **Preseed render'ı senkrona bağlanmalı** — Pi'deki `preseed.cfg` şablon + parola karmasından
   üretiliyor; bugün elle üretildi. `llm-repo-sync`'e render adımı eklenirse şablon depoda
   değişince Pi kendiliğinden tazelenir (dünkü inceleme bulgusu; bugün bedeli ödendi).
2. ~~Router'da IP rezervasyonu~~ → 15 Eyl'de yapıldı. ~~JIT'i kapatma~~ → 15 Eyl'de yapıldı.
3. **(Opsiyonel) ISO'yu Pi'ye taşı** — MeshCentral sunucu taraflı IDER yapar, o zaman ISO
   Pi'de durur ve kurtarma laptop'a bağımlı olmaz. Şu an MeshCommander yeterli ama ISO
   tarayıcının olduğu makinede olmalı.

### İPTAL/ELENEN
- ~~Faz 5: Pi netboot~~ → **bu ağ topolojisinde imkânsız** (modem L2 izolasyonu; aşağıya bak).
  `netboot/` dosyaları duruyor ama başka bir switch/segment olmadan kullanılamaz.

### Bitenler (31 Ağu – 17 Eyl 2026)
- ✅ **18 Eyl: FORMAT TATBİKATI #2 (Koşu C) — SIDER ile, ofis dışından.** 4 kurulum turu
  (2'si `ahci` yüzünden sessiz takıldı, 1'i SIDER kesilmediği için kaza), sonunda taze sistem +
  bootstrap 7 dk. **13 bug** bulundu/düzeltildi (`egitim/TATBIKAT.md` §4) — en önemlileri:
  d-i `disk-detect` `ahci`'yi yüklemiyor (preseed artık `modprobe ahci` + tanı işaretleri +
  `2x-DISK-YOK`), parolasız sudo ve hostname preseed'de yoktu (eklendi), SIDER-kes zamanlaması,
  SSH host anahtarı, DKMS "derlendi" kontrolü. MeshCentral SIDER kanıtlandı; hostname `marvin`.
- ✅ **18 Eyl:** bootstrap adım 10 (eğitim ortamı + NVMe önbellek + `lms-model`) çalışan
  makinede üç turda oturdu; 7 bug düzeltildi. Model açılışta yüklenmiyor; `lms-model` doğrulandı.
- ✅ **15 Eyl:** AMT ACM'e alındı (MEBx + G3 reset) → uzaktan güç/reset/boot-order çalışıyor.
- ✅ **15 Eyl:** IP rezervasyonu yapıldı (modem, `60:cf:84:76:49:42` → `.114`).
- ✅ **15 Eyl:** BIOS "Wait for F1 If Error" kapatıldı — iki haftalık takılmanın sebebi.
- ✅ **15 Eyl:** `bootstrap.sh`'a `fsck.repair=yes` eklendi (açılışta otomatik onarım).
- ✅ **15 Eyl:** JIT kapatıldı + model açılışta sabitleniyor (ExecStartPost lms load).
- ✅ **15 Eyl: FORMAT TATBİKATI TAMAMLANDI.** marvin tamamen silindi ve uzaktan
  yeniden kuruldu; kullanıcı ofiste değilken. Kurulum preseed'den **5 dk 22 sn**
  (1,8 TB ext4 biçimlendirme dahil, paketler internetten). 17 GB model NVMe'de
  korundu (kurulumcuya hiç görünmedi). SSH anahtarı preseed ile geri geldi,
  bootstrap.sh çıkış kodu 0 ile tamamlandı, Pi→marvin→27B zinciri http=200 / 0,8 sn.
  **Tatbikatın bulduğu ve düzelttiği ALTI bug** (hepsi "yazıldı ama hiç çalıştırılmadı"):
  1. `linux-headers` kurulmuyordu → nvidia DKMS modülü hiç derlenmiyor, GPU ölü.
  2. Sürücü dalı kısır reboot döngüsüne giriyordu (reboot modülü derlemez).
  3. `ls a b | head` + `pipefail` → dosyalardan biri yoksa script çıkış 2 ile ölüyordu.
  4. `jq` taze Debian'da yok; JIT adımı sessizce atlanıyordu.
  5. Preseed `/dev/sda`'yı hedefliyordu ama IDER'in **boş sanal disketi** o adı kapıyor
     (gerçek disk `sdb`'ye kayıyor) → üç kurulum boşa gitti. Disk artık çalışma anında
     bulunuyor: çıkarılabilir olmayan ve >200 GB olan ilk disk.
  6. Model anahtarı taze kurulumda farklı (`qwen3.8-27b` vs `qwen/qwen3.8-27b`);
     `ExecStartPost=-lms load` sessizce başarısız oluyordu. Artık `lms ls` ile tespit ediliyor.
- ✅ **15 Eyl:** IDER KANITLANDI — marvin sanal CD'den Debian kurulum menüsüne açıldı.
  MeshCommander Pi'de servis olarak kuruldu. Uzaktan sıfırdan kurulum artık mümkün.
- ⛔ **15 Eyl:** Netboot elendi — modem L2 izolasyonu broadcast'i kesiyor (ARP testiyle kanıtlı).
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

## Netboot (Faz 5) — bu ağda ÖLÜ, IDER/SOL istemcisi de yok

**15 Eyl 2026 bulgusu:** Netboot bu topolojide kesinlikle çalışmıyor. ZTE modem
(H3600P) kablolu portları **L2 seviyesinde ayırıyor**: marvin'in ARP/DHCP broadcast'i
Pi'ye hiç ulaşmıyor (ARP testiyle kanıtlandı — marvin `.166`/`.200` için ARP yayınladı,
Pi 0 paket gördü). PXE başlıyor ("Start PXE over IPv4" ekranda görülüyor) ama Discover
yalnızca modeme gidiyor, Pi'deki dnsmasq proxy'ye ulaşmadığı için açılış dosyası
gelmiyor → siyah ekran → diske düşüyor. Modemde "port kontrolü hepsi açık" olsa da
izolasyon firmware'de gömülü, kapatılamıyor. dnsmasq/TFTP/preseed tarafı sağlam,
sorun tamamen ağ katmanı. `netboot/` dosyaları duruyor ama bu modemle kullanılamaz.

**IDER (uzaktan sanal CD) — 15 Eyl 2026'da ÇALIŞTIĞI KANITLANDI.** marvin sanal CD'den
Debian kurulum menüsüne açıldı. Yani makine tamamen ölse bile **uzaktan sıfırdan kurulabilir**.

Kurulum: Pi'de `meshcommander.service` (npm, systemd, `--port 3001 --any`) →
**http://100.101.117.47:3001** (tailnet'ten her yerden). Bağlantı: `192.168.1.114`,
**Digest / TLS** (port otomatik 16993), kullanıcı `admin`.

Akış: **IDER düğmesi → ISO seç → "Immediate" → oturum kurulur → Power Actions →
"Reset to IDE-R CDROM"**. Sıra önemli; oturum kurulmadan power action verilirse makine boş
sanal CD bulup diske düşer (zararsız).

**TUZAK — `ListenerEnabled=false`:** AMT'de `EnabledState=32771` (IDER+SOL açık) görünse bile
`ListenerEnabled` false ise IDER oturumu kurulamaz. İlk denememiz bu yüzden başarısız oldu.
Düzeltme: `AMT_RedirectionService.RequestStateChange(32771)` (PUT şema hatası verir, gerek yok).

**Oturumu durdurmadan boot rolü değişmez:** `UseIDER=true` iken `SetBootConfigRole` hata 5 döner.
Testten sonra MeshCommander'da IDER oturumunu durdur, makine diskten açılır.

**ISO nerede durur:** MeshCommander'da IDER protokolü **tarayıcıda** çalışır (`default.htm`),
Node sunucusu yalnızca ham TLS borusu (`/webrelay.ashx` → `tls.connect`). Yani ISO, tarayıcının
olduğu makinede olmalı — Pi'de değil. Kurtarma hâlâ "elinde ISO olan bir laptop" gerektirir.
Bunu kaldırmak için MeshCentral (sunucu taraflı IDER) gerekir; `amt-ider-module.js` sunucu
nesnelerine bağlı olduğu için bağımsız CLI/API yolu yok (meshcmd kaynağı repodan kaldırılmış).

**Test ISO'su:** `mini.iso` (64 MB, netboot dizini) tercih edilmeli — `netinst.iso` 756 MB ve
IDER kanalı yavaş olduğu için testi gereksiz uzatıyor. mini.iso gerçek kurulum için de yeterli
(paketleri internetten çeker, marvin LAN'da internete çıkıyor).

**Bunun yerine kanıtlanmış kurtarma zinciri:** AMT güç/reset (ACM) + `efibootmgr -n`
(OS ayaktayken aygıt seçimi) + BIOS "Wait for F1" kapalı + `fsck.repair=yes`
(bozuk dosya sistemi açılışta otomatik onarılır, insan beklemez).

## Uzaktan sıfırdan kurulum — nasıl yapılır (15 Eyl 2026'da kanıtlandı)

1. **MeshCommander**: http://100.101.117.47:3001 → `192.168.1.114`, **Digest/TLS**, `admin`
2. **IDER** düğmesi → ISO seç → **Immediate** → oturum kurulur
3. **Power Actions → Reset to IDE-R CDROM**
4. Menü 10 sn sonra otomatik kuruluma girer — **tuşa basmak yok**
5. Kurulum bitince **IDER oturumunu durdur**, makine diskten açılır
6. `ssh marvin` (anahtar preseed ile kuruldu) → `sudo bash /root/bootstrap.sh` (preseed oraya koyar; /tmp DEĞİL)

**ISO:** `marvin-v3.iso` (Pi'de `/opt/llm-repo`, ayrıca Mac'te `~/Downloads`).
`mini.iso`'dan (64 MB) türetilmiş; parametreler `boot/grub/grub.cfg`'ye gömülü:
`auto=true url=<pi>/preseed.cfg modprobe.blacklist=nvme log_host=<pi> console=ttyS0`.
Yeniden üretim: `netboot/` dizinindeki dosyalar + `xorriso -indev mini.iso -outdev ... -boot_image any replay -map`.

**ISO tarayıcıda okunur, Pi'de değil** — kurtarma hâlâ elinde ISO olan bir laptop ister.
Sunucu taraflı IDER için MeshCentral gerekir (bkz. Kalan işler).

**Kurulum görünürlüğü (bunlar olmadan kör kalırsın):**
- `log_host=192.168.1.166 log_port=514` → Pi'de `marvin-syslog.service` dinler,
  **http://192.168.1.166:8080/install.log** adresinden okunur. Asıl teşhis aracı budur.
- Aşama bildirimi: preseed `?asama=...` ile Pi erişim log'una iz bırakır.
- `console=ttyS0,115200n8` → AMT SOL ile canlı terminal.
- **Uyarı:** log'u `usb 1-16 reset` satırları boğabilir (IDER sanal aygıtı);
  okurken `grep -v "reset high-speed USB"` ile süz.

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
- **Test edilmemiş her kod yolu kırıktır.** 15 Eyl format tatbikatı `bootstrap.sh`'ta
  altı bug buldu; hepsi daha önce hiç çalışmamış dallardaydı (sürücü kurulumu, GRUB
  tespiti, model yükleme). "Yazdım, mantığı doğru" yeterli değil — çalıştırılmamış
  kod, ihtiyaç anında kırılır. Aynı desen netboot'ta ve `update-grub`'da da yaşandı.
- **Görünürlüğü baştan kur, sorunu sonra çöz.** `log_host` ile uzak syslog'u kurana
  kadar üç kurulum körlemesine denendi ve sebep bulunamadı. Kurulduktan sonra
  IDER sanal disketi sorunu tek satırda görüldü. Görünürlük sonradan eklemek pahalı.
- **Yetenek listesi ≠ kullanabilmek.** `AMT_BootCapabilities` PXE/IDER/SOL için "VAR"
  diyordu ve doğruydu — ama CCM hepsini kullanıcı onayı kapısının arkasına kilitliyor.
  Bir yeteneği "var" görmek yetmez; erişim politikasını (`IPS_OptInService`) da sorgula.
- **Aktivasyon kipi kritik bir mimari karardır, teknik ayrıntı değil.** CCM'e düşmek
  uzaktan yönetimi "sadece güç"e indirger ve bu ancak gerçek bir arızada fark edilir.
  MEBx aktivasyonu tutmadığı için CCM'e düşülmüş; o an pratik görünen tercih,
  1 Eylül'de makinenin uzaktan kurtarılamamasının doğrudan sebebi oldu.
- **Firmware'in yeteneklerini arayüze bakarak değil, firmware'e sorarak öğren.**
  AMT WebUI dar bir arayüzdür ve sunduğu seçenekler donanımın yapabildiklerinin
  tamamı değildir. `tools/amt-check.py` firmware'e `AMT_BootCapabilities` ile
  doğrudan sorar. Bu yapılmadığı için aylarca IDER ve SOL'un olmadığı sanıldı;
  ikisi de baştan beri varmış.
- **1 Eylül'deki iki haftalık "açılmıyor" krizinin sebebi donanım değil, BIOS'tu.**
  Journalctl'e göre makine düzgün çalışıyordu; 10:15-10:17'de üç kez elle yeniden
  başlatıldı, sonuncusu sert kesildi. Ardından ASUS'un **"Wait for F1 If Error"**
  ekranında takıldı (anormal güç olayı sonrası tuş bekler) ve AMT reset'leri hep
  aynı yere döndü. Ekran görülene kadar (15 Eyl) teşhis edilemedi. Ders: **açılmayan
  makinede ilk iş ekrana bakmaktır**; SSH/ping/AMT hepsi "ölü" gösterir ama gerçek
  sebep tek satırlık bir firmware istemi olabilir. BIOS'ta "Wait for F1" artık kapalı.
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
- ~~AMT ile ISO yönlendirme/KVM: ISM + KF'de yok~~ → **BU YANLIŞTI.** 1 Eylül 2026'da
  firmware'e `AMT_BootCapabilities` ile doğrudan soruldu: **IDER (uzaktan ISO) VAR**,
  **SOL (seri konsol) VAR**, **ForcePXEBoot VAR**. Yalnızca **KVM yok** (iGPU olmadığı için).
  Yanılgının kaynağı: AMT WebUI'ın dar arayüzüne bakıp hüküm verilmesi. WebUI yalnızca
  "Normal boot" sunuyor, ama WS-MAN arayüzü hepsini sunuyor.
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
