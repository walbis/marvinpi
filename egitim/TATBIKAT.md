# Tatbikat — bootstrap adım 10 (eğitim ortamı) — doldurulacak rapor

**Durum:** ☐ yapılmadı · ☐ yapıldı, tarih: ________ · koşan: ________

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

> Dikkat: senkron hâlâ `RAW_BASE` (pi-setup.sh:21) adresinden çeker. Bu PR Gitea'daysa ve
> GitHub güncel değilse Pi eski dosyayı alır. Önce kanonik repo kararı (REVIEW-CONTEXT.md).

## 1. Koşu A — çalışan makinede, önbellek boş (internetten)

Amaç: (1) paket kümesinin çözüldüğünü görmek, (2) `requirements.txt` üretmek, (3) önbelleği doldurmak.

```bash
ssh marvin
curl -fsSL http://192.168.1.166:8080/bootstrap.sh -o /tmp/b.sh
time sudo bash /tmp/b.sh 2>&1 | tee /tmp/bootstrap-A.log
```

| Ölçüm | Beklenen | Gerçek |
| --- | --- | --- |
| Çıkış kodu | 0 | |
| Toplam süre | 15-25 dk (65 Mbit) | |
| "Eğitim ortamı :" satırı | `tamam (N sn)` | |
| "python yolu" | `system` (3.13) — ya da `uv312` düştüyse **REHBER §7'ye işle** | |
| "torch" | `2.6.0+cu124 12.4` | |
| `/root/egitim-requirements.txt` | var, `torch==2.6.0+cu124` satırı içerir | |
| `/mnt/models/cache/wheels` | dolu (`ls | wc -l` > 50) | |
| `/mnt/models/cache/llama.cpp/llama.cpp-v0.4.1.tar.zst` | var | |
| lmstudio.service | `active`; **model yüklü değil** (`lms-model status`) | |

Sonra: `scp marvin:/root/egitim-requirements.txt egitim/requirements.txt` → depoya commit → Pi senkronu.

## 2. Koşu B — aynı makinede ikinci koşum (idempotentlik)

```bash
time sudo bash /tmp/b.sh 2>&1 | tee /tmp/bootstrap-B.log
```

| Ölçüm | Beklenen | Gerçek |
| --- | --- | --- |
| Çıkış kodu | 0 | |
| Süre | < 90 sn | |
| Günlükte "atlandı" / "zaten" | venv, llama.cpp, apt "hepsi kurulu", PATH | |
| `grep -c "güncellendi\|kuruluyor\|indiriliyor" /tmp/bootstrap-B.log` | 0 (yalnız model tespiti/stamp doğrulaması) | |
| İndirme | yok (`/var/log/marvin-bootstrap-egitim.log`'da yeni `Downloading` satırı yok) | |

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
| 1 | | | |

## 5. Tatbikat sonrası depoya işlenecekler

- [ ] `egitim/requirements.txt` (dondurulmuş)
- [ ] REHBER §7 "Python yolu" paragrafı: 3.13 mü, uv-3.12 mi
- [ ] REHBER §11 "Henüz test edilmemiş" satırı silinir; §10'a tarih ve süreler
- [ ] DURUM.md "Kalan işler 1" kapanır; "Bitenler"e ölçümlerle girer
- [ ] Bu dosyanın üstündeki durum kutusu
