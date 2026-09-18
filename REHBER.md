# marvin — Kurulum ve Kurtarma Rehberi

*Son güncelleme: 17 Eylül 2026. Kaynak: Claude Doc (marvin — Kurulum ve Kurtarma Rehberi).*

Ofisteki LLM test makinesinin tam belgesi: ne olduğu, nasıl erişileceği, bozulduğunda nasıl kurtarılacağı. Hiç bilgisi olmayan biri bu belgeyle sistemi devralabilir.

## 1. Bu sistem nedir

Ofiste, **başkalarının her an formatlayabileceği** bir masaüstü bilgisayarda büyük dil modeli (LLM) servisi çalıştırıyoruz. Makinenin adı **marvin**.

Temel varsayım şu: marvin geçicidir. Biri gelip diskini silebilir, biri kapatabilir, bir açılış hatası onu haftalarca erişilemez bırakabilir. Bu yüzden sistem "makine bozulmasın" diye değil, **"bozulduğunda hızlıca ve uzaktan geri gelsin"** diye tasarlandı. Sunucu dünyasında buna *cattle, not pets* denir: makineye can simidi gözüyle bakmazsın, yerine yenisini koyarsın.

İki makine var ve rolleri kesin olarak ayrı:

|  | **marvin** | **llm-pi** (Raspberry Pi) |
| --- | --- | --- |
| Rolü | LLM'i çalıştıran güçlü makine | Kalıcı çapa — hiç formatlanmaz |
| Üzerinde ne var | GPU, modeller, LM Studio | Ağ geçidi, dosya sunucusu, yönetim arayüzleri |
| Silinebilir mi | **Evet, tasarım gereği** | Hayır — silinirse kurtarma yolu kaybolur |
| Dış dünyaya açık mı | Hayır, sadece ofis LAN'ında | Evet, Tailscale ile her yerden |

Pi küçük ve ucuz bir bilgisayar ama sistemin hafızası o: marvin'e nasıl ulaşılacağını, nasıl yeniden kurulacağını ve kurulum dosyalarını o tutuyor. marvin silindiğinde Pi ona "kendini nasıl yeniden kuracağını" anlatıyor.

### Neden bu kadar uğraş gerekti

Sıradan bir sunucuda "bozulursa gider bakarım" yeterlidir. Burada iki şey bunu zorlaştırıyor:

1. **Makinenin ekranı uzaktan görülemiyor.** İşlemci (i9-14900**KF**) dahili grafik birimi içermiyor, bu yüzden anakartın uzaktan yönetim özelliği ekran görüntüsü aktaramıyor. Yani "ekranda ne yazıyor?" sorusunun cevabı normalde yok.
2. **Ofise gitmek pahalı.** 2026 Eylül başında makine iki hafta erişilemez kaldı; sebep ekranda yazan tek satırlık bir mesajdı ve kimse görmediği için teşhis edilemedi. (Detayı: 9. Bilinen tuzaklar)

Bu belgedeki her şey o iki sorunu çözmek için var.

### Bugün ne yapabiliyoruz

- Makineyi **uzaktan açıp kapatabiliyoruz** — işletim sistemi çökmüş olsa da, makine kapalıyken de.
- Makineyi **uzaktan sıfırdan kurabiliyoruz** — disk tamamen silinip Debian yeniden kuruluyor, yaklaşık 5,5 dakikada.
- Kurulumun **kayıtlarını uzaktan okuyabiliyoruz** — artık ekrana bakmaya gerek yok.
- Ve bütün bunlar olurken **17 GB'lık model dosyaları hiç silinmiyor.**

Bunların hiçbiri bu çalışma başlamadan önce mümkün değildi.

## 2. Donanım ve diskler — özellikle silinmeyen disk

### marvin

