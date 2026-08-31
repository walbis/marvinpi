# LLM Test Makinesi — Kurtarma ve İşletme Rehberi

## Proje özeti (brief)
- Test makinesi (Debian, NVIDIA 12GB+) her an başkalarınca formatlanabilir → "cattle" yaklaşımı: her şey `bootstrap.sh` ile tek komutta geri gelir, elle kurulum yok.
- Raspberry Pi kalıcı çapa: hep tailnet'te, LiteLLM gateway (sabit endpoint + API anahtarları) ve bootstrap dosya sunucusu onda.
- Model sunucusu: şimdilik Ollama (tek kullanıcı, OpenAI uyumlu). Ekip yükü gelince compose'ta vLLM bloğuna geçilir.
- Erişim yalnızca Tailscale üzerinden; makinenin API'si sadece tailnet IP'sini dinler.

## İlk kurulum sırası
1. **Tailscale hesabı**: tailscale.com → ücretsiz plan. Admin konsolunda MagicDNS açık olsun (varsayılan).
2. **Auth key üret**: Admin konsolu → Settings → Keys → *Generate auth key* → **Reusable** işaretle, süre 90 gün. Çıkan `tskey-auth-...` değerini not et.
3. **Pi kurulumu**: `sudo bash pi-setup.sh` → verdiği linkle Tailscale'e giriş yap. Üretilen **master key**'i sakla. `bootstrap.sh` ve `docker-compose.yml` dosyalarını `/opt/llm-repo/` içine kopyala.
4. **Test makinesi**: `sudo TS_AUTHKEY=tskey-auth-XXX bash bootstrap.sh` → sürücü kurulduysa reboot ister, reboot sonrası aynı komutu tekrar çalıştır.
5. Admin konsolu → Machines → `llm-test` → **Disable key expiry** (yoksa ~6 ayda bir yeniden giriş ister).

## Senaryolar

**A) Makine formatlandı.** Formatı yapan kişi taze Debian kurar (kurulumda "SSH server" seçili olsun) ve tek komut çalıştırır:
```
curl -fsSL http://<pi-lan-ip>:8080/bootstrap.sh -o /tmp/b.sh && sudo TS_AUTHKEY=tskey-auth-XXX bash /tmp/b.sh
```
GitHub kullanıyorsan adres: `https://raw.githubusercontent.com/KULLANICI/REPO/main/bootstrap.sh`. Kişiye komutu güncel key ile sen iletirsin. Alternatif: makineye SSH açıksa Pi üzerinden kendin bağlanıp (`tailscale ssh llm-pi` → `ssh kullanici@<makine-lan-ip>`) komutu uzaktan sen çalıştırırsın.

**B) Servis bozuldu, makine ayakta.** `tailscale ssh llm-test` → `cd /opt/llm && docker compose restart` yetmezse `sudo bash bootstrap.sh` (idempotent, her şeyi onarır).

**C) Makine kapalı veya donmuş.** Birincil yol **AMT**: `https://192.168.1.114:16993` (sertifika uyarısını geç) → `admin` + AMT şifresi → Remote Control → Power On / Reset. Ofis dışındaysan önce Tailscale'i aç (Pi subnet router). Yedek yol WoL: `tailscale ssh llm-pi` → `sudo etherwake -i eth0 60:cf:84:76:49:42`.

**Sabit bilgiler:** AMT/LAN portu MAC `60:cf:84:76:49:42` (Debian'da `enp6s0`) · IP `192.168.1.114` (router'da rezerve) · AMT adresi `https://192.168.1.114:16993` · kip CCM · teşhis aracı `sudo rpc amtinfo`.

**D) Auth key süresi doldu (90 gün).** Adım 2'deki gibi yeni key üret, A senaryosundaki komutta değiştir. Takvimine 80. güne hatırlatma koy.

## API kullanımı (Pi üzerinden, sabit adres)
```
curl http://<pi-tailscale-ip>:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-MASTERKEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"selam"}]}'
```
Ekip üyesine anahtar üretmek:
```
curl -X POST http://<pi-tailscale-ip>:4000/key/generate \
  -H "Authorization: Bearer sk-MASTERKEY" -H "Content-Type: application/json" \
  -d '{"key_alias":"ali"}'
```
Doğrudan makineye (gateway'siz) istek: `http://<makine-tailscale-ip>:11434/v1/...` — anahtar gerekmez, tailnet zaten kimlik katmanı.

## vLLM'e geçiş (ekip yükü gelince)
1. Makinede `/opt/llm/docker-compose.yml`: ollama bloğunu yorumla, vllm bloğunu aç → `docker compose up -d`.
2. Pi'de `/opt/llm-gw/litellm-config.yaml`: vLLM model bloğunu aç → `docker compose restart litellm`.

## Notlar
- Modeller format ile silinir; bootstrap yeniden indirir (yaklaşık 9 GB, ilk istek öncesi biter). Formatsız reboot'larda `ollama_models` volume'ü sayesinde kalıcıdır.
- Sürücü adımı takılırsa elle: non-free depoyu açıp `apt install nvidia-driver`, reboot, script'e devam.
- `llm-test` adı çözülmüyorsa (eski node kaydı kalmış olabilir) admin konsolundan eski makineyi sil veya litellm-config'te `api_base` olarak makinenin 100.x IP'sini yaz.
- Secrets asla repoya girmez: auth key komutla, master key Pi'deki `.env` içinde.
