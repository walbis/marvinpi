# Tatbikat — bootstrap adım 10 (eğitim ortamı) — doldurulacak rapor

**Durum:** Koşu A+B ☑ 18 Eyl 2026 · **Koşu C ☑ 18 Eyl 2026** (Berkay: MeshCentral SIDER ile format; Claude: izleme + bootstrap) — TAMAMLANDI

Kural: "test edilmemiş her kod yolu kırıktır." Adım 10 makinede hiç koşmadı. Bu belge
koşulana kadar REHBER §11 "Henüz test edilmemiş" listesinde kalır. Tatbikatı **insan**
koşar (IDER + AMT gerekir); agent yalnızca komutları ve beklenen çıktıları hazırlar.

## 0. Hazırlık (Pi'de, tek sefer)

```bash
ssh pi
# Senkron listesi değişti (REHBER.md + egitim/requirements.txt). Ya pi-setup.sh'ı yeniden koş
# ya da sadece sync script'ini tazele:
sudo bash pi-setup.sh          # idempotent; Tailscale/Docker/LiteLLM'e dokunmaz
sudo /usr/local/bin/llm-repo-sync
ls -la /opt/llm-repo/ /opt/llm-repo/egitim/ 2>/dev/null
```

Beklenen: `bootstrap.sh` yeni (içinde `lms-model` geçer: `grep -c lms-model /opt/llm-repo/bootstrap.sh` > 0).
`egitim/requirements.txt` ilk tatbikatta **henüz yok** — normal (404 → bootstrap gevşek listeyle kurar).

> Kanonik repo **GitHub** (`walbis/marvinpi`, 17 Eyl 2026 kararı); Pi senkronu oradan çeker
> (`RAW_BASE`, pi-setup.sh:21). Gitea (`karay/marvinpi`) kopyadır — Pi'ye düşmesi gereken
> her değişiklik GitHub `main`'e girmeli.

## 1. Koşu A — çalışan makinede, önbellek boş (internetten)

Amaç: (1) paket kümesinin çözüldüğünü görmek, (2) `requirements.txt` üretmek, (3) önbelleği doldurmak.

```bash
ssh marvin
curl -fsSL http://192.168.1.166:8080/bootstrap.sh -o /tmp/b.sh
time sudo bash /tmp/b.sh 2>&1 | tee /tmp/bootstrap-A.log
```

