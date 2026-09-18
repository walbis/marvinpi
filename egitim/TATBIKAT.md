# Tatbikat — bootstrap adım 10 (eğitim ortamı) — doldurulacak rapor

**Durum:** Koşu A+B ☑ 18 Eyl 2026 (Claude, çalışan makinede; Berkay AMT ile açtı) · Koşu C (format) ☐ bekliyor

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

## 3. Koşu C — format tatbikatı (asıl sınav)

REHBER §6 adımlarıyla marvin'i IDER'den sıfırdan kur (5,5 dk), sonra:

```bash
ssh marvin 'sudo bash /root/bootstrap.sh' 2>&1 | tee /tmp/bootstrap-C.log   # /root — /tmp DEĞİL
```

| Kabul ölçütü | Komut | Beklenen | Gerçek |
| --- | --- | --- | --- |
| GPU | `nvidia-smi` | RTX 6000 Ada, 550.163.01 | |
| torch/unsloth/bnb | `su - marvin -c '/opt/egitim-venv/bin/python -c "import torch, unsloth, bitsandbytes; print(torch.cuda.is_available(), torch.version.cuda)"'` | `True 12.4` | |
| llama-quantize | `/opt/llama.cpp/build/bin/llama-quantize --help` | usage metni | |
| convert | `su - marvin -c '/opt/egitim-venv/bin/python /opt/llama.cpp/convert_hf_to_gguf.py --help'` | usage metni | |
| HF_HOME | `su - marvin -c 'echo $HF_HOME'` | `/mnt/models/hf` | |
| PATH | `su - marvin -c 'command -v python llama-quantize'` | `/opt/egitim-venv/bin/python`, `/opt/llama.cpp/build/bin/llama-quantize` | |
| Sahiplik | `stat -c '%U' /opt/egitim-venv /opt/llama.cpp /mnt/models/hf` | üçü de `marvin` | |
| Model yüklü değil | `lms-model status` | `lms ps` boş, "sabitli model yok" | |
| Model istek üzerine | `lms-model load qwen3.8-27b && curl -s localhost:1234/v1/models` | model listede | |
| Boşalt | `lms-model unload` | VRAM boş (`nvidia-smi`) | |
| Süre (bootstrap, önbellekli) | `time` | **< 5 dk** (DKMS derlemesi dahil) | |
| Çıkış kodu | | 0 | |
| İkinci koşum | tekrar `sudo bash /root/bootstrap.sh` | < 90 sn, 0 | |

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
| — | kapsam dışı (15 Eyl kurulumu) | hostname `192`: d-i ters DNS'ten IP'yi alıp ilk noktada kesmiş; preseed `netcfg/hostname=marvin` kazanmamış (`/etc/hosts`: `127.0.1.1 192.local 192`) | ayrı iş: preseed `late_command` → `echo marvin > /target/etc/hostname`; canlıda `hostnamectl set-hostname marvin` |

## 5. Tatbikat sonrası depoya işlenecekler

- [x] `egitim/requirements.txt` (dondurulmuş, 18 Eyl A3)
- [x] REHBER §7 "Python yolu" paragrafı: uv-3.12 (xformers cp313 yok) + torchao<0.17
- [ ] REHBER §11 "Henüz test edilmemiş" satırı silinir; §10'a tarih ve süreler
- [ ] DURUM.md "Kalan işler 1" kapanır; "Bitenler"e ölçümlerle girer
- [ ] Bu dosyanın üstündeki durum kutusu
