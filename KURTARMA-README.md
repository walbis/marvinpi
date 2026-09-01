# LLM Test Makinesi (marvin) — Kurtarma ve İşletme Rehberi

## Proje özeti
- Test makinesi **marvin** her an başkalarınca formatlanabilir → "cattle" yaklaşımı: her şey `bootstrap.sh` ile tek komutta geri gelir, elle kurulum yok.
- **Modeller ayrı diskte** (`SILME-MODELLER`) ve **formatı sağ atlatır**. Yeniden indirmeye gerek yoktur.
- **Raspberry Pi kalıcı çapa**: hep tailnet'te; LiteLLM gateway (sabit endpoint + API anahtarları) ve bootstrap dosya sunucusu onda.
- Model sunucusu: **LM Studio**. Seçilme sebebi REST API'sinin model yükleme/boşaltma/indirme uçları içermesi — çalışma anında API'den model değiştirilebiliyor.
- **marvin tailnet'e girmez.** Tek giriş kapısı Pi'dir (Tailscale subnet router, `192.168.1.0/24` ilan edilmiş).

## Sabit bilgiler

| | |
|---|---|
| marvin | Debian 13 (trixie) · i9-14900KF · 128 GB RAM · RTX 6000 Ada 48 GB |
| marvin LAN | `192.168.1.114` · arayüz `enp6s0` · MAC `60:cf:84:76:49:42` |
| Sistem diski | `sda` 1.8 TB → `/` — **format edilecek disk BUDUR** |
| Model diski | `nvme0n1p1`, ext4, etiket **`SILME-MODELLER`** → `/mnt/models` (fstab'da `nofail`) |
| LM Studio | port **1234**, `--bind 0.0.0.0`, systemd: `lmstudio.service` |
| Yüklü modeller | `qwen/qwen3.8-27b` (Q4_K_M) + `text-embedding-nomic-embed-text-v1.5` |
| Pi (`llm-pi`) | Tailscale `100.101.117.47` · LAN `192.168.1.166` · kullanıcı `noone` |
| Pi servisleri | LiteLLM `:4000` · bootstrap dosya sunucusu `:8080` |
| AMT | `https://192.168.1.114:16993` · kullanıcı `admin` · kip CCM |
| Güvenlik duvarı | ufw: `192.168.1.0/24` → 22, 1234 |
| Repo | `https://github.com/walbis/marvinpi` |

## Erişim

Mac'te `~/.ssh/config`:
```
Host pi
    HostName 100.101.117.47
    User noone

Host marvin
    HostName 192.168.1.114
    User marvin
    ProxyJump pi
```
Böylece `ssh marvin` ofis dışından da Pi üzerinden atlar. Pi'ye giriş Tailscale SSH ile olur (anahtar gerekmez); marvin'e giriş **SSH anahtarıyla** olur — anahtar yoksa `ssh-copy-id marvin@192.168.1.114`.

## Senaryolar

**A) Makine formatlandı.** Formatı yapan kişi taze Debian kurar. Kurulumda dikkat:
- Sistem diski **`sda`** seçilmeli. **NVMe'ye (`nvme0n1`) dokunulmamalı** — modeller orada.
- En güvenlisi: kurulum sırasında NVMe'yi fiziksel olarak sök. Kurulumcu görmediği diski silemez.
- "SSH server" seçili olsun, kullanıcı adı `marvin`.

Sonra tek komut:
```
curl -fsSL https://raw.githubusercontent.com/walbis/marvinpi/main/bootstrap.sh -o /tmp/b.sh && sudo bash /tmp/b.sh
```
Pi'nin dosya sunucusundan da alınabilir (internet yoksa):
```
curl -fsSL http://192.168.1.166:8080/bootstrap.sh -o /tmp/b.sh && sudo bash /tmp/b.sh
```
Auth key **gerekmez** — marvin tailnet'e girmiyor. Sürücü kurulduysa reboot ister; reboot sonrası aynı komut tekrar çalıştırılır (script idempotenttir). Kesintisiz olsun istersen `sudo AUTO_REBOOT=1 bash /tmp/b.sh`.

**SSH erişimi de geri gelir.** `bootstrap.sh` public key listesini Pi'den (`http://192.168.1.166:8080/authorized_keys`) çekip kurar; var olan anahtarları korur, mükerrer satır eklemez. Yani format sonrası ilk komut çalıştıktan sonra `ssh marvin` doğrudan çalışır.

