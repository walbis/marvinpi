# Eğitim ortamı — marvin'de GPU deney/eğitim katmanı

`bootstrap.sh` adım 10'un ne kurduğu, ne kurmadığı ve oturum sonunda ne beklendiği.
Teknik akış REHBER.md §7 "Adım 10"da; burası kullanım sözleşmesi.

## Ne var

| | |
| --- | --- |
| Python ortamı | `/opt/egitim-venv` — sahibi `marvin`, `sudo` gerekmez. torch **cu124** (sürücü 550 → CUDA 12.4 tavanı, torch ≤ 2.6), unsloth, peft, trl, transformers, datasets, accelerate, bitsandbytes, sentencepiece, protobuf, gguf, hf_transfer, numpy, httpx, openai, pytest |
| llama.cpp | `/opt/llama.cpp` — sabit etiket (`LLAMA_TAG`, bugün `v0.4.1`), yalnız CPU derlemesi. `convert_hf_to_gguf.py` ve `build/bin/llama-quantize` GGUF çevirme/niceleme için; çıkarım LM Studio'da |
| HF önbelleği | `/mnt/models/hf` (`HF_HOME`) — **yalnız kamuya açık taban ağırlıklar**. Formatı sağ atlatır, tekrar indirilmez |
| Kurulum önbelleği | `/mnt/models/cache` — pip wheel, apt .deb, llama.cpp derlemesi, uv Python. İkinci kurulum internetsiz ~2 dk |
| `lms-model` | LM Studio modelini istek üzerine yükle/boşalt/sabitle. Açılışta model **yüklenmez** |
| Ortam | giriş kabuğunda (`marvin` için): `HF_HOME`, `HF_HUB_ENABLE_HF_TRANSFER=1`, PATH'te venv ve llama.cpp |

Giriş yaptığında `python` doğrudan venv'in Python'u, `llama-quantize` PATH'te.

## Ne yok (bilerek)

- **CUDA toolkit** — pip tekerlekleri kendi çalışma zamanını taşır. `nvcc` gerekiyorsa oturum içinde kur, bootstrap'a ekleme.
- **Ollama** — bu makinede yalnız LM Studio.
- **Proje dizinleri, veri, adaptör, çıktı, anahtar** — oturumla gelir, oturumla gider. Bootstrap NVMe'de yalnız `lmstudio/`, `hf/` ve `cache/` bırakır.
- **Açılışta yüklü model** — VRAM boş başlar. Sohbet modeli lazımsa `lms-model load qwen3.8-27b`.

## Oturum akışı

```bash
ssh marvin
mkdir -p /mnt/models/PROJE && cd /mnt/models/PROJE     # oturum dizini (NVMe, hızlı; sonunda silinir)
python -m pip install -r requirements-proje.txt         # projenin kendi pin'leri venv'in ÜSTÜNE (bootstrap değişmez)
# ... eğitim / değerlendirme / çevirme ...
python /opt/llama.cpp/convert_hf_to_gguf.py ./merged --outfile ./model-f16.gguf
llama-quantize ./model-f16.gguf ./model-Q4_K_M.gguf Q4_K_M
```

LM Studio ile aynı anda çalışacaksan önce `lms-model unload` (VRAM'i boşalt); bitince istersen `lms-model load`.

## Oturum sonu — iz bırakma

1. **Proje dizini:** `shred -u` ile hassas dosyalar, sonra `rm -rf /mnt/models/PROJE`. (NVMe'de `shred` blok düzeyinde garanti vermez; gerçekten hassas veri için oturumu baştan LUKS'lu bir dosya imajında ya da tmpfs'te yürüt.)
2. **venv'e proje pin'i kurduysan** ortamı bootstrap hâline döndür:
   ```bash
   sudo rm -rf /opt/egitim-venv && sudo bash /root/bootstrap.sh     # önbellekten ~2 dk
   ```
   Alternatif (hızlı): oturumu hiç venv'e dokunmadan `python -m venv --system-site-packages /mnt/models/PROJE/.venv` ile ayrı bir venv'de yürüt; silmek proje diziniyle biter.
3. **HF önbelleği:** yalnız kamuya açık taban modeller kalır. Özel/lisanslı ağırlık indirdiysen `huggingface-cli delete-cache` ile kaldır.
4. **HF/W&B tokenları:** `~/.cache/huggingface/token`, `~/.netrc`, ortam değişkenleri — sil. Bootstrap bunları hiç yazmaz, o yüzden hiç bulamaz.
5. Şüphedeysen makineyi yeniden kur: 5,5 dk kurulum + ~2 dk bootstrap (önbellekli). Bu makinenin tasarım amacı budur.

## Paket pin'leri nasıl yönetilir

- `egitim/requirements.txt` **dondurulmuş** listedir; elle yazılmaz. İlk başarılı kurulum `/opt/egitim-venv/requirements.txt` üretir → depoya bu ad altında konur → Pi senkronu (`llm-repo-sync`) dağıtır → sonraki kurulumlar buradan kurar.
- Sürüm yükseltmek: `egitim/requirements.txt`'i sil (ya da `REQ_URL=` boş ver), bootstrap'ı çalışan makinede koştur, yeni dondurulmuş dosyayı depoya koy. Değişiklik commit'i = sürüm kararı.
- torch tavanı **cu124 / 2.6** sürücü 550'den geliyor. Daha yeni torch için önce sürücü (trixie'de resmi olarak yok) — bu bir mimari karar, requirements düzenleyerek aşılmaz. Tavanın iki sonucu: Python **3.12** (xformers cp313 tekerleği yok) ve `torchao<0.17` (0.17+ torch 2.7 ister).
- llama.cpp'nin kendi `requirements/requirements-convert_hf_to_gguf.txt` dosyasını **asla** venv'e kurma: içindeki `torch==2.11.0` (CPU dizini) CUDA torch'u sessizce ezer.

## Değiştirilebilir ayarlar

`EGITIM=0` (adımı atla) · `EGITIM_PYTHON=uv312|system|auto` · `LLAMA_TAG` · `TORCH_INDEX` · `CACHE_DIR` · `REQ_URL` — tam liste REHBER.md §7.