| Ölçüm | Beklenen | Gerçek |
| --- | --- | --- |
| Çıkış kodu | 0 | A1: 1 (bug 1-2) · A2: 1 (bug 4-6) · **A3: 0** (kabul satırı bug 7 ile yanlış HATA dedi, stamp yazıldı) |
| Toplam süre | 15-25 dk (65 Mbit) | A1 379 s + A2 389 s + A3 190 s — üç koşum toplamı ~16 dk; A3 tek başına önbellekten |
| "Eğitim ortamı :" satırı | `tamam (N sn)` | `tamam (172 sn)` |
| "python yolu" | `uv312` (varsayılan; 3.13 xformers yüzünden elendi) | `uv312` (3.12.14) |
| "torch" | `2.6.0+cu124 12.4` | `2.6.0+cu124 12.4` ✓ |
| `/opt/egitim-venv/requirements.txt` | var, `torch==2.6.0+cu124` satırı içerir | 106 satır; torch 2.6.0+cu124, torchao 0.16.0, unsloth 2026.9.6, transformers 5.5.0, trl 0.24.0, xformers 0.0.29.post3 |
| `/mnt/models/cache/wheels` | dolu (`ls | wc -l` > 50) | 107 wheel, 3.1 GB (pip cache 2.7 GB, llama 164 MB, uv 117 MB, apt 52 MB) |
| `/mnt/models/cache/llama.cpp/llama.cpp-v0.4.1.tar.zst` | var | var (A1'de derlendi, A2/A3 önbellekten) |
| lmstudio.service | `active`; **model yüklü değil** (`lms-model status`) | active, model yok ✓ |

Sonra: `scp marvin:/opt/egitim-venv/requirements.txt egitim/requirements.txt` → depoya commit → Pi senkronu.

## 2. Koşu B — aynı makinede ikinci koşum (idempotentlik)

```bash
time sudo bash /tmp/b.sh 2>&1 | tee /tmp/bootstrap-B.log
```

| Ölçüm | Beklenen | Gerçek |
| --- | --- | --- |
| Çıkış kodu | 0 | **0** ✓ |
| Süre | < 90 sn | **23 s** (eğitim adımı 6 s — stamp + import doğrulaması) |
| Günlükte "atlandı" / "zaten" | venv, llama.cpp, apt "hepsi kurulu", PATH | "venv zaten var (uv312)", "paketler güncel — atlandı", "llama.cpp zaten derli", "apt: hepsi kurulu" ✓ |
| `grep -c "güncellendi\|kuruluyor\|indiriliyor" /tmp/bootstrap-B.log` | 0 (yalnız model tespiti/stamp doğrulaması) | 0 ✓ |
| İndirme | yok (`/var/log/marvin-bootstrap-egitim.log`'da yeni `Downloading` satırı yok) | 0 `Downloading`/`Collecting` ✓ |

Canlı makinede ayrıca doğrulandı (18 Eyl): sahiplik üçü de `marvin`; `su - marvin` → `python`=venv 3.12.14, `llama-quantize` PATH'te, `HF_HOME=/mnt/models/hf`; root etkilenmiyor; `lms-model load qwen3.8-27b` 3.6 s → API listeledi → VRAM 20 GB; `unload` → 2 MiB; `pin`/`unpin` drop-in yazıp sildi, `systemctl show` gördü.

## 3. Koşu C — format tatbikatı (asıl sınav) — 18 Eyl 2026, YAPILDI

**Kurulum turları** (hepsi `marvin-v3.iso`, aynı preseed):

| Tur | IDER kaynağı | Sonuç | Süre |
| --- | --- | --- | --- |
| 1 | MeshCommander, ISO Mac'te | **Takıldı:** Mac→IDER USB aygıtı flap etti (`error -71`, `DID_ERROR`); `disk-detect` `ahci`'yi yüklemedi; SATA diski hiç görünmedi; partman disksiz kalıp **sessizce** bekledi (SOL boş, syslog sustu) | — |
| 2 | **MeshCentral SIDER, ISO Pi'de** (ilk deneme — çalıştı) | USB hatası yok, ama **yine `ahci` yüklenmedi** → aynı sessiz takılma. Sebep IDER kaynağı değil, d-i'nin kendisi | — |
| 3 | SIDER + Pi'deki preseed'e `modprobe ahci` + bekleme + `?tani=` işaretleri | `pci: 00:17.0=0x010601` (AHCI, BIOS değişmemiş) · `modprobe-ahci rc=0` · `ata=8`, `sdb` 3907029168 · **kurulum bitti** | reset 18:28 → reboot 18:54 = **26 dk** (IDER'den açılış ~6, disk-detect 2, biçimlendirme ~6, udev zaman aşımı 2) |
| 4 | (kaza) SIDER kesilmediği için reboot yine sanal CD'den açtı → **ikinci otomatik kurulum** diski tekrar sildi | 18:58 → 19:13:49 reboot = 16 dk; sonra SIDER kesildi, diskten açıldı 19:14:32 | |

**Bootstrap** (taze sistem 19:14:32'de açıldı):

| Koşum | Ne | Süre | Çıkış |
| --- | --- | --- | --- |
| elle (Berkay) | `sudoers.d/marvin` NOPASSWD + hostname — preseed üretmiyordu (bug 9-10) | ~2 dk | |
| C-1 | non-free + nvidia-driver + başlıklar, DKMS derleme → "yeniden başlat" | **196 s** | 0 |
| reboot | | 67 s | |
| C-2 | model diski, LM Studio (internet), eğitim ortamı **önbellekten** (66 s, "internet kullanılmadı"), ufw, WoL, SSH, kabul kontrolleri | **158 s** | 0 |
| C-3 | ikinci koşum: JIT dosyası oluşmuştu → ayarlandı; gerisi atlandı | **30 s** | 0 |

Toplam (otomatik kısım): 196 + 67 + 158 = **7 dk** — hedef < 5 dk'nın üstünde; fark sürücü indirme+DKMS (~3 dk, önbelleklenmedi) ve LM Studio indirme (~1 dk).

Orijinal tablo (doldurulmuş):

```bash
ssh marvin 'sudo bash /root/bootstrap.sh' 2>&1 | tee /tmp/bootstrap-C.log   # /root — /tmp DEĞİL
```

| Kabul ölçütü | Komut | Beklenen | Gerçek |
| --- | --- | --- | --- |
| GPU | `nvidia-smi` | RTX 6000 Ada, 550.163.01 | ✓ (reboot sonrası) |
| torch/unsloth/bnb | `su - marvin -c '/opt/egitim-venv/bin/python -c "import torch, unsloth, bitsandbytes; print(torch.cuda.is_available(), torch.version.cuda)"'` | `True 12.4` | `True 12.4` ✓ |
| llama-quantize | `/opt/llama.cpp/build/bin/llama-quantize --help` | usage metni | ✓ |
| convert | `su - marvin -c '/opt/egitim-venv/bin/python /opt/llama.cpp/convert_hf_to_gguf.py --help'` | usage metni | ✓ |
| HF_HOME | `su - marvin -c 'echo $HF_HOME'` | `/mnt/models/hf` | ✓ |
| PATH | `su - marvin -c 'command -v python llama-quantize'` | `/opt/egitim-venv/bin/python`, `/opt/llama.cpp/build/bin/llama-quantize` | ✓ |
| Sahiplik | `stat -c '%U' /opt/egitim-venv /opt/llama.cpp /mnt/models/hf` | üçü de `marvin` | ✓ |
| Model yüklü değil | `lms-model status` | `lms ps` boş, "sabitli model yok" | ✓ |
| Model istek üzerine | `lms-model load qwen3.8-27b && curl -s localhost:1234/v1/models` | model listede | ✓ |
| Boşalt | `lms-model unload` | VRAM boş (`nvidia-smi`) | 2 MiB ✓ |
| Süre (bootstrap, önbellekli) | `time` | **< 5 dk** (DKMS derlemesi dahil) | **7 dk** (C-1 196 s + reboot + C-2 158 s) — eğitim kısmı 66 s; sürücü/LM Studio indirmesi önbellek dışı |
| Çıkış kodu | | 0 | 0 / 0 / 0 |
| İkinci koşum | tekrar `sudo bash /root/bootstrap.sh` | < 90 sn, 0 | **30 s**, 0, sıfır indirme ✓ |

## 4. Bulunan bug'lar

| # | Nerede | Ne oldu | Düzeltme commit'i |
| --- | --- | --- | --- |
| 1 | bootstrap adım 10c (Koşu A, 18 Eyl) | Kısıt/pin dosyaları `/root`'a yazılıyordu; pip `marvin` olarak koşar, `/root` 700 → `Permission denied`. torch kurulmuştu, gerisi düştü; script gereksiz yere uv-3.12'ye geçti, orada da aynı hata. Pi'den gelen pinli liste de aynı yere yazılıyordu | dosyalar venv içine (`/opt/egitim-venv/{requirements,constraints}.txt`) |
| 2 | bootstrap kabul kontrolleri (Koşu A, 18 Eyl) | `llama-quantize --help \| grep -q usage` + `pipefail`: grep ilk eşleşmede çıkınca binary SIGPIPE (141) → boru hattı "başarısız" → çalışan binary HATA göründü | çıktı değişkene alınıp `[[ == *usage* ]]` ile bakılıyor |
| 4 | bootstrap adım 10c (Koşu A2) | Python 3.13: unsloth → xformers; torch 2.6 ile uyumlu son xformers 0.0.29.post3'ün cp313 tekerleği yok → pip kaynaktan derlemeye kalktı, build izolasyonunda torch yok → düştü. Kümenin 3.13'te kurulması bugün imkânsız | varsayılan `EGITIM_PYTHON=uv312`; `auto` 3 dk boşa harcıyordu |
| 5 | bootstrap adım 10c (Koşu A2) | uv-3.12'de her şey kuruldu ama `import unsloth` → transformers → torchao 0.18 → `torch.utils._pytree.register_constant` yok (torch 2.7 API'si). Ampirik: torchao 0.13–0.16 OK, 0.17+ HATA | kısıt `torchao<0.17` (`KISITLAR`) |
| 6 | bootstrap adım 10c (tasarım) | `pip freeze` doğrulamadan ÖNCE yapılıyordu → bozuk küme (torchao 0.18) önbelleğe pinli liste olarak yazıldı; sonraki koşum aynı bozuk listeyi kurardı | dondurma `venv_verify` geçince (`dondur()`) |
| 3 | tatbikat sarmalayıcısı (script değil) | `sudo bash b.sh; echo; echo EXIT=$?` → `$?` echo'nun; EXIT=0 yanıltıcı | `rc=$?` hemen sonra |
| 7 | bootstrap kabul kontrolleri (Koşu A3) | unsloth import'ta banner basıyor; `$k1` "🦥 Unsloth…" ile başlayınca `True*` karşılaştırması düştü, geçen kurulum HATA göründü | son satır alınıyor (`tail -n 1`) |
| 8 | preseed / d-i `disk-detect` (Koşu C tur 1-2) | `ahci` modülü yüklenmedi (sata-modules udeb indi, modprobe edilmedi; muhtemelen flap eden IDER USB aygıtı hw-detect taramasını yiyor — tur 2'de USB hatasız da tekrarladı). SATA disk görünmedi, döngü boş döndü, partman **sessizce** bekledi | `early_command`: `modprobe ahci` + 60 sn bekleme + `?tani=` raporları + `2x-DISK-YOK` işareti (PR #2) |
| 9 | preseed (Koşu C) | Taze kurulumda `sudo` parola istiyor — parolasız sudo eski makineye elle konmuştu; uzaktan `sudo bash /root/bootstrap.sh` koşmadı | `late_command` → `/etc/sudoers.d/marvin` NOPASSWD (PR #2) |
| 10 | preseed (Koşu C, 15 Eyl'den beri) | hostname `192`: d-i ters DNS'ten IP'yi alıp ilk noktada kesiyor; `netcfg/hostname=marvin` kazanmıyor | `late_command` → `/target/etc/hostname` + `/etc/hosts` (PR #2) |
| 11 | işletme (Koşu C tur 4) | SIDER kesilmeden reboot → sanal CD'den açılıp **kurulum baştan başladı**, biten kurulumu sildi. 10 sn'lik otomatik menü bunu kaçınılmaz kılıyor | `asama=3` işareti `…-SIDER-IDER-SIMDI-KES` oldu; REHBER §6'ya büyük harfle. Kalıcı çözüm: `marvin-yeniden-kur` (IDER'siz yol) |
| 12 | işletme | Her kurulumda SSH host anahtarı değişir → `ssh marvin` "REMOTE HOST IDENTIFICATION HAS CHANGED" ile durur | `ssh-keygen -R 192.168.1.114` — REHBER §6 adımlarına eklendi |
| 14 | preseed + bootstrap (Koşu C sonrası kontrol) | Taze kurulumda `PasswordAuthentication yes`; `99-nopw.conf` eski makineye elle konmuştu. Parolasız sudo (bug 9 düzeltmesi) ile birleşince LAN'da parola tahmini = root | preseed `late_command` + bootstrap adım 9b aynı dosyayı yazar (PR #3); canlıda 18 Eyl'de kapatıldı |
| 13 | bootstrap adım 1 | "DKMS modülü derlendi" yalnız başlık dizinine bakıyordu; modül adı `nvidia-current` olduğu için `modinfo nvidia` da boş dönüyor | `nvidia_module_built()`: `.ko` dosyası ya da `dkms status … installed` (PR #2) |

## 5. Tatbikat sonrası depoya işlenecekler

- [x] `egitim/requirements.txt` (dondurulmuş, 18 Eyl A3)
- [x] REHBER §7 "Python yolu" paragrafı: uv-3.12 (xformers cp313 yok) + torchao<0.17
- [x] REHBER §6: SIDER yolu kanıtlandı, "SIDER'ı `asama=3`'te kes", `ssh-keygen -R`; §11 satırı silindi (PR #2)
- [x] DURUM.md "Kalan işler 1" kapandı; "Bitenler"e ölçümlerle girdi (PR #2)
- [x] Bu dosyanın üstündeki durum kutusu