> Pi erişilemezse veya `/opt/llm-repo/authorized_keys` yoksa bu adım uyarı basıp geçer — kurulum tamamlanır ama makineye anahtarla girilemez. O durumda erişimi elle aç: `ssh-copy-id marvin@192.168.1.114`.
>
> Anahtar listesini güncellemek için: `scp ~/.ssh/id_ed25519.pub pi:/tmp/ak && ssh -t pi 'sudo install -m 644 /tmp/ak /opt/llm-repo/authorized_keys'`

**B) Servis bozuldu, makine ayakta.**
```
ssh marvin
sudo systemctl restart lmstudio
```
Yetmezse `sudo bash /tmp/bootstrap.sh` — idempotenttir, her şeyi onarır ve çalışan servise gereksiz dokunmaz.
Teşhis: `systemctl status lmstudio` · `journalctl -u lmstudio -n 50`

**C) Makine kapalı veya donmuş.**
Birincil yol **AMT**: `https://192.168.1.114:16993` (sertifika uyarısını geç) → `admin` + AMT şifresi → Remote Control → Power On / Reset.
Yedek yol **WoL**: `ssh pi` → `sudo etherwake -i eth0 60:cf:84:76:49:42`

> **16992 ASLA açılmaz** — CSME 16.1 TLS'siz portları kaldırdı. Hep 16993.
> Bu donanımda **KVM ve SOL yok** (ISM + KF, iGPU yok): BIOS ekranı uzaktan görülemez, AMT yalnızca güç verir.

**Makine açık mı kapalı mı — hızlı ayrım (ping TTL):**

| Cevap | Anlamı |
|---|---|
| `ttl=64` | Linux ayakta |
| `ttl=255` | **Makine KAPALI**, cevabı ME veriyor |
| cevap yok | ağ/güç yok ya da açılış geçişi |

Bu ayrım önemli: kapalı makine de ping'e cevap verir ve AMT portu açık kalır. Sadece "ping geliyor ama SSH yok" görüp güvenlik duvarı sanma — önce TTL'e bak.

**D) AMT şifresi unutuldu / ME bozuldu.**
BIOS → Advanced → AMT Configuration → Unconfigure ME: Enabled → F10 → Debian'da `sudo rpc activate -local -ccm -password 'YENİ'`. Yaklaşık 1 dk sonra 16993 tekrar açılır. Teşhis: `sudo rpc amtinfo` (araç `/usr/local/bin/rpc`, rpc-go). `rpc activate/configure` LMS olmadığı için 20 sn timeout döngüsüne girer — yavaştır ama tamamlar.

## API kullanımı

Pi üzerinden, sabit adres (önerilen):
```
curl http://100.101.117.47:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-MASTERKEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen/qwen3.8-27b","messages":[{"role":"user","content":"selam"}],"max_tokens":512}'
```
Ekip üyesine anahtar üretmek:
```
curl -X POST http://100.101.117.47:4000/key/generate \
  -H "Authorization: Bearer sk-MASTERKEY" -H "Content-Type: application/json" \
  -d '{"key_alias":"ali"}'
```
Doğrudan makineye (gateway'siz, sadece LAN içinden): `http://192.168.1.114:1234/v1/...`

> **`max_tokens` cömert verilmeli.** qwen3 bir *reasoning* modelidir; küçük bir limit tamamen düşünme aşamasında tükenir ve cevap boş görünür (`finish_reason: "length"`, `reasoning_tokens` dolu). 512 ve üzeri güvenli.

## Notlar
- **Modeller formatta silinmez** — ayrı diskte (`/mnt/models`). `bootstrap.sh` diski etiketinden bulup bağlar ve symlink'i kurar. Disk bulunamazsa symlink'i **bilerek kurmaz**, yoksa modeller sistem diskine inip formatta uçardı.
- Sürücü adımı takılırsa elle: non-free depoyu açıp `apt install nvidia-driver`, reboot, script'e devam.
- `bootstrap.sh` çalışan servisi gereksiz yere yeniden başlatmaz: systemd unit'i birebir aynıysa dokunmaz, yüklü model düşmez.
- ufw kuralları **enable'dan önce** yazılır ve doğrulanır; doğrulanamazsa güvenlik duvarına hiç dokunulmaz. (Ters sıra makineyi ağdan kilitler: ping açık, tüm TCP kapalı.)
- Secrets repoya girmez: LiteLLM master key Pi'deki `.env` içinde (chmod 600).
- Pi tek arıza noktasıdır (gateway + dosya sunucusu + ileride netboot). SD kart imajını yedekle.
