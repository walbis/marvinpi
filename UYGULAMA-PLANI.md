# Uçtan Uca Uygulama Planı — LLM Test Makinesi + Uzaktan Yönetim

## Durum tespiti (BIOS fotoğraflarından)
- Anakart ASUS (Aptio/AMI), üst menüde **MEBx sekmesi** ve Advanced altında ME/AMT sayfası var → kart uzaktan yönetim (Intel ME) destekli.
- İşlemci **i9-14900KF**: Intel spec sayfasına göre tam AMT/vPro yok, **Intel Standard Manageability (ISM)** var. F serisi = iGPU yok.
- Pratik sonuç:
  | Yetenek | Durum |
  |---|---|
  | Uzaktan güç aç / kapat / reset | ✅ (ISM ile) |
  | Makine kapalıyken erişim (fiş takılı) | ✅ |
  | BIOS ekranını uzaktan görme (Intel KVM) | ❌ (KF: iGPU yok, ISM: KVM yok) |
  | SOL metin konsolu / One-Click Recovery | ❓ BIOS'ta menüleri var, Faz 1'de test edilecek |
- 128 GB RAM bonusu: VRAM'e sığmayan büyük modellerde Ollama fazlasını RAM'e taşır (yavaşlar ama çalışır).

---

## ✅ Faz 0 + Faz 1 — TAMAMLANDI (31 Ağu 2026) — gerçekleşen durum
- **AMT aktif, kapalı makinede test edildi ve çalışıyor.** Aktivasyon MEBx yerine `rpc activate -local -ccm` ile yapıldı → kip **Client Control Mode (CCM)**. Güç aç/kapat/reset için fark yok.
- **Adres: `https://192.168.1.114:16993`** (kendinden imzalı sertifika uyarısını geç) · kullanıcı `admin` · şifre: AMT şifresi (kâğıtta).
- **16992 bu makinede hiçbir zaman açılmaz:** CSME 16.1 firmware TLS'siz portları (16992/16994/623) kaldırdı; sadece TLS portları (16993/16995/664) çalışır. Test ederken hep 16993 kullan.
- **AMT portu = `60:cf:84:76:49:42`** (Debian'da `enp6s0`). Diğer port (`…:43` / `enp7s0`) ME'ye bağlı değil. Kablo `:42`'de kalacak; router'da bu MAC'e **192.168.1.114 rezervasyonu** yap.
- ME kapalı makinede ping'e `ttl=255` ile cevap verir (Linux `ttl=64`) — "ME ayakta mı" hızlı testi.
- Araç: `/usr/local/bin/rpc` (rpc-go). `sudo rpc amtinfo` her zaman güvenilir; `activate`/`configure` komutları LMS olmadığı için 20 sn timeout + tekrar döngüsüyle **yavaş ama sonunda tamamlanıyor**, sabırlı ol.
- **Açık iş:** MEBx şifresi Unconfigure sonrası `admin`'e döndü → MEBx'e girip yeni şifre koy (CCM'de ağdan değiştirilemez, sadece yerinde). Activate Network Access'e **dokunma**.
- **Şifre unutulursa / ME bozulursa kurtarma:** BIOS → Advanced → AMT Configuration → Unconfigure ME: Enabled → F10 → Debian'da `sudo rpc activate -local -ccm -password 'YENİ'` → 1 dk sonra 16993 tekrar açılır.
- Serial Port Console Redirection bu BIOS'ta yok → BIOS ekranı uzaktan görülemez; gerekirse KVM kutusu.

## Faz 2 — Pi'den her yerden erişim (~15 dk)
En temiz yol Pi'yi **Tailscale subnet router** yapmak: telefondan/evden `https://192.168.1.114:16993` adresini doğrudan açarsın, MeshCommander'a gerek kalmaz; ayrıca formatlanmış/yeni kurulmuş makineye LAN IP'sinden SSH de bu yolla mümkün olur.
```bash
# Pi'de:
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-tailscale.conf && sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
sudo tailscale up --ssh --advertise-routes=192.168.1.0/24
```
Sonra Tailscale admin konsolu → Machines → llm-pi → **Edit route settings → 192.168.1.0/24'ü onayla**. Mac/telefonda Tailscale açıkken AMT paneline ofis dışından ulaşabilirsin.

İsteğe bağlı MeshCommander (SOL/ISO gibi ileri işler için): `npm install meshcommander` → makineyi eklerken **TLS** kutusunu işaretle, port 16993.

## Faz 2.5 — Veri diski (modeller format sonrası kalsın)
Boş NVMe/SATA slotuna disk tak → tek bölüm, ext4 → etiket: `sudo e2label /dev/sdX1 SILME-MODELLER`.
- Kök dizine `OKU-BENI-SILME.txt` koy (kime ait, neden silinmemeli, telefon).
- Diskin üstüne fiziksel etiket yapıştır.
- Gizli bölüm fikri **elendi**: kurulum sihirbazı zaten görür, "diski tamamen sil" ile uçar, mevcut sistemi bozma riski taşır. Ayrı disk + açık isim, gizlilikten daha iyi korur.
- `bootstrap.sh` bu etiketi arayıp bağlayacak; disk yoksa normal dizine düşecek (kurulum yine çalışır).

## Faz 3 — Model sunucusu: LM Studio headless (~30 dk + model indirme)
**Neden LM Studio (Ollama/vLLM değil):** REST API'si model listeleme/**yükleme/boşaltma/indirme** uçlarını içeriyor; llmster adlı bağımsız daemon ile GUI'siz çalışıyor, systemd ile açılışta başlatma resmi belgeli. JIT yükleme: istek gelince model belleğe alınır, boşta kalınca düşer. vLLM'de model konteyner başlarken sabitlenir, çalışma anında API'den değiştirilemez — vLLM'in üstünlüğü sadece tek modelde yüksek eşzamanlı yük. Bu makine "sürekli deneme" makinesi olduğu için esneklik kazandı.
1. Tailscale hesabı + **reusable auth key** üret.
2. Pi: `sudo bash pi-setup.sh` → master key'i sakla; `bootstrap.sh` + config'i `/opt/llm-repo/` içine kopyala.
3. Makine: LM Studio AppImage + `lms bootstrap` → llmster systemd servisi → model dizini `SILME-MODELLER` diskine. (Kurulum komutları makinede doğrulanıp `bootstrap.sh`'a işlenecek; resmi kaynak: lmstudio.ai/docs/developer/core/headless_llmster)
4. Pi'deki LiteLLM `api_base` → `http://llm-test:1234/v1`. Ekip sabit adrese (`http://<pi-ip>:4000/v1`) istek atar; model değişimi arkada API'den yapılır.
5. Tailscale admin → Machines → llm-test → **Disable key expiry**.
6. İleride tek model ekip tarafından yoğun kullanılırsa: o modeli ayrı portta vLLM ile aç, LiteLLM'e ikinci satır ekle. İkisi yan yana çalışır.

## Faz 4 — Tatbikat (~20 dk, güvence turu)
1. Makineyi kapat → AMT panelinden (`https://192.168.1.114:16993`) uzaktan aç. ✅ (31 Ağu'da doğrulandı)
2. `docker stop ollama` ile boz → `tailscale ssh llm-test` → `sudo bash bootstrap.sh` ile onar.
3. **Asıl sınav:** Debian'ı sıfırdan kurdur → tek satır komutla her şeyin geri geldiğini gör.
4. IP, MAC, AMT/MEBx şifresi ve auth key tarihini README'ye işle; auth key için 80. güne takvim hatırlatması koy.

---

# Faz 5 — Format sonrası kurtarma: Pi netboot (Faz 3 bittikten sonra)

**Neden netboot, neden diskte bölüm değil:** Kurtarma yolu makinenin dışında yaşar. Format, disk değişimi, diskin ölmesi — hiçbiri bozamaz, çünkü makinede silinecek bir şey yok. ISM'de ISO yönlendirme çalışmadığı için "uzaktan sıfırdan kurulum" senaryosunun tek gerçekçi yolu bu. Aynı diskte gizli bölüm fikri elendi: kurulum sihirbazları listeler, ilk `wipefs`'te uçar, emeği çok kazancı az.

**Altın kural — mevcut sistem bozulmasın:** netboot'un kendisi diske dokunmaz, riski preseed yaratır. İki katman birden uygula:
1. **Ağ boot'u varsayılan yapma.** BIOS boot sırasında disk ilk sırada kalsın. Netboot'u sadece ihtiyaç anında, AMT'nin "bir sonraki açılışta PXE" komutuyla tek seferlik tetikle.
2. **Menüyü savunmacı kur.** Varsayılan seçenek `local` (yerel diskten devam), zaman aşımı da ona düşsün. Yıkıcı kurulum ayrı satır olarak dursun, sadece bilerek seçilsin.

**Menü üç seçenek içerecek:**
| Seçenek | Diske etkisi | Ne zaman |
|---|---|---|
| `local` (varsayılan) | Yok | Her normal açılış |
| `rescue` — Tailscale'li live ortam | **Yok** | Sistem açılmıyor, disk kurtarılacak, teşhis gerek |
| `install` — preseed + bootstrap.sh | Diski siler | Bilerek sıfırdan kurulum |

**Kurulum adımları (Pi'de):**
1. `sudo apt install -y dnsmasq` → **proxy-DHCP modu** (router'ın DHCP'sine dokunmaz):
   ```
   # /etc/dnsmasq.d/netboot.conf
   port=0                          # DNS kapalı, sadece boot
   dhcp-range=192.168.1.0,proxy    # proxy modu: IP dağıtmaz
   dhcp-boot=netboot.xyz.efi
   pxe-service=x86-64_EFI,"Netboot",netboot.xyz
   enable-tftp
   tftp-root=/srv/tftp
   ```
2. Debian netinstall'ın UEFI netboot dosyalarını `/srv/tftp` altına aç, GRUB menüsünü yukarıdaki üç seçenekle yaz (varsayılan `local`, timeout 10 sn).
3. Preseed dosyasını Pi'nin mevcut dosya sunucusundan (`llm-repo`, port 8080) yayınla; `late_command` içinde `bootstrap.sh`'ı çağır → kurulum biter bitmez makine tailnet'e girer.
4. **Test sırası:** önce `local` seçeneğinin mevcut sistemi hiç etkilemediğini doğrula → sonra `rescue`'yu dene → `install`'ı en son ve bilerek test et.

**Tetikleme (uzaktan):** AMT panelinde Remote Control → boot device olarak PXE seç → Reset. Makine ağdan açılır, menüden `rescue` ya da `install` seçilir.

**Yedek katman (ağ yoksa):** Makinenin USB portunda sürekli takılı duran, Debian netinstall + `bootstrap.sh` içeren bir bellek. Router/Pi çökse bile çalışır; formatı yapan kişiye "kurulumu bundan yap" diyebileceğin somut nesne. ESP'ye rescue imajı koyma fikri elendi — kurulum sihirbazı ESP'yi yeniden biçimlendirince GRUB girdisi kaybolur, kırılganlığı bu USB'ye değmiyor.

**Pi tek arıza noktası:** gateway + dosya sunucusu + netboot artık Pi'de. SD kartın imajını düzenli yedekle.

---

## Bitmiş yapının katmanları (özet)
| Senaryo | Çözüm | Durum |
|---|---|---|
| Servis bozuldu, makine ayakta | `tailscale ssh llm-test` → `sudo bash bootstrap.sh` | Faz 3 |
| Makine donmuş / kapalı | AMT paneli → Power On / Reset | ✅ Çalışıyor |
| Ofis dışından erişim | Pi subnet router (Tailscale) | Faz 2 |
| Makine formatlandı | Pi netboot → preseed → bootstrap | Faz 5 |
| Ağ/Pi de çökmüş | USB bellek + makine başında kurulum | Faz 5 |
| Elektrik kesintisi | APM: Last State + WoL yedek | ✅ Ayarlı |

## Karar noktası — KVM kutusu gerekir mi?
Netboot çalışırsa **gerekmez**; "uzaktan sıfırdan kurulum" ihtiyacını o karşılıyor. Kutu (JetKVM ~70$ / Sipeed NanoKVM ~30$) sadece şu kalırsa anlamlı: BIOS'un **grafik** ekranını görme ihtiyacı (bu BIOS'ta Serial Console Redirection yok, KF'de iGPU yok → Intel tarafıyla imkânsız). Örnek: biri BIOS'ta boot sırasını bozarsa netboot da tetiklenemez, o an tek çare makinenin başına gitmek ya da KVM kutusu olur.