|  |  |
| --- | --- |
| Anakart | ASUS Pro WS W680-ACE |
| İşlemci | Intel i9-14900KF (**KF = dahili grafik yok**) |
| RAM | 128 GB |
| Ekran kartı | NVIDIA RTX 6000 Ada, 48 GB |
| İşletim sistemi | Debian 13 (trixie) |
| NVIDIA sürücü | 550.163.01 |
| LAN adresi | `192.168.1.114` (modemde MAC'e rezerve edildi) |
| Ağ arabirimi | `enp6s0`, MAC `60:cf:84:76:49:42` |

### llm-pi (Raspberry Pi)

|  |  |
| --- | --- |
| Tailscale adresi | `100.101.117.47` |
| LAN adresi | `192.168.1.166` |
| Kullanıcı | `noone` |
| Depolama | 32 GB SD kart |

### İki disk, iki farklı kader

marvin'de **iki ayrı fiziksel disk** var ve aralarındaki fark bu projenin en önemli tasarım kararı:

|  | **Sistem diski** | **Model diski** |
| --- | --- | --- |
| Aygıt | `sda` (SATA) | `nvme0n1p1` (NVMe) |
| Boyut | 1,8 TB | 931 GB |
| Etiket | — | **`SILME-MODELLER`** |
| Nereye bağlanır | `/` (kök dizin) | `/mnt/models` |
| İçeriği | Debian, LM Studio, ayarlar | 17 GB model dosyası (.gguf) |
| Format edilir mi | **Evet — her kurtarmada silinir** | **Hayır — asla** |

Disk etiketine bilerek büyük harfle **`SILME-MODELLER`** adı verildi. Sebep sosyal: makineyi elle formatlayacak kişi disk listesinde bu adı gördüğünde ne yapmaması gerektiğini anlar. Teknik korumaların hepsi başarısız olsa bile geriye bu kalır.

### Diskte ne var

- `qwen/qwen3.8-27b` (Q4\_K\_M niceleme) — asıl sohbet modeli, yaklaşık 17 GB
- `text-embedding-nomic-embed-text-v1.5` — metin gömme modeli

LM Studio bu dosyaları normalde `~/.lmstudio/models` altında arar. O dizin gerçek bir klasör değil, `/mnt/models/lmstudio` adresine giden bir **symlink** (kısayol). Yani LM Studio sistem diskinde çalışır ama modelleri model diskinden okur.

### Bu disk nasıl korunuyor — üç katman

**1. Kurulum anında görünmez yapılıyor.** Uzaktan kurulum ISO'sunun açılış parametrelerinde `modprobe.blacklist=nvme` var. Bu, Debian kurulum programının NVMe sürücüsünü hiç yüklememesi demek. Kurulum programı diski **görmez**; görmediği diski listeleyemez, seçemez, silemez. Kurulum bitip sistem normal açıldığında NVMe sürücüsü yüklenir ve disk geri gelir.

**2. Hedef disk çalışma anında seçiliyor.** Kurulum tanımına (preseed) sabit `/dev/sda` yazılmıyor. Onun yerine şu kural çalışıyor: *çıkarılabilir olmayan ve 200 GB'tan büyük ilk diski seç.* Bunun sebebi acı bir deneyim — uzaktan kurulumda kullanılan sanal disket sürücüsü `/dev/sda` adını kapıyor ve gerçek disk `/dev/sdb`'ye kayıyor. Üç kurulum bu yüzden boşa gitti.

**3. `bootstrap.sh` symlink'i sadece disk gerçekten bağlıysa kuruyor.** Kurulum sonrası çalışan betik diski etiketinden (`SILME-MODELLER`) bulur, `/mnt/models` altına bağlar ve ancak ondan sonra symlink'i kurar. Disk yoksa **symlink'i bilerek kurmaz** ve uyarı basar. Sebebi şu: symlink hedefsiz kalırsa LM Studio onu sıradan bir klasör sanıp modelleri **sistem diskine** indirir — ki bir sonraki formatta hepsi uçar. Ayrı diskin bütün amacı bu olurdu.

Ayrıca `/etc/fstab` kaydı `nofail` seçeneğiyle yazılır: model diski takılı değilse makine yine de açılır, açılış ekranında takılıp kalmaz.

### Kanıt

15 Eylül 2026'da yapılan format tatbikatında sistem diski tamamen silindi ve Debian sıfırdan kuruldu. Kurulum bittikten sonra model diski olduğu gibi duruyordu; 17 GB'lık model tekrar indirilmedi, LM Studio ilk çalıştırmada modeli buldu. Bu, teoride değil pratikte doğrulandı.

> **Uyarı:** Biri makineyi *elle*, USB'den Debian kurarak formatlarsa bu korumaların hiçbiri devreye girmez — `modprobe.blacklist=nvme` sadece bizim ISO'muzda var. O kişiye söylenecek tek şey: **sistem diski `sda`, NVMe'ye dokunma.** En güvenlisi kurulum sırasında NVMe'yi fiziksel olarak sökmektir.

## 3. Nasıl erişilir

### Temel kural: her şey Pi'den geçer

marvin **dış ağa açık değil** ve Tailscale VPN'ine de dahil edilmedi. Bunun sebebi bilinçli: marvin her an formatlanabilir, formatlandığında VPN kimliği de uçar ve geri gelmesi elle iş gerektirir. Bunun yerine **Pi tek giriş kapısı**: Pi hep VPN'de, hep ayakta, ve ofis ağını (`192.168.1.0/24`) VPN'e duyuruyor (buna *subnet router* denir).

```
Senin bilgisayarın  ──Tailscale──>  Pi (100.101.117.47)  ──ofis LAN──>  marvin (192.168.1.114)
```

### SSH ayarı

Mac'te `~/.ssh/config` dosyasına:

```
Host pi
    HostName 100.101.117.47
    User noone

Host marvin
    HostName 192.168.1.114
    User marvin
    ProxyJump pi
```

Bundan sonra iki komut yeter:

```bash
ssh pi
```

```bash
ssh marvin
```

`ssh marvin` otomatik olarak Pi üzerinden atlar (`ProxyJump`), yani ofis dışından da çalışır.

**Kimlik doğrulama:** Pi'ye giriş Tailscale SSH ile olur, ayrı anahtar gerekmez — VPN'e girmiş olman yeterli kimliktir. marvin'e giriş **SSH anahtarıyla** olur; anahtarın kurulumu `bootstrap.sh`'ın işi (bkz. 7. bootstrap.sh). Anahtar yoksa: `ssh-copy-id marvin@192.168.1.114`.

### Adres ve port listesi

| Ne | Adres | Not |
| --- | --- | --- |
| LLM API (önerilen) | `http://100.101.117.47:4000/v1` | Pi'deki LiteLLM geçidi, API anahtarı ister |
| LLM API (doğrudan) | `http://192.168.1.114:1234/v1` | Sadece LAN içinden, anahtarsız |
| Kurtarma dosyaları | `http://192.168.1.166:8080/` | Pi'nin dosya sunucusu |
| Kurulum günlüğü | `http://192.168.1.166:8080/install.log` | Uzaktan kurulum sırasında okunur |
| MeshCommander | `http://100.101.117.47:3001` | Uzaktan yönetim arayüzü |
| MeshCentral | `https://100.101.117.47:4430` | **Önerilen** uzaktan kurulum arayüzü: SIDER (ISO Pi'de) |
| AMT (donanım yönetimi) | `https://192.168.1.114:16993` | Kullanıcı `admin`, sertifika uyarısını geç |

> **16992 asla açılmaz.** Bu ürün nesli (CSME 16.1) şifresiz portları (16992 / 16994 / 623) tamamen kaldırdı. Her zaman **16993** ve her zaman `https://`.

### En sık düşülen tuzak: aynı ağ aralığı

Ofis ağı `192.168.1.x` aralığını kullanıyor. Ev modemlerinin ezici çoğunluğu da aynı aralığı kullanır. Evden bağlanmaya çalıştığında `192.168.1.114` ofise değil **kendi evindeki bir cihaza** gider — çünkü yerel ağ rotası VPN rotasını yener.

Hata mesajı yoktur. Sadece "ulaşamıyorum" olur ve saatler kaybedilir. 1 Eylül 2026'da tam olarak bu yaşandı.

**Çözüm — SSH tüneli** (çakışmayı tamamen atlar):

```bash
ssh -f -N -L 16993:192.168.1.114:16993 pi
```

Sonra tarayıcıda `https://localhost:16993/`. Aynı yöntem herhangi bir LAN servisi için kullanılabilir — örneğin LLM portu için `-L 1234:192.168.1.114:1234`.

Kalıcı çözüm ofis ağını daha ender bir aralığa taşımaktır (örneğin `10.42.0.0/24`), ama bu modem ayarı gerektirir.

> **İkinci tuzak:** Tek bir bilgisayar aynı anda tek bir Tailscale ağına bağlanabilir. Mac'te birden fazla hesap varsa ve yanlış olanı aktifse Pi görünmez. `tailscale status` ile hangi ağda olduğunu kontrol et.

## 4. Günlük kullanım — LLM'e soru sormak

Sistem OpenAI ile aynı API biçimini konuşur. Yani OpenAI için yazılmış her kütüphane (Python `openai`, LangChain, Cursor, Continue…) sadece adres ve anahtar değiştirilerek buraya bağlanır.

### Önerilen yol: Pi üzerinden

```bash
curl http://100.101.117.47:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-MASTERKEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen/qwen3.8-27b","messages":[{"role":"user","content":"selam"}],"max_tokens":512}'
```

Bu adres **sabittir**: marvin formatlansa, IP'si değişse, model adı değişse bile kullanıcıların kodu değişmez. Arada duran LiteLLM geçidi adresi ve model adını çevirir. Değişen şeyler Pi'de tek bir dosyada toplanır.

**Ana anahtar nerede:** Pi'de `/opt/llm-gw/.env` (izinleri `600`). Repoya girmez, bu belgede yazılı değildir.

### Ekip üyesine anahtar üretmek

Herkese ana anahtarı vermek yerine kişiye özel anahtar üret — sonra tek tek iptal edilebilir:

```bash
curl -X POST http://100.101.117.47:4000/key/generate \
  -H "Authorization: Bearer sk-MASTERKEY" -H "Content-Type: application/json" \
  -d '{"key_alias":"ali"}'
```

### Doğrudan makineye (sadece ofis ağından)

```bash
curl http://192.168.1.114:1234/v1/models
```

Bu yol anahtar istemez ve sadece ofis LAN'ından erişilir. Teşhis için kullanışlıdır: cevap geliyorsa LM Studio ayakta demektir.

### Sağlık kontrolleri

```bash
curl http://100.101.117.47:4000/health/liveliness
```

Cevap `"I'm alive!"` ise geçit çalışıyor. Geçit çalışıp LLM cevap vermiyorsa sorun marvin'de, Pi'de değil.

### Önemli tuzak: `max_tokens` cömert olmalı

`qwen3` bir **akıl yürütme (reasoning) modeli**. Cevabı vermeden önce kendi içinde düşünür ve o düşünme de token harcar. `max_tokens` küçük verilirse limit tamamen düşünme aşamasında tükenir ve **cevap boş görünür**. Model bozuk sanılır, oysa çalışıyordur.

Teşhis: cevapta `finish_reason: "length"` ve dolu bir `reasoning_tokens` alanı varsa sebep budur. **512 ve üzeri güvenli.**

### Model değiştirmek

LM Studio seçilmiş olmasının sebebi tam olarak bu: REST API'si model **yükleme / boşaltma / indirme** uçları içeriyor, yani çalışma anında model değiştirilebiliyor. (vLLM'de model konteyner başlarken sabitlenir; Ollama'da API yüzeyi daha dardır.)

**17 Eylül 2026'dan beri model açılışta YÜKLENMEZ.** Sebep: makine artık GPU eğitim işleri için de kullanılıyor (bkz. 7. bootstrap.sh, adım 10) ve 17 GB'lık sohbet modeli VRAM'de otururken eğitim başlayamaz. Model yükleme kararı insanın: `lms-model` komutu (bootstrap kurar).

```bash
ssh marvin 'lms-model ls'                      # diskteki modeller
ssh marvin 'lms-model load qwen3.8-27b'        # yükle (anahtarın son bileşeni yeter)
ssh marvin 'lms-model status'                  # ne yüklü, açılışa sabitli mi
ssh marvin 'lms-model unload'                  # VRAM'i eğitime bırak
```

Model yüklü değilken Pi üzerinden gelen istekler hata döner — bu bilinçli. Eskisi gibi açılışta da yüklensin istersen:

```bash
ssh marvin 'sudo lms-model pin qwen3.8-27b'    # kaldırmak: sudo lms-model unpin
```

`pin`, ana servis dosyasına dokunmadan bir systemd *drop-in* yazar; `bootstrap.sh` tekrar koşsa bile sabitleme kalır. JIT (ilk istekte otomatik yükleme) bilerek **kapalı**: açık olsaydı eğitim sırasında Pi'den gelen sıradan bir istek modeli VRAM'e çekip eğitim işini öldürürdü.

## 5. Uzaktan güç kontrolü — makineyi aç, kapat, sıfırla

### AMT nedir

Intel anakartlarının içinde, asıl işlemciden **bağımsız çalışan** küçük bir yönetim bilgisayarı vardır (Intel ME). Bu birim kendi ağ yığınına sahiptir ve makine **kapalıyken bile çalışır** — prize takılı olması yeterlidir. Yani işletim sistemi tamamen çökmüş olsa da, disk silinmiş olsa da bu birim cevap verir.

Bu makinedeki sürüm **ISM** (Intel Standard Manageability) — tam AMT'nin biraz kısıtlı kardeşi. Ne var ne yok:

| Yetenek | Durum |
| --- | --- |
| Uzaktan aç / kapat / sıfırla | ✅ |
| Açılış aygıtını zorlama (disk / CD / ağ) | ✅ |
| BIOS ekranına girmeye zorlama | ✅ |
| IDER — uzaktan sanal CD | ✅ |
| SOL — uzaktan seri konsol | ✅ |
| KVM — uzaktan ekran görüntüsü | ❌ (işlemcide dahili grafik yok) |

> **Önemli ders:** Bu tablonun üstü uzun süre yanlış biliniyordu. AMT'nin web arayüzü sadece "Normal boot" gösterdiği için IDER ve SOL'un olmadığı sanıldı. Oysa ikisi de baştan beri vardı — web arayüzü firmware'in yapabildiklerinin sadece bir kısmını sunuyor. Gerçeği öğrenmek için firmware'e **doğrudan sormak** gerekti (`tools/amt-check.py`).

### Komut satırından kullanım

Mac'te `~/.zshrc` içinde bir kısayol tanımlı:

```
amt() { python3 ~/Projects/marvinpi/tools/amt-boot.py "$@"; }
```

Kullanım — önce tüneli aç (bkz. 3. Nasıl erişilir), sonra:

```bash
ssh -f -N -L 16993:192.168.1.114:16993 pi
```

| Komut | Ne yapar |
| --- | --- |
| `amt status` | Güç durumunu söyler — açık mı, kapalı mı |
| `amt on` | Makineyi açar |
| `amt off` | Kapatır (sert kesme — önce `ssh marvin sudo poweroff` dene) |
| `amt reset` | Sert yeniden başlatma |
| `amt cycle` | Kapatıp açar |
| `amt hdd` | Diskten açmaya zorlar + sıfırlar |
| `amt cd` | CD'den açmaya zorlar + sıfırlar (uzaktan kurulum için) |
| `amt bios` | BIOS ekranına girip durur |
| `amt enum` | Firmware'in sunduğu tüm açılış kaynaklarını listeler |

Açılış aygıtı zorlamaları **tek seferliktir** — sonraki açılışta normale döner.

`AMT_NORESET=1` verirsen boot sırasını ayarlar ama makineyi sıfırlamaz; tetiklemeyi sen seçersin. `AMT_DEBUG=1` ham SOAP cevaplarını basar.

**Parola:** komut satırına yazılmaz. macOS Keychain'den okunur:

```bash
security add-generic-password -a "$USER" -s marvin-amt -w
```

Pi'de de bir kopyası var: `/etc/marvin-amt.pass` (izinleri `600`).

### Web arayüzü

Tünel açıkken `https://localhost:16993` → kullanıcı `admin`. Sertifika uyarısını geç. Web arayüzü temel güç işlemlerini sunar; gelişmiş her şey için `amt` komutu ya da MeshCommander gerekir.

### Yedek yol: Wake-on-LAN

AMT cevap vermezse makine ağ kartı üzerinden de uyandırılabilir:

```bash
ssh pi 'sudo etherwake -i eth0 60:cf:84:76:49:42'
```

Bu sadece **açar** — kapatamaz, sıfırlayamaz.

### "Soft off" ne demek

`amt status` kapalı makinede **"Off - Soft"** der. Bu normaldir ve şu anlama gelir: işletim sistemi kapanmış, ama anakart hafif bir bekleme akımı alıyor — tam da bu sayede AMT hayatta ve makineyi uzaktan açabiliyorsun. Fiş çekilmiş olsaydı "Off - Hard" olurdu ve hiçbir uzaktan komut işlemezdi.

### Kapalı mı açık mı — hızlı ayırt etme

Kapalı bir makine de ping'e cevap verir, çünkü cevabı yönetim birimi verir. Fark TTL değerindedir:

| `ping 192.168.1.114` cevabı | Anlamı |
| --- | --- |
| `ttl=64` | **Linux ayakta** |
| `ttl=255` | **Makine kapalı** — cevabı yönetim birimi veriyor |
| cevap yok | Ağ/güç yok, ya da açılış geçişinde |

Bu ayrım önemli: "ping geliyor ama SSH yok" görüp güvenlik duvarı sorunu sanmak bu projede bir kez yapıldı ve yanlışın sürdü. Makine sadece kapalıydı.

## 6. Uzaktan sıfırdan kurulum

Bu bölüm projenin asıl kazanımı. **Makinenin diski tamamen silinmiş olsa bile**, ofise gitmeden, elini sürmeden Debian'ı yeniden kurabilirsin.

### Nasıl mümkün oluyor — IDER

IDER (*IDE Redirection*), yönetim biriminin sunduğu bir numara: senin bilgisayarındaki bir ISO dosyasını marvin'e **fiziksel bir CD sürücüsüymüş gibi** gösterir. marvin'in BIOS'u aradaki ağı bilmez; sadece "CD takılı" görür ve ondan açar.

Bu, makineye USB takmakla aynı şey — sadece uzaktan.

### Adım adım — MeshCentral SIDER (önerilen, 18 Eyl 2026'da kanıtlandı)

ISO **Pi'de** durur, akışı Pi yapar; Mac/laptop yalnızca düğmeye basar. Bağlantı hızın önemsizdir.

**1.** `https://100.101.117.47:4430` (sertifika uyarısını geç) → hesabınla gir.

**2.** Cihaz listesinde `192.168.1.114` (marvin) → cihaz sayfası → **Intel® AMT** sekmesi.

**3.** Yan yana iki düğme var: **IDER** (tarayıcı taraflı, ISO Mac'ten — kullanma) ve **SIDER** (sunucu taraflı). **SIDER**'a bas → dosya seçici Pi'deki "Files" alanını gösterir → `Public/marvin-v3.iso` → bağlan.

**4.** **Power Actions → "Reset to IDE-R CDROM"** (önce SIDER, sonra reset — ters sıra makineyi boş CD'den diske düşürür, zararsız).

**5.** Bundan sonra **hiçbir tuşa basılmaz.** Kurulumcu 10 saniye sonra kendiliğinden başlar. İlerlemeyi Pi'den izle (aşağıda "Kurulumu izlemek").

**6.** Pi'nin erişim günlüğünde **`asama=3-kurulum-bitti-SIDER-IDER-SIMDI-KES`** göründüğü an **SIDER → Disconnect.** Kurulum bitmiş, `late_command` çalışmıştır; ISO'ya iş kalmamıştır.

> **Bu adımı geciktirme.** 18 Eyl 2026'da SIDER bağlıyken reboot oldu, makine yine sanal CD'den açıldı ve 10 sn'lik otomatik menü **ikinci bir kurulumu başlatıp biten kurulumu sildi** (16 dk kayıp). Menüde "diskten aç" varsayılanı yoktur — bilerek: ISO tek amaçlıdır.

**7.** Makine diskten açılır (~1 dk). Host anahtarı değişmiştir; önce eskisini sil, sonra bootstrap:

```bash
ssh-keygen -R 192.168.1.114
```

```bash
ssh marvin 'sudo bash /root/bootstrap.sh'
```

Sürücü kurulduktan sonra "yeniden başlat" der: `ssh marvin 'sudo systemctl reboot'`, 1 dk sonra aynı komut tekrar. Kesintisiz istiyorsan `sudo AUTO_REBOOT=1 bash /root/bootstrap.sh`.

**Yeni bir ISO üretilirse** MeshCentral'ın onu görmesi için Pi'de `/opt/meshcentral/meshcentral-files/domain/user-<kullanıcı>/Public/` altına konmalı (ya da web arayüzünden "Files"a yüklenmeli); depo dizininin kökü seçicide görünmez.

### Yedek yol — MeshCommander (ISO laptop'ta)

`http://100.101.117.47:3001` → cihaz `192.168.1.114`, **Digest**, **TLS**, `admin` → **IDER** → ISO'yu kendi diskinden seç → **Immediate** → **Reset to IDE-R CDROM**. IDER protokolü tarayıcıda çalıştığı için ISO senin makinende akar; yavaş bağlantıda sanal USB aygıtı flap eder ve kurulumcu takılabilir (18 Eyl 2026 tur 1). SIDER varken buna gerek yok.

### Ne kadar sürer

15 Eylül 2026: **5 dakika 22 saniye** (preseed'den; MeshCommander, ofiste). 18 Eylül 2026 (SIDER, ofis dışından): reset → reboot **26 dk** — IDER'den açılış ~6 dk, `disk-detect` 2 dk, biçimlendirme ~6 dk, udev zaman aşımı 2 dk (SIDER erken kesilirse düşer), paketler internetten. Sonra bootstrap: sürücü 196 s + reboot + kalan her şey **158 s** (eğitim ortamı önbellekten 66 s) — toplam ~7 dk. Yani sıfırdan tam makine: **~35 dk, insan müdahalesi iki tık** (SIDER bağla/kes).

### Hangi ISO

**`marvin-v3.iso`** — 64 MB. Durduğu yerler: Pi'de `/opt/llm-repo/`, ayrıca Mac'te `~/Downloads/`.

Debian'ın resmi `mini.iso` dosyasından türetildi; içine açılış parametreleri gömüldü:

| Parametre | Ne işe yarıyor |
| --- | --- |
| `auto=true priority=critical` | Hiçbir soru sorma, tamamen otomatik kur |
| `url=http://192.168.1.166:8080/preseed.cfg` | Kurulum tarifini Pi'den al |
| `modprobe.blacklist=nvme` | **Model diskini görme** |
| `log_host=192.168.1.166 log_port=514` | Günlükleri Pi'ye yolla |
| `console=ttyS0,115200n8` | Seri konsoldan canlı izlenebilsin |
| `hostname=marvin` | Makine adı |

> **Neden küçük ISO:** tam kurulum imajı 756 MB ve IDER kanalı yavaş. 64 MB'lık sürüm sadece çekirdeği taşır, geri kalan her şeyi internetten çeker — marvin LAN'dan internete çıkabildiği için sorun olmaz ve kurulum çok daha hızlı başlar.

**ISO'yu yeniden üretmek gerekirse:** repodaki `netboot/` dizinindeki dosyalar + `xorriso -indev mini.iso -outdev marvin-v3.iso -boot_image any replay -map ...`

### Kurulumu izlemek — kör kalmamak için

Bu belki de en değerli parça. Kurulum başladıktan sonra ekranı göremediğin için normalde ne olduğunu bilemezsin. Üç pencere açıldı:

**1. Uzak günlük (asıl teşhis aracı).** Kurulum programı tüm kayıtlarını Pi'ye yollar; Pi'deki `marvin-syslog.service` bunları dosyaya yazar:

```bash
curl -s http://192.168.1.166:8080/install.log | grep -v "reset high-speed USB" | tail -50
```

(`grep -v` şart: sanal CD sürücüsü saniyede bir USB mesajı basar ve günlüğü boğar.)

**2. Aşama bildirimi.** Kurulum tarifi belirli noktalarda Pi'nin dosya sunucusuna `?asama=...` şeklinde bir istek atar. Pi'nin erişim günlüğünde "şu anda 2. aşamadayız, diski seçti" gibi izler bırakır.

**3. Seri konsol (SOL).** MeshCommander'daki SOL düğmesi canlı bir terminal açar. Ekran görüntüsü değil ama metin akışı görünür.

> **Ders:** Bu üç pencere kurulmadan önce üç kurulum körlemesine denendi ve neden başarısız oldukları anlaşılamadı. Uzak günlük açıldıktan sonra sebep **tek satırda** görüldü. Görünürlüğü baştan kur; sonradan eklemek pahalı.

### Kurulumcunun kendini raporlaması

Preseed'in disk arama adımı artık Pi'ye tanı işaretleri de gönderir (`?tani=pci-depolama`, `?tani=modprobe-ahci`, `?tani=blok`) ve disk bulamazsa **`asama=2x-DISK-YOK`** ile bağırır. 18 Eyl 2026'da iki kurulum `disk-detect`'in `ahci` modülünü yüklememesi yüzünden **sessizce** takıldı — hiçbir günlük, hiçbir ekran yoktu. Preseed artık `modprobe ahci` deneyip diski 60 sn bekliyor; sessiz takılma sınıfı kapatıldı.

### İşletim sistemi ayaktayken — ISO'suz yol (planlı)

OS ayakta ve SSH çalışıyorsa IDER'e hiç gerek yok: kurulumcu çekirdeği diske konup tek seferlik GRUB girişiyle aynı preseed'le açılabilir — Pi'den tek komut, laptop yok, SIDER bağla/kes yok. `marvin-yeniden-kur` olarak ayrı PR'da gelecek. Kural: **SSH varsa script, yoksa SIDER.**

## 7. bootstrap.sh — makineyi çalışır hale getiren betik

Taze kurulmuş bir Debian, LLM servisi değildir. Aradaki her şeyi bu tek betik yapar. Elle kurulum adımı **yoktur** — bilerek: elle yapılan her şey bir sonraki formatta kaybolur ve kimse neyin nasıl yapıldığını hatırlamaz.

### Nasıl çalıştırılır

İnternetten:

```bash
curl -fsSL https://raw.githubusercontent.com/walbis/marvinpi/main/bootstrap.sh -o /tmp/b.sh && sudo bash /tmp/b.sh
```

Pi'den (internet yoksa da çalışır):

```bash
curl -fsSL http://192.168.1.166:8080/bootstrap.sh -o /tmp/b.sh && sudo bash /tmp/b.sh
```

Sürücü kurulduysa yeniden başlatma ister; ardından aynı komut tekrar çalıştırılır. Kesintisiz olsun istersen başına `AUTO_REBOOT=1` ekle — kendi yeniden başlatır ve devam eder.

### En önemli özellik: idempotent

Betik kaç kez çalıştırılırsa çalıştırılsın aynı sonucu verir ve **çalışan bir şeye gereksiz yere dokunmaz**. Örneğin systemd tanımı birebir aynıysa servisi yeniden başlatmaz — yani yüklü model bellekten düşmez. "Bir şey bozuldu, ne olduğunu bilmiyorum" durumunda çekinmeden çalıştırabilirsin.

### On adım

| # | Adım | Ne yapar |
| --- | --- | --- |
| 0 | Ön kontroller | root mu, hedef kullanıcı var mı, ağ var mı |
| 1 | NVIDIA sürücüsü | `non-free` deposunu açar, **çekirdek başlıklarını** ve sürücüyü kurar |
| 2 | Model diski | `SILME-MODELLER` etiketini bulur, `/mnt/models`'a bağlar, `fstab`'a `nofail` ile yazar |
| 3 | LM Studio | Hedef kullanıcıya kurar, PATH'i ayarlar, model dizini symlink'ini kurar |
| 4 | JIT ayarı | JIT'i kapalı tutar: model yalnızca açıkça istendiğinde yüklenir |
| 5 | systemd servisi | `lmstudio.service` — açılışta otomatik başlar; **model yüklemez** (`lms-model` ile) |
| 6 | Uyku kapalı | Uyku/hazarda-geçiş maskelenir, hedef `multi-user.target` |
| 6b | Açılışta onarım | GRUB'a `fsck.repair=yes` ekler — bozuk dosya sistemi insan beklemeden onarılır |
| 7 | Güvenlik duvarı | ufw: ofis ağına 22 ve 1234 açık, gerisi kapalı |
| 8 | Wake-on-LAN | Ağ kartını uyandırmaya hazır bırakır (kalıcı servis) |
| 9 | SSH anahtarları | Pi'den public key listesini çekip kurar — **erişim böyle geri gelir** |
| 9b | SSH parola girişi kapalı | `sshd_config.d/99-nopw.conf` — parolasız sudo ile parolayla SSH birleşmesin (anahtar yoksa atlanır) |
| 10 | Eğitim ortamı | GPU deney/eğitim katmanı: `/opt/egitim-venv`, `/opt/llama.cpp`, HF önbelleği, `lms-model` — **NVMe önbellekli** (aşağıda) |
| 11 | Özet | Ne yapıldığını, neyin çalıştığını ve eğitim kabul kontrollerini basar |

### Adım 10 — Eğitim ortamı (17 Eylül 2026'da eklendi)

marvin bundan sonra farklı projelerin **kısa süreli GPU işleri** için de kullanılıyor: ince ayar (LoRA/QLoRA), değerlendirme, GGUF'a çevirme ve niceleme. Kural: her kullanımdan sonra sıfırdan kurulur, iz bırakılmaz. Bu yüzden projeden bağımsız, herkese açık yazılım katmanı taze kurulumda hazır gelir; **proje verisi, kod ve anahtarlar oturumla gelip gider** — bootstrap'ın işi değildir. Ayrıntı: `egitim/README.md`.

Ne kurar:

| Parça | Nerede | Not |
| --- | --- | --- |
| Sistem paketleri | apt | git, tmux, cmake, build-essential, python3-venv… CUDA toolkit **kurulmaz** (pip tekerlekleri kendi çalışma zamanını taşır) |
| Python ortamı | `/opt/egitim-venv` (sahibi `marvin`) | torch **yalnız cu124** (sürücü 550 → CUDA 12.4 tavanı → torch ≤ 2.6), unsloth, peft, trl, transformers, datasets, accelerate, bitsandbytes, gguf, hf_transfer… |
| llama.cpp | `/opt/llama.cpp` (sabit etiket `v0.4.1`, yalnız CPU) | `convert_hf_to_gguf.py` + `llama-quantize`. Deposunun kendi `requirements-*.txt` dosyası **kurulmaz** — içindeki CPU torch pini CUDA torch'u ezer |
| HF önbelleği | `/mnt/models/hf` | Yalnız kamuya açık taban modeller. Giriş kabuğunda `HF_HOME` **disk bağlıysa** ayarlanır; değilse uyarı basar ve ayarlanmaz (sda'ya inmesin) |
| `lms-model` | `/usr/local/bin` | LM Studio modelini istek üzerine yükle/boşalt/sabitle |

**Neden hızlı — NVMe önbellek.** İndirilen her şey (`.deb`, pip wheel, llama.cpp derlemesi, uv Python) model diskindeki `/mnt/models/cache/` altında tutulur. Disk formatı sağ atlattığı için ikinci kurulum internete çıkmadan biter: 65 Mbit ofis hattında ~12 dakikalık indirme → ~2 dakika. Disk bağlı değilse önbellek yok sayılır, her şey internetten gelir; sda'ya önbellek yazılmaz.

**Paket pin'leri.** İlk başarılı kurulum `pip freeze` ile `/opt/egitim-venv/requirements.txt` üretir; bu dosya depoya `egitim/requirements.txt` olarak konur, Pi'ye senkronlanır ve sonraki kurulumlar **ondan** kurar (kaynak sırası: Pi → önbellek → yoksa gevşek liste + dondurma). Projeler kendi pin listesini getirirse oturum içinde venv'in üstüne kurar; bootstrap değişmez.

**Python yolu — uv ile 3.12 (tatbikat sonucu, 18 Eyl 2026).** Sistem Python'u 3.13 ama bu kümeyle **kurulamıyor**: unsloth'un istediği ve torch 2.6 ile uyumlu son xformers (0.0.29.post3) için cp313 tekerleği yok; pip kaynaktan derlemeye kalkıp düşüyor. Bu yüzden bootstrap `uv` ile Python 3.12 kurar (ikili `/mnt/models/cache/uv/python` altında, formatı sağ atlatır) ve venv'i onunla yapar. Ayrıca `torchao<0.17` kısıtı var: unsloth_zoo torchao ister, 0.17+ torch 2.7 API'si kullanıyor (marvin'de ampirik: 0.13–0.16 çalışıyor). Sürücü/torch yükselince `EGITIM_PYTHON=system` yeniden denenir. Seçilen yol `/opt/egitim-venv/.python-yolu` dosyasında ve özet ekranında yazar.

**Kabul ölçütleri** (bootstrap sonunda kendisi koşar; `egitim/TATBIKAT.md` ile aynı):

```bash
su - marvin -c '/opt/egitim-venv/bin/python -c "import torch, unsloth, bitsandbytes; print(torch.cuda.is_available(), torch.version.cuda)"'   # True 12.4
/opt/llama.cpp/build/bin/llama-quantize --help
su - marvin -c '/opt/egitim-venv/bin/python /opt/llama.cpp/convert_hf_to_gguf.py --help'
su - marvin -c 'echo $HF_HOME'                                                # /mnt/models/hf
```

Atlamak için: `sudo EGITIM=0 bash bootstrap.sh`.

### Değiştirilebilir ayarlar

Hepsi ortam değişkeniyle ezilebilir, betik düzenlenmeden:

| Değişken | Varsayılan | Açıklama |
| --- | --- | --- |
| `TARGET_USER` | `marvin` | LM Studio bu kullanıcıya kurulur |
| `MODELS_LABEL` | `SILME-MODELLER` | Aranacak disk etiketi |
| `MOUNT_POINT` | `/mnt/models` | Model diskinin bağlanacağı yer |
| `LMS_PORT` | `1234` | LLM API portu |
| `LMS_MODEL` | *(boş)* | Açılışta sabitlenecek model. **Boş = yüklenmez** (17 Eyl 2026). Eski davranış: `qwen/qwen3.8-27b` ya da `lms-model pin` |
| `LMS_CTX` | `8192` | Bağlam penceresi (`lms-model load --ctx` ile oturumda değişir) |
| `LMS_PARALLEL` | `4` | Eşzamanlı istek sayısı |
| `LAN_CIDR` | `192.168.1.0/24` | Güvenlik duvarında serbest bırakılan ağ |
| `AUTO_REBOOT` | `0` | `1` → sürücü sonrası kendi yeniden başlatır |
| `AUTH_KEYS_URL` | Pi'nin `:8080/authorized_keys` | SSH anahtar listesi kaynağı |
| `EGITIM` | `1` | `0` → eğitim ortamı adımı atlanır |
| `EGITIM_PYTHON` | `uv312` | `system` (3.13 — bugün xformers yüzünden kurulamıyor) / `auto` (önce sistem, olmazsa uv) |
| `LLAMA_TAG` | `v0.4.1` | llama.cpp sürüm etiketi (asla `latest`) |
| `TORCH_INDEX` | `…/whl/cu124` | torch tekerlek dizini — sürücü 550 tavanı |
| `CACHE_DIR` | `/mnt/models/cache` | NVMe önbelleği; disk bağlı değilse kullanılmaz |
| `REQ_URL` | Pi'nin `:8080/egitim/requirements.txt` | Pinli paket listesi kaynağı |

### SSH anahtarı adımı — erişim nasıl geri geliyor

Format sonrası makinede hiçbir anahtarın yoktur, yani normalde giremezsin. 9. adım bunu çözer: Pi'nin dosya sunucusundaki `authorized_keys` listesini indirip kurar. Çalışma biçimi dikkatli:

- Var olan anahtarlar **korunur**, mükerrer satır eklenmez
- İnen içerik gerçekten public key değilse dosyaya **hiç dokunmaz** (yarım inen dosya erişimi kilitlemesin)
- Pi erişilemezse **uyarı basar ve devam eder** — kurulum yine tamamlanır, sadece anahtarla giriş olmaz

> **Zincirin zayıf halkası:** `authorized_keys` dosyası repoda yoktur (olmamalı da) — sadece Pi'de durur. Pi'nin SD kartı giderse format sonrası makineye girilemez. Pi yedeğine bu dosyayı dahil et.

Anahtar listesini güncellemek:

```bash
scp ~/.ssh/id_ed25519.pub pi:/tmp/ak && ssh -t pi 'sudo install -m 644 /tmp/ak /opt/llm-repo/authorized_keys'
```

### Pi'deki kopya kendini tazeliyor

Pi'de `llm-repo-sync.timer` günde bir kez GitHub'daki güncel sürümü çeker. İndirme başarısız olursa eldeki kopya korunur; inen `.sh` dosyası `bash -n` ile sözdizimi açısından doğrulanır ve bozuksa yerine konmaz.

Bu mekanizma bir arıza sınıfını kapatmak için eklendi: elle senkron unutulduğu için Pi bir gün boyunca **SSH anahtarı adımı olmayan eski bir sürümü** servis etti — hiçbir hata vermeden. Bu tür sessiz eskime ancak gerçek bir kurtarma anında fark edilir, yani en kötü anda.

Elle tetiklemek: `ssh pi 'sudo /usr/local/bin/llm-repo-sync'`

## 8. Sorun giderme — makineye ulaşamıyorsan

Soruları **bu sırayla** sor. Bu sıra rastgele değil: her adım bir öncekinden daha pahalı ve bu projede sıranın atlanması iki kez zaman kaybettirdi.

### 1. Doğru ağda mısın?

```bash
tailscale status | head -5
```

Pi görünmüyorsa yanlış Tailscale hesabındasın. Bir bilgisayar aynı anda tek bir tailnet'e bağlanabilir.

### 2. Pi ayakta mı?

```bash
ssh pi 'uptime; systemctl is-active llm-repo marvin-syslog meshcommander'
```

Pi ölüyse **hiçbir kurtarma yolu çalışmaz** — önce onu ayığa kaldır.

### 3. Makine açık mı? (önce buna bak)

```bash
ping -c 3 192.168.1.114
```

| Cevap | Anlamı | Ne yap |
| --- | --- | --- |
| `ttl=64` | Linux ayakta | 4. adıma geç |
| `ttl=255` | **Kapalı** | `amt on` — sorun yok, sadece kapalıydı |
| Cevap yok | Ağ yok / açılış geçişi | 30 sn bekle, tekrar dene |

Aynı ağ aralığındaysan (ev modemi de `192.168.1.x`) bu ping **kendi evindeki bir cihaza** gidiyor olabilir — cevap da alabilirsin. Şüphelenirsen Pi üzerinden ping at:

```bash
ssh pi 'ping -c 3 192.168.1.114'
```

### 4. SSH çalışıyor mu?

```bash
ssh marvin 'uptime; systemctl is-active lmstudio'
```

Çalışıyorsa sorun servis seviyesinde:

```bash
ssh marvin 'sudo systemctl restart lmstudio; journalctl -u lmstudio -n 50 --no-pager'
```

Yetmezse `bootstrap.sh`'ı tekrar çalıştır — idempotenttir, her şeyi onarır.

### 5. Makine açık ama SSH yok

Bu en zor durum. Sırasıyla:

```bash
ssh -f -N -L 16993:192.168.1.114:16993 pi && amt status
```

- `amt status` cevap veriyorsa donanım sağlam, sorun işletim sisteminde.
- **Sıfırlamayı dene:** `amt reset`. Çoğu durumu çözer.
- Sıfırlama sonrası yine gelmiyorsa makine bir açılış ekranında takılı olabilir — MeshCommander'da **SOL** aç ve metin akışını izle.

### 6. Hiçbir şey işe yaramıyorsa

Sıfırdan kur — artık bu pahalı bir işlem değil, 5,5 dakika. Bkz. 6. Uzaktan sıfırdan kurulum. Modeller korunur, erişim anahtarları geri gelir.

### AMT parolası unutulduysa

Bu adım **fiziksel erişim** gerektirir:

1. BIOS → Advanced → AMT Configuration → `Unconfigure ME: Enabled` → F10
2. Debian açıldıktan sonra: `sudo rpc activate -local -ccm -password 'YENİ'`
3. Yaklaşık 1 dakika sonra 16993 tekrar açılır

Teşhis aracı: `sudo rpc amtinfo`. Not: `rpc activate` bu makinede 20 saniyelik zaman aşımı döngüsüne girer — yavaştır ama tamamlanır, iptal etme.

> Parolayı yeniden kurduktan sonra ACM kipine almayı unutma, yoksa uzaktan kurulum yeteneğini kaybedersin — bkz. 9. Bilinen tuzaklar.

## 9. Bilinen tuzaklar — bunlar canımızı yaktı

Her madde gerçekten yaşanmış bir olaydır. Okuması beş dakika; yaşaması günler aldı.

### İki haftalık kesintinin sebebi tek bir BIOS ayarıydı

1 Eylül 2026'da makine "açılmıyor" sanıldı ve iki hafta öyle kaldı. Gerçek: makine üç kez elle yeniden başlatılmış, sonuncusu sert kesilmiş. ASUS'un **"Wait For F1 If Error"** ayarı anormal güç olayı sonrası ekranda tuş bekliyor. AMT'den atılan her sıfırlama makineyi aynı ekrana geri döndürüyordu.

SSH ölü, ping garip, AMT açık — her şey "donanım öldü" diyordu. Sebep tek satırlık bir firmware istemiydi ve **ekran görülene kadar** teşhis edilemedi.

**Ders:** Açılmayan makinede ilk iş ekrana bakmaktır. Ayar artık kapalı, ama BIOS'ta "Load Optimized Defaults" yapılırsa geri gelir — ilk şüpheli olarak aklında tut.

### Kapalı makine de ping'e cevap verir

Yönetim birimi cevaplar (`ttl=255`). "Ping var ama SSH yok" görüp güvenlik duvarı sorunu sanmak bu projede bir kez yapıldı ve "fiziksel erişim gerekiyor" gibi yanlış bir sonuca götürdü. Makine sadece kapalıydı.

AMT portunun açık olması da makinenin açık olduğu anlamına gelmez — AMT zaten kapalı makinede çalışır.

### Aktivasyon kipi mimari bir karardır, teknik detay değil

AMT'nin iki kipi var: **CCM** (Client Control Mode) ve **ACM** (Admin Control Mode). CCM'de açılış yönlendirmesiyle ilgili her şey — IDER, boot sırası değiştirme, PXE — *makinenin başındaki kullanıcının onayı* kapısının arkasındadır. Uzaktan çağırdığında `AccessDenied` alırsın.

Bu makine CCM'deydi. Yani uzaktan yönetim **sadece güce** indirgenmişti ve bu ancak gerçek bir arızada fark edildi.

**Düzeltme:** BIOS → MEBx → `Standard Manageability → Activate Network Access` + `User Consent → None`.

> **Kritik incelik:** MEBx değişiklikleri **sıcak yeniden başlatmayla oturmaz.** Yönetim birimi yarım kalır: UUID sıfırlanır, Remote Control menüsü kaybolur, açılış kaynakları listesi boşalur. **Tam güç kesintisi gerekir — fişi çek, 60 saniye bekle.** Ondan sonra her şey yerine oturur. Bu adım atlanınca değişikliklerin uygulanmadığı zannedildi ve bir tur boşa gitti.

Doğrulama: `python3 tools/amt-check.py` → `OptInRequired=0`, `CanModifyOptInPolicy=1`.

### Yetenek listesi ≠ kullanabilmek

Firmware "IDER var, SOL var, PXE var" diyordu ve **doğruydu**. Ama CCM hepsini onay kapısının arkasına kilitliyordu. Bir yeteneği "var" görmek yetmez; erişim politikasını da sorgula.

### Firmware'in yeteneklerini arayüze bakarak öğrenme

AMT'nin web arayüzü sadece "Normal boot" sunuyor. Buna bakıp **aylarca IDER ve SOL'un olmadığı sanıldı** — ikisi de baştan beri varmış. Web arayüzü donanımın yapabildiklerinin sadece bir kısmını gösterir. Firmware'e doğrudan sor: `tools/amt-check.py`.

### Test edilmemiş her kod yolu kırıktır

15 Eylül format tatbikatı `bootstrap.sh`'ta **altı ayrı bug** buldu. Hepsi daha önce **hiç çalışmamış** dallardaydı — çünkü o dallar sadece taze kurulumda çalışıyor:

1. **Çekirdek başlıkları (`linux-headers`) kurulmuyordu** → NVIDIA modülü hiç derlenmiyor → GPU ölü
2. **Sürücü dalı kısır yeniden başlatma döngüsüne giriyordu** (yeniden başlatmak modülü derlemez)
3. **`ls a b | head` + `pipefail`** → dosyalardan biri yoksa betik çıkış 2 ile ölüyordu
4. **`jq` taze Debian'da yok** → JIT adımı sessizce atlanıyordu
5. **Kurulum `/dev/sda`'yı hedefliyordu** ama uzaktan kurulumun boş sanal disketi o adı kapıyor → gerçek disk `sdb`'ye kayıyor → **üç kurulum boşa gitti**
6. **Model anahtarı taze kurulumda farklı** (`qwen3.8-27b` vs `qwen/qwen3.8-27b`) → model yükleme sessizce başarısız

**Ders:** "Yazdım, mantığı doğru" yeterli değil. Çalıştırılmamış kod, ihtiyaç anında kırılır. Kurtarma yolunu düzenli olarak **gerçekten çalıştır**.

### Görünürlüğü baştan kur

Uzak günlük kurulana kadar **üç kurulum körlemesine** denendi ve neden başarısız oldukları anlaşılamadı. `log_host` açıldıktan sonra sanal disket sorunu **tek satırda** görüldü. Görünürlüğü sonradan eklemek pahalı.

### Çalışan sistem ile onu yeniden üreten betik ayrışıyor

İki kez yaşandı:

- Elle düzeltilen LiteLLM yapılandırması `pi-setup.sh`'a yansımamıştı — Pi yeniden kurulsa geçit var olmayan bir adrese bakardı.
- Pi'nin servis ettiği `bootstrap.sh` elle senkron unutulduğu için eskimişti — bir gün boyunca SSH anahtarı adımı olmayan sürümü dağıttı.

İkisi de **hata vermeden**, yalnızca gerçek bir kurtarma anında ortaya çıkacak cinsten. **Makinede elle bir şey düzeltirsen betik dosyasına da işle.**

### Daha küçük ama pahalıya patlayanlar

| Tuzak | Sonucu |
| --- | --- |
| **ufw'de sıra** | İzin kuralları `enable`'dan **önce** yazılmalı. Ters sıra makineyi ağdan kilitler: ping açık, tüm TCP kapalı — ve KVM olmadığı için kurtarma fiziksel erişim ister |
| **LM Studio'yu `sudo` ile kurmak** | `/root/.lmstudio`'ya gider, servis çalışmaz. Hedef kullanıcıya `sudo -u ... -H` ile kurulmalı |
| **Disk bağlı değilken symlink kurmak** | LM Studio modelleri sistem diskine indirir — ayrı diskin bütün amacı bozulur |
| **PATH'i `.bashrc`'ye eklemek** | Kurulum her tekrarlandığında satır yığılır (makinede üç mükerrer satır oluşmuştu). Doğrusu `/etc/profile.d/` altında tek dosya |
| **`ethtool` çıktısında `Wake-on:` iki kez geçer** | Desen satır başına sabitlenmezse yanlış alan okunur — WoL "çalışmıyor" sanıldı |
| **`ListenerEnabled=false`** | IDER açık görünse bile oturum kurulamaz. Düzeltme: `RequestStateChange(32771)` |
| **Yetkisiz `grep` sessizce boş döner** | Kök dizinin GRUB dosyası `600` izinli; `sudo`suz `grep -c` **0** döner ve "yok" sanılır. Üç tur yanlış teşhis bundandı — doğrulama komutunun kendi yetkisini de kontrol et |

### Netboot bu ağda ölü (tekrar denemeyin)

Pi'den ağ üzerinden açılış (PXE) kurulmuştu ve dosya tarafı sağlamdı, ama hiç çalışmadı. Sebep ARP testiyle kanıtlandı: **ZTE H3600P modem kablolu portları L2 seviyesinde ayırıyor.** marvin'in yayın paketleri Pi'ye hiç ulaşmıyor. Modemde "port kontrolü hepsi açık" görünse de izolasyon firmware'de gömülü.

`netboot/` dizinindeki dosyalar duruyor ama başka bir switch ya da ağ segmenti olmadan kullanılamaz. **IDER bu ihtiyacı zaten karşılıyor.**

### Denenip elenen fikirler (tekrar önermeyin)

- **Aynı diskte gizli bölüm:** kurulum sihirbazı görür ve siler. Ayrı disk + açık `SILME-` adı daha iyi korur.
- **EFI bölümüne kurtarma imajı:** kurulum o bölümü yeniden biçimlendirince kaybolur.
- **Mac'te iki Tailscale ağı aynı anda:** mümkün değil, hesap değiştirmek gerekir.

## 10. Ne yapıldı — 31 Ağustos – 15 Eylül 2026

### Başlangıç durumu

31 Ağustos'ta elimizde şunlar vardı: çalışan bir LLM makinesi, bir Raspberry Pi, ve **kurtarma konusunda kâğıt üzerinde bir plan.** Belgeler eski mimariyi (Ollama + Docker) anlatıyordu, Pi'nin dosya sunucusunun dizini **boştu** (yani "internetsiz kurtarma" yolu gerçekte yoktu), ve makine bozulursa yapılabilecek tek şey ofise gitmekti.

### 31 Ağustos — temel

Dosyalar iCloud'dan çıkarılıp GitHub'a taşındı: **github.com/walbis/marvinpi**. (iCloud'daki dosyalar "dataless" durumda olduğu için `git add` zaman aşımına uğruyordu — önce yerele indirilmeleri gerekti.)

### 1 Eylül — gerçekle hizalama

- `bootstrap.sh` LM Studio mimarisine göre **sıfırdan yazıldı** (eski sürüm Ollama + Tailscale + Docker kuruyordu; artık kullanılmayan bir mimariydi)
- `KURTARMA-README.md` yeniden yazıldı, ölü `docker-compose.yml` silindi
- Pi'nin dosya sunucusu **dolduruldu** — internetsiz kurtarma yolu ilk kez gerçek oldu
- `bootstrap.sh`'a **SSH anahtarı adımı** eklendi — format sonrası erişim artık kendiliğinden geliyor
- `llm-repo-sync.timer` kuruldu — Pi'deki kopya artık kendini tazeliyor
- `pi-setup.sh` gerçekle hizalandı (hâlâ eski Ollama adresini üretiyordu)
- **AMT yetenek envanteri çıkarıldı** — IDER, SOL ve PXE'nin baştan beri var olduğu keşfedildi
- **CCM kilidi bulundu** — uzaktan kurtarmanın önündeki asıl engel

Bu sırada makine erişilemez hale geldi ve **iki hafta öyle kaldı.**

### 15 Eylül — kriz çözüldü ve yetenekler kazanıldı

**İki haftalık kesintinin sebebi bulundu:** BIOS'un "Wait For F1 If Error" ayarı. Kapatıldı.

Aynı gün sırasıyla:

- **AMT ACM kipine alındı** (MEBx + tam güç kesintisi) → uzaktan güç, sıfırlama ve açılış aygıtı seçimi çalışır hale geldi
- Modemde IP rezervasyonu yapıldı — marvin'in adresi artık sabit
- `fsck.repair=yes` eklendi — bozuk dosya sistemi insan beklemeden onarılıyor
- Model artık açılışta yükleniyor ve yüklü kalıyor (JIT kapatıldı) — ilk istek artık yavaş değil
- **Netboot elendi** — modem izolasyonu ARP testiyle kanıtlandı, bu yol kapandı
- **IDER kanıtlandı** — marvin sanal CD'den Debian kurulum menüsüne açıldı
- MeshCommander Pi'ye servis olarak kuruldu
- Uzak kurulum günlüğü kuruldu (`marvin-syslog.service`)
- Özel otomatik kurulum ISO'su üretildi (`marvin-v3.iso`)
- MeshCentral kuruldu (sunucu taraflı IDER için altyapı)

### Format tatbikatı — asıl sınav

Aynı gün, kullanıcı ofiste **değilken**, marvin'in sistem diski tamamen silindi ve makine uzaktan sıfırdan kuruldu.

| Ölçüm | Sonuç |
| --- | --- |
| Kurulum süresi | **5 dakika 22 saniye** (1,8 TB biçimlendirme dahil) |
| Model diski | **Dokunulmadı** — 17 GB korundu, kurulum programı diski hiç görmedi |
| SSH erişimi | Kurulum tarifiyle kendiliğinden geri geldi |
| `bootstrap.sh` | Çıkış kodu 0, hatasız tamamlandı |
| Uçtan uca test | Pi → marvin → 27B model: **http 200, 0,8 saniye** |

Tatbikat aynı zamanda `bootstrap.sh`'ta altı bug ortaya çıkardı (bkz. 9. Bilinen tuzaklar) — hepsi hiç çalıştırılmamış kod yollarındaydı ve hepsi düzeltildi. Tatbikatın asıl değeri budur: gerçek bir kriz anında çökecek olan altı nokta, kriz olmadan bulundu.

### Öncesi ve sonrası

|  | **31 Ağustos** | **15 Eylül** |
| --- | --- | --- |
| Makine kapalıyken açmak | ❌ | ✅ `amt on` |
| Donmuş makineyi sıfırlamak | ❌ | ✅ `amt reset` |
| Açılış aygıtını seçmek | ❌ | ✅ `amt cd` / `amt hdd` |
| Uzaktan sıfırdan kurulum | ❌ | ✅ IDER, 5,5 dakika |
| Kurulumu izlemek | ❌ (kör) | ✅ uzak günlük + SOL |
| Format sonrası SSH erişimi | ❌ elle | ✅ kendiliğinden |
| Model koruması | ❓ teoride | ✅ kanıtlandı |
| İnternetsiz kurtarma | ❌ (dizin boştu) | ✅ Pi'de, kendini tazeliyor |

### Bu belge neye dayanıyor

Repo: **github.com/walbis/marvinpi** — 17 commit, 31 Ağustos – 15 Eylül 2026.

| Dosya | İçeriği |
| --- | --- |
| `bootstrap.sh` | Makineyi çalışır hale getiren betik |
| `DURUM.md` | Teknik devir notu — yeni bir oturumda önce bu okunur |
| `KURTARMA-README.md` | Kısa işletme rehberi |
| `pi-setup.sh` | Pi'yi sıfırdan kuran betik |
| `tools/amt-boot.py` | Uzaktan güç ve açılış aygıtı kontrolü |
| `tools/amt-check.py` | Firmware yetenek ve politika sorgusu |
| `netboot/` | Kurulum tarifi (preseed), ISO üretimi, uzak günlük dinleyicisi |
| `meshcentral/` | Sunucu taraflı IDER yapılandırması |

> Repo herkese açık. İçinde parola yok, ama iç ağ topolojisi (IP ve MAC adresleri) görünüyor.

## 11. Kalan işler, riskler ve bakım

### Henüz test edilmemiş

| Ne | Durum |
| --- | --- |
| **`marvin-yeniden-kur` (ISO'suz, OS ayaktayken)** | Henüz yazılmadı — planlı, bkz. §6 |
| **preseed `late_command` sudo/hostname satırları** | 18 Eyl'de eklendi, Pi'deki preseed yeniden üretildi; **bir sonraki kurulumda** doğrulanacak (bu turda elle yapıldı) |

> Yukarıdaki "test edilmemiş her kod yolu kırıktır" dersi burada da geçerli: bu yol denenmeden **çalışıyor sayılmamalı.**

### Güvenlik — yapılması gerekenler

| İş | Neden |
| --- | --- |
| **AMT parolasını değiştir** | Mevcut parola bu çalışma sırasında düz metin olarak konuşma geçmişine girdi. Değiştirdikten sonra Keychain (`marvin-amt`) ve Pi'deki `/etc/marvin-amt.pass` kopyalarını da güncelle |
| **Pi'nin SD kartını yedekle** | Pi tek arıza noktası. Yedeğe `/opt/llm-repo/authorized_keys` ve `/opt/llm-gw/.env` **mutlaka** dahil olmalı — ikisi de repoda yok ve ikisi de kaybolursa geri getirilemez |

**Mevcut yapılandırma notları:** Her iki makinede de `sudo` parolasız (`/etc/sudoers.d/`). Bu yüzden marvin'de SSH parola girişi **kapatıldı** (`/etc/ssh/sshd_config.d/99-nopw.conf`) — parolasız sudo + parolayla SSH birleşirse parolayı tahmin eden herkes root olurdu. Sadece anahtarla giriş var.

### Riskler

- **Pi tek arıza noktasıdır.** Geçit, dosya sunucusu, yönetim arayüzleri, SSH anahtar listesi — hepsi onda. Pi giderse marvin çalışmaya devam eder ama **kurtarma yeteneği kaybolur.**
- **BIOS'ta "Load Optimized Defaults"** yapılırsa "Wait For F1" ayarı geri gelir ve iki haftalık kriz tekrarlanabilir.
- **Elle yapılan düzeltmeler betiklere işlenmezse** bir sonraki kurtarmada kaybolur. Bu iki kez yaşandı.
- **Repo herkese açık.** Parola yok ama iç ağ topolojisi görünüyor.

### Periyodik bakım

**Ayda bir (5 dakika):**

```bash
ssh pi 'systemctl is-active llm-repo llm-repo-sync.timer marvin-syslog meshcommander; ls -la /opt/llm-repo/'
```

```bash
ssh marvin 'systemctl is-active lmstudio; df -h /mnt/models; nvidia-smi --query-gpu=name,memory.used --format=csv'
```

Ayrıca `amt status` ile yönetim biriminin cevap verdiğini doğrula — kriz anında çalışmadığını öğrenmek istemezsin.

**Altı ayda bir:** Format tatbikatını **tekrarla.** Bu maliyetli görünür ama tatbikatın ilk seferi altı bug buldu; kurtarma yolu kullanılmadığında sessizce bozulur.

**Her değişiklikten sonra:**

```bash
ssh pi 'sudo /usr/local/bin/llm-repo-sync'
```

### Bu belge eskirse

En güncel teknik ayrıntı her zaman repodaki `DURUM.md` dosyasındadır — bu belge onun anlaşılır anlatımıdır. İkisi çelişirse `DURUM.md` ve betiklerin kendisi doğru kabul edilir.
